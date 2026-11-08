import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../media/media_item.dart';
import '../media/media_server_client.dart';
import 'playback_initialization_types.dart';

/// A preview has a texture of its own. There is intentionally no watch-state
/// store, playback reporter, scrobbler, queue, or normal player session here.
abstract class HoverPreviewSession {
  int? get textureId;
  ValueListenable<bool> get ready;
  Future<void> open(String url, Map<String, String> headers, {required Duration startPosition});
  Future<void> dispose();
}

class _TexturePreviewSession implements HoverPreviewSession {
  static const _channel = MethodChannel('com.plezy/hover_preview');

  @override
  int? textureId;
  @override
  final ValueNotifier<bool> ready = ValueNotifier(false);
  bool _disposed = false;

  @override
  Future<void> open(String url, Map<String, String> headers, {required Duration startPosition}) async {
    final createdId = await _channel.invokeMethod<int>('create');
    if (_disposed || createdId == null) {
      if (createdId != null) {
        unawaited(_channel.invokeMethod<void>('dispose', {'textureId': createdId}));
      }
      return;
    }
    textureId = createdId;
    final loaded = await _channel
        .invokeMethod<bool>('open', {
          'textureId': createdId,
          'url': url,
          'headers': headers,
          'startMs': startPosition.inMilliseconds,
        })
        .timeout(const Duration(seconds: 15), onTimeout: () => false);
    if (_disposed || loaded != true) return;
    ready.value = true;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ready.value = false;
    final id = textureId;
    textureId = null;
    try {
      await _channel.invokeMethod<void>('dispose', id == null ? null : {'textureId': id});
    } catch (_) {
      // Ignore missing plugin on platforms without hover preview support.
    } finally {
      ready.dispose();
    }
  }
}

/// One hover owns the preview. Generation checks prevent a late server response
/// or player startup from reviving a card the pointer has already left.
class HoverPreviewController extends ChangeNotifier {
  HoverPreviewController({HoverPreviewSession Function()? createSession})
    : _createSession = createSession ?? _TexturePreviewSession.new;

  static final instance = HoverPreviewController();
  final HoverPreviewSession Function() _createSession;
  Object? _owner;
  HoverPreviewSession? _session;
  int _generation = 0;
  Future<void> _retirement = Future.value();

  bool isOwner(Object owner) => identical(owner, _owner);

  Future<HoverPreviewSession?> start(
    Object owner,
    MediaItem item,
    MediaServerClient client, {
    ValueChanged<HoverPreviewSession>? onSession,
  }) async {
    final retirement = stop();
    final generation = ++_generation;
    _owner = owner;
    bool current() => generation == _generation && identical(_owner, owner);
    try {
      await retirement;
      if (!current()) return null;
      final resumePosition = Duration(milliseconds: math.max(0, item.viewOffsetMs ?? 0));
      final source = await client.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0, startPosition: resumePosition),
      );
      if (!current() || source.videoUrl == null || source.isTranscoding) return null;
      await _retirement;
      if (!current()) return null;
      final session = _createSession();
      _session = session;
      // Mount the texture underneath the still-visible poster before opening
      // the stream. Linux needs the texture mounted for frame notifications.
      onSession?.call(session);
      final partOffset = source.mediaInfo?.partTimeline?.current.start ?? Duration.zero;
      final sourcePosition = resumePosition >= partOffset ? resumePosition - partOffset : Duration.zero;
      await session.open(source.videoUrl!, client.streamHeaders, startPosition: sourcePosition);
      if (!current()) return null;
      return session;
    } catch (_) {
      if (current()) await stop(owner: owner);
      // An unavailable/unsupported preview quietly keeps the poster visible.
      return null;
    }
  }

  Future<void> stop({Object? owner}) {
    if (owner != null && !identical(owner, _owner)) return Future.value();
    ++_generation;
    _owner = null;
    final session = _session;
    _session = null;
    notifyListeners();
    if (session != null) {
      _retirement = _retirement.then((_) => session.dispose()).catchError((Object _) {});
    }
    return _retirement;
  }
}
