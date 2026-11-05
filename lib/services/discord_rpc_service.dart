import 'dart:async';

import 'package:dart_discord_presence/dart_discord_presence.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../media/playback_timeline.dart';
import '../utils/app_logger.dart';
import '../utils/formatters.dart';
import '../utils/media_image_helper.dart';
import '../utils/platform_detector.dart';
import '../utils/media_server_http_client.dart';
import 'satra_server.dart';
import 'settings_service.dart';

const Duration _defaultPosterCacheTtl = Duration(hours: 3);
const Duration _maxPosterCacheTtl = Duration(days: 365);

DateTime posterCacheExpiryFromResponse(Object? responseData, {required DateTime receivedAt}) {
  final expiresIn = switch (responseData) {
    {'expiresIn': final int seconds} => seconds,
    _ => null,
  };
  if (expiresIn == null) {
    return receivedAt.add(_defaultPosterCacheTtl);
  }
  if (expiresIn <= 0) {
    return receivedAt;
  }
  if (expiresIn > _maxPosterCacheTtl.inSeconds) {
    return receivedAt.add(_defaultPosterCacheTtl);
  }
  try {
    return receivedAt.add(Duration(seconds: expiresIn));
  } on RangeError {
    return receivedAt.add(_defaultPosterCacheTtl);
  }
}

class _CachedUrl {
  final String url;
  final DateTime expiresAt;

  _CachedUrl(this.url, this.expiresAt);

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Service that manages Discord Rich Presence integration.
///
/// Desktop only (Windows, macOS, Linux). Shows a "Watching" activity for
/// video and a "Listening" activity for music tracks. Gracefully handles
/// Discord not running.
class DiscordRPCService {
  static const String _applicationId = '1453773470306402439';
  static const String _posterUploadUrl = '$satraServerBaseUrl/posters';
  static const int _maxPosterUploadBytes = 5 * 1024 * 1024;

  /// Cache of thumbnail paths to hosted poster URLs. Keyed by
  /// `<backendId>:<thumbPath>` so the same path on different backends doesn't
  /// collide.
  static final Map<String, _CachedUrl> _posterUrlCache = {};

  static DiscordRPCService? _instance;
  static DiscordRPCService? _testingInstance;
  static DiscordRPCService get instance => _testingInstance ?? (_instance ??= DiscordRPCService._());

  /// Routes [instance] to [service] so playback engines under test publish
  /// to a [forTesting] service instead of the real IPC singleton.
  @visibleForTesting
  static void debugOverrideInstance(DiscordRPCService? service) {
    _testingInstance = service;
  }

  DiscordRPC? _rpc;
  bool _isConnected = false;
  bool _isEnabled = false;
  bool _isInitialized = false;
  bool get isEnabled => _isEnabled;
  bool get isConnected => _isConnected;
  MediaItem? _currentMetadata;
  MediaServerClient? _currentClient;
  String? _cachedThumbnailUrl;
  bool _isPlaying = false;
  final PlaybackTimeline _timeline = PlaybackTimeline();
  double _playbackSpeed = 1.0;
  int _playbackRevision = 0;
  Timer? _reconnectTimer;
  DateTime? _lastPresenceUpdate;
  StreamSubscription<void>? _readySubscription;
  StreamSubscription<void>? _disconnectedSubscription;
  StreamSubscription<dynamic>? _errorSubscription;

  DiscordRPCService._() : _rpcFactory = DiscordRPC.new;

  /// Standalone instance for tests; [rpcFactory] supplies fake clients so no
  /// IPC connection is attempted.
  @visibleForTesting
  DiscordRPCService.forTesting({required this._rpcFactory});

  final DiscordRPC Function() _rpcFactory;

  static bool get isAvailable {
    if (!PlatformDetector.isDesktopOS()) {
      return false;
    }
    return DiscordRPC.isAvailable;
  }

  /// Initialize the service. Call once at app startup (main.dart).
  Future<void> initialize() async {
    if (!isAvailable) {
      appLogger.d('Discord RPC not available on this platform');
      return;
    }

    if (_isInitialized) return;
    _isInitialized = true;

    final settings = await SettingsService.getInstance();
    _isEnabled = settings.read(SettingsService.enableDiscordRPC);

    if (_isEnabled) {
      await _connect();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (_isEnabled == enabled) return;

    _isEnabled = enabled;

    if (enabled) {
      await _connect();
      // Restore presence if we have active playback
      if (_currentMetadata != null) {
        await _updatePresence();
      }
    } else {
      _disconnect();
    }
  }

  /// Start showing presence for media playback. Works for any backend —
  /// thumbnail upload uses the neutral [MediaServerClient.thumbnailUrl] /
  /// [MediaServerClient.streamHeaders] surface.
  Future<void> startPlayback(MediaItem metadata, MediaServerClient client) async {
    final revision = ++_playbackRevision;
    _currentMetadata = metadata;
    _currentClient = client;
    _isPlaying = true;
    _timeline.reset(duration: metadata.durationMs != null ? Duration(milliseconds: metadata.durationMs!) : null);
    _cachedThumbnailUrl = null;
    _playbackSpeed = 1.0;
    _lastPresenceUpdate = null;

    if (_isEnabled && _isConnected) {
      unawaited(_uploadThumbnailAndUpdatePresence(revision, metadata, client));
    }
  }

  /// Update current playback position (for progress bar)
  void updatePosition(Duration position) {
    final secondsChanged = position.inSeconds != _timeline.position.inSeconds;
    final isSeek = _timeline.updatePosition(position);
    if (!_isPlaying && _currentMetadata != null && _currentMetadata!.kind != MediaKind.track && secondsChanged) {
      if (_isEnabled && _isConnected) unawaited(_updatePresence());
      return;
    }

    if (_isEnabled && _isConnected && _isPlaying && isSeek) {
      final now = clock.now();
      if (_lastPresenceUpdate == null || now.difference(_lastPresenceUpdate!) > const Duration(seconds: 1)) {
        _lastPresenceUpdate = now;
        _updatePresence();
      }
    }
  }

  /// Update current playback speed (for accurate remaining time calculation)
  void updatePlaybackSpeed(double speed) {
    if (!speed.isFinite || speed <= 0 || _playbackSpeed == speed) return;
    _playbackSpeed = speed;
    if (_isEnabled && _isConnected && _isPlaying) {
      _updatePresence();
    }
  }

  /// Resume from the player's position, excluding time spent paused.
  Future<void> resumePlayback({Duration? position}) async {
    if (_currentMetadata == null) return;
    if (position != null) _timeline.updatePosition(position);
    _isPlaying = true;

    if (_isEnabled && _isConnected) {
      await _updatePresence();
    }
  }

  /// Videos retain a static paused status; music keeps its existing withdraw
  /// policy. Capture the final player position before replacing the timer.
  Future<void> pausePlayback({Duration? position}) async {
    if (position != null) _timeline.updatePosition(position);
    _isPlaying = false;

    if (_isEnabled && _isConnected) {
      await _updatePresence();
    }
  }

  Future<void> stopPlayback() async {
    _playbackRevision++;
    _currentMetadata = null;
    _currentClient = null;
    _isPlaying = false;
    _cachedThumbnailUrl = null;
    _playbackSpeed = 1.0;
    _lastPresenceUpdate = null;

    if (_isEnabled && _isConnected) {
      await clearPresence();
    }
  }

  Future<void> clearPresence() async {
    try {
      unawaited(_rpc?.clearPresence());
    } catch (e) {
      appLogger.d('Failed to clear Discord presence', error: e);
    }
  }

  /// Dispose the service (call on app shutdown)
  Future<void> dispose() async {
    _reconnectTimer?.cancel();
    _disconnect();
  }

  Future<void> _connect() async {
    if (_rpc != null) return;

    // Bound to this attempt's client so deferred continuations (the initialize
    // await and the ready/disconnected listeners) can detect that a
    // disable/enable cycle replaced the client and stand down instead of
    // acting on — or tearing down — the successor.
    DiscordRPC? rpc;
    try {
      rpc = _rpcFactory();
      _rpc = rpc;

      _readySubscription = rpc.onReady.listen((_) async {
        if (!identical(_rpc, rpc)) return; // stale event from a replaced client
        _isConnected = true;
        appLogger.i('Discord RPC connected');

        // Small delay to let Discord stabilize after connection
        await Future.delayed(const Duration(milliseconds: 200));
        // The client may have been replaced while we waited; don't publish
        // presence on the successor's behalf.
        if (!identical(_rpc, rpc)) return;

        // Update presence if we have active playback
        final metadata = _currentMetadata;
        final client = _currentClient;
        if (metadata != null && client != null) {
          await _uploadThumbnailAndUpdatePresence(_playbackRevision, metadata, client);
        }
      });

      _disconnectedSubscription = rpc.onDisconnected.listen((_) {
        if (!identical(_rpc, rpc)) return; // stale event from a replaced client
        appLogger.i('Discord RPC disconnected');
        // A disposed/lost DiscordRPC cannot be re-initialized and _connect
        // no-ops while _rpc is set — tear the dead client down before arming
        // the reconnect timer so its _connect builds a fresh client.
        _teardownRpc();
        _scheduleReconnect();
      });

      _errorSubscription = rpc.onError.listen((error) {
        appLogger.w('Discord RPC error: $error');
      });

      await rpc.initialize(_applicationId);
    } catch (e) {
      appLogger.w('Failed to initialize Discord RPC', error: e);
      // Only clean up when this attempt's client is still current. A stale
      // failure's client was already torn down by whoever replaced it, and
      // _teardownRpc disposes whatever _rpc holds now — the successor.
      if (identical(_rpc, rpc)) {
        _teardownRpc();
        _scheduleReconnect();
      }
    }
  }

  void _disconnect() {
    _reconnectTimer?.cancel();
    _teardownRpc();
  }

  /// Tear down the current client synchronously: cancel the event
  /// subscriptions and dispose the captured client. `_rpc` is nulled at once
  /// so a concurrently armed `_connect` (the reconnect timer's callback)
  /// builds a fresh client instead of bailing on the dead one. The cancel and
  /// dispose futures carry no work this class depends on.
  void _teardownRpc() {
    final rpc = _rpc;
    _rpc = null;
    _isConnected = false;

    unawaited(_readySubscription?.cancel());
    unawaited(_disconnectedSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    _readySubscription = null;
    _disconnectedSubscription = null;
    _errorSubscription = null;

    if (rpc == null) return;
    try {
      unawaited(rpc.dispose());
    } catch (e) {
      appLogger.d('Error disposing Discord RPC', error: e);
    }
  }

  void _scheduleReconnect() {
    if (!_isEnabled) return;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 30), () {
      if (_isEnabled && !_isConnected) {
        _connect();
      }
    });
  }

  Future<void> _uploadThumbnailAndUpdatePresence(int revision, MediaItem metadata, MediaServerClient client) async {
    final thumbnailUrl = await _uploadThumbnail(metadata, client);
    if (revision != _playbackRevision || !identical(_currentMetadata, metadata) || !identical(_currentClient, client)) {
      return;
    }
    _cachedThumbnailUrl = thumbnailUrl;
    await _updatePresence();
  }

  Future<String?> _uploadThumbnail(MediaItem metadata, MediaServerClient client) async {
    try {
      final thumbPath = _presenceThumbPath(metadata);
      if (thumbPath == null || thumbPath.isEmpty) return null;

      final cacheKey = '${client.backend.id}:$thumbPath';
      final cached = _posterUrlCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        appLogger.d('Using cached poster URL for: $cacheKey');
        return cached.url;
      }

      final imageUrl = _buildTranscodedThumbnailUrl(metadata, client, thumbPath);
      if (imageUrl.isEmpty) return null;

      final imageBytes = await httpClient.getBytes(
        imageUrl,
        headers: client.streamHeaders,
        timeout: const Duration(seconds: 10),
      );
      if (imageBytes.isEmpty) return null;
      if (imageBytes.length > _maxPosterUploadBytes) {
        appLogger.d('Discord poster upload skipped: transcoded image is ${imageBytes.length} bytes');
        return null;
      }

      final uploadResponse = await httpClient.post(
        _posterUploadUrl,
        body: imageBytes,
        headers: {'Content-Type': 'application/octet-stream'},
        timeout: const Duration(seconds: 15),
      );

      final responseData = uploadResponse.data;
      final uploadedUrl = switch (responseData) {
        {'url': final String url} when uploadResponse.statusCode >= 200 && uploadResponse.statusCode < 300 => url,
        _ => null,
      };
      final hostedUrl = _absolutePosterUrl(uploadedUrl);
      if (hostedUrl != null) {
        final receivedAt = DateTime.now();
        final expiresAt = posterCacheExpiryFromResponse(responseData, receivedAt: receivedAt);
        if (expiresAt.isAfter(receivedAt)) {
          _posterUrlCache[cacheKey] = _CachedUrl(hostedUrl, expiresAt);
          appLogger.d('Uploaded and cached thumbnail until $expiresAt: $hostedUrl');
        } else {
          appLogger.d('Uploaded thumbnail without caching expired URL: $hostedUrl');
        }
        return hostedUrl;
      }
    } catch (e) {
      appLogger.d('Failed to upload thumbnail to Satra poster host', error: e);
    }
    return null;
  }

  /// The image Discord shows: series poster for episodes (falling back to the
  /// episode thumb), album art for tracks — never the artist portrait Plex
  /// puts in `grandparentThumb` — and the item's own poster otherwise.
  String? _presenceThumbPath(MediaItem metadata) {
    if (metadata.kind == MediaKind.track) return metadata.thumbPath;
    return metadata.grandparentThumbPath ?? metadata.thumbPath;
  }

  String _buildTranscodedThumbnailUrl(MediaItem metadata, MediaServerClient client, String thumbPath) {
    final (double maxWidth, double maxHeight, ImageType imageType) = switch (metadata.kind) {
      MediaKind.track => (512, 512, ImageType.square),
      MediaKind.episode when metadata.grandparentThumbPath == null => (960, 540, ImageType.thumb),
      _ => (512, 768, ImageType.poster),
    };
    return MediaImageHelper.getOptimizedImageUrl(
      client: client,
      thumbPath: thumbPath,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      // Discord renders this, not us: ask for exactly the pixels it wants.
      pixelRatio: 1,
      imageType: imageType,
    );
  }

  String? _absolutePosterUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return url;
    }
    if (uri.hasScheme || uri.hasAuthority || !url.startsWith('/posters/')) {
      return null;
    }
    return Uri.parse(_posterUploadUrl).resolve(url).toString();
  }

  Future<void> _updatePresence() async {
    if (_rpc == null || !_isConnected || _currentMetadata == null) return;

    if (!_isPlaying && _currentMetadata!.kind == MediaKind.track) {
      await clearPresence();
      return;
    }

    try {
      final metadata = _currentMetadata!;
      final details = _buildDetails(metadata);
      final state = _isPlaying ? _buildState(metadata) : _buildPausedState(metadata);

      await _rpc!.setPresence(
        DiscordPresence(
          type: metadata.kind == MediaKind.track ? DiscordActivityType.listening : DiscordActivityType.watching,
          details: details,
          state: state,
          timestamps: _buildTimestamps(),
          statusDisplayType: DiscordStatusDisplayType.details,
          largeAsset: _cachedThumbnailUrl != null
              ? DiscordAsset(url: _cachedThumbnailUrl!, text: _buildLargeImageText(metadata))
              : null,
        ),
      );
    } catch (e) {
      appLogger.d('Failed to update Discord presence', error: e);
    }
  }

  Duration get _boundedPosition {
    final position = _timeline.position;
    if (position < Duration.zero) return Duration.zero;
    final duration = _timeline.duration;
    if (duration != null && duration > Duration.zero && position > duration) return duration;
    return position;
  }

  /// Paused video uses a static position; resume anchors the running timer
  /// to media time rather than counting the time spent paused.
  DiscordTimestamps? _buildTimestamps() {
    if (!_isPlaying) return null;
    final duration = _timeline.duration;
    final position = _boundedPosition.inMicroseconds;
    final start = clock.now().subtract(Duration(microseconds: (position / _playbackSpeed).round()));
    if (duration == null || duration <= Duration.zero) return DiscordTimestamps.started(start);
    final end = start.add(Duration(microseconds: (duration.inMicroseconds / _playbackSpeed).round()));
    return DiscordTimestamps.range(start, end);
  }

  String _buildPausedState(MediaItem metadata) {
    final position = formatDurationTimestamp(_boundedPosition);
    final duration = _timeline.duration;
    final progress = duration != null && duration > Duration.zero
        ? '$position / ${formatDurationTimestamp(duration)}'
        : position;
    final episode = metadata.kind == MediaKind.episode ? _buildState(metadata) : null;
    final state = 'Paused at $progress${episode == null || episode.isEmpty ? '' : ' · $episode'}';
    // Keep the pause indicator first even for an unusually long episode title.
    return String.fromCharCodes(state.runes.take(128));
  }

  /// Build the main "details" line (first line of presence)
  String _buildDetails(MediaItem metadata) {
    switch (metadata.kind) {
      case MediaKind.movie:
        final year = metadata.year != null ? ' (${metadata.year})' : '';
        return (metadata.title ?? '') + year;

      case MediaKind.episode:
        // Show: "Show Name" or just episode title if no show name
        return metadata.grandparentTitle ?? metadata.title ?? '';

      default:
        return metadata.title ?? '';
    }
  }

  /// Build the "state" line (second line of presence)
  String? _buildState(MediaItem metadata) {
    switch (metadata.kind) {
      case MediaKind.episode:
        // Format: "S1 E5 - Episode Title"
        final season = metadata.parentIndex;
        final episode = metadata.index;
        if (season != null && episode != null) {
          return 'S$season E$episode - ${metadata.title ?? ''}';
        }
        return metadata.title;

      case MediaKind.movie:
        return metadata.studio;

      case MediaKind.track:
        // Same artist the OS media session shows: the performing artist,
        // album artist as fallback.
        return metadata.trackArtistTitle;

      default:
        return null;
    }
  }

  /// Hover text for the large image: the album for a track, the series or
  /// title otherwise.
  String _buildLargeImageText(MediaItem metadata) {
    if (metadata.kind == MediaKind.track) {
      return metadata.albumTitle ?? metadata.trackArtistTitle ?? metadata.title ?? '';
    }
    return metadata.grandparentTitle ?? metadata.title ?? '';
  }
}
