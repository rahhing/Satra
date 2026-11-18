import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/backdrop_cache.dart';
import '../theme/app_motion.dart';

import '../media/media_server_client.dart';
import '../services/device_performance.dart';
import '../utils/media_image_helper.dart';
import 'artwork_focal_point.dart';
import 'optimized_media_image.dart';

/// Shares only the last painted backdrop across retained browsing pages.
/// Foreground pages keep their own focus/scroll state and never overlap.
class BackdropTransitionScope extends StatefulWidget {
  const BackdropTransitionScope({super.key, required this.child});
  final Widget child;

  @override
  State<BackdropTransitionScope> createState() => _BackdropTransitionScopeState();
}

class _BackdropTransitionScopeState extends State<BackdropTransitionScope> {
  final memory = _BackdropHandoff();

  @override
  void dispose() {
    memory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _BackdropMemory(memory: memory, child: widget.child);
}

class _BackdropMemory extends InheritedWidget {
  const _BackdropMemory({required this.memory, required super.child});
  final _BackdropHandoff memory;

  @override
  bool updateShouldNotify(_BackdropMemory oldWidget) => memory != oldWidget.memory;
}

class _BackdropHandoff {
  ImageInfo? frame;
  Object? key;

  void remember(ImageInfo image, Object? artworkKey) {
    if (key == artworkKey && frame?.image.isCloneOf(image.image) == true) return;
    frame?.dispose();
    frame = image.clone();
    key = artworkKey;
  }

  void dispose() => frame?.dispose();
}

Future<bool> _defaultLocalFileExists(File file) => file.exists();

/// Controls and observes artwork rotation without rebuilding the artwork when
/// a page marker changes. The desktop spotlight places its controls above the
/// backdrop's blur and scrims.
class BackdropRotationController extends ChangeNotifier {
  _CyclingMediaBackdropState? _state;
  bool _notificationPending = false;
  bool _disposed = false;

  List<String> get _paths => _state?._rotationPaths.where((p) => !_state!._failedPaths.contains(p)).toList() ?? [];
  int get itemCount => _paths.length;
  int get currentIndex => _paths.indexOf(_state?._currentPath ?? '').clamp(0, itemCount > 0 ? itemCount - 1 : 0);
  bool get paused => _state?._paused ?? false;

  void select(int index) {
    final paths = _paths;
    if (index < 0 || index >= paths.length) return;
    _state?._selectPath(paths[index]);
  }

  void togglePaused() => _state?._togglePaused();

  void _update(_CyclingMediaBackdropState state) {
    _state = state;
    if (_notificationPending || _disposed) return;
    _notificationPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  void _detach(_CyclingMediaBackdropState state) {
    if (identical(_state, state)) _state = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _state = null;
    super.dispose();
  }
}

/// Displays server artwork and rotates through multiple backdrops in order.
///
/// The settled image remains visible until the incoming provider produces a
/// frame. Failed candidates are skipped without flashing an empty frame.
class CyclingMediaBackdrop extends StatefulWidget {
  const CyclingMediaBackdrop({
    super.key,
    required this.mediaKey,
    required this.imagePaths,
    required this.client,
    required this.width,
    required this.height,
    required this.fallbackColor,
    this.fallbackImagePaths = const [],
    this.localArtworkPathResolver,
    this.imageProviderResolver,
    this.allowNetwork = true,
    this.localFileExists = _defaultLocalFileExists,
    this.active = true,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.focusCrop = false,
    this.rotationInterval = const Duration(seconds: 10),
    this.fadeDuration = const Duration(milliseconds: 280),
    this.controller,
    this.frameBuilder,
  });

  final Object? mediaKey;
  final List<String> imagePaths;
  final List<String> fallbackImagePaths;
  final MediaServerClient? client;
  final String? Function(String artworkPath)? localArtworkPathResolver;

  /// Overrides provider construction for deterministic widget tests.
  @visibleForTesting
  final ImageProvider? Function(String artworkPath)? imageProviderResolver;

  /// Overrides local file checks for deterministic widget tests.
  @visibleForTesting
  final Future<bool> Function(File file) localFileExists;
  final bool allowNetwork;
  final bool active;
  final double width;
  final double height;
  final BoxFit fit;
  final Alignment alignment;
  final bool focusCrop;
  final Color fallbackColor;
  final Duration rotationInterval;
  final Duration fadeDuration;
  final BackdropRotationController? controller;
  final Widget Function(BuildContext context, Widget artwork)? frameBuilder;

  @override
  State<CyclingMediaBackdrop> createState() => _CyclingMediaBackdropState();
}

class _CyclingMediaBackdropState extends State<CyclingMediaBackdrop> with WidgetsBindingObserver {
  bool _paused = false;
  Timer? _rotationTimer;
  late List<String> _rotationPaths;
  late List<String> _fallbackPaths;
  final Set<String> _failedPaths = <String>{};
  final Set<String> _pendingProviderFailures = <String>{};
  int _rotationIndex = 0;
  bool _lifecycleResumed = true;
  bool _tickerEnabled = true;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycleResumed = switch (WidgetsBinding.instance.lifecycleState) {
      null || AppLifecycleState.resumed => true,
      _ => false,
    };
    _replacePaths();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    final disableAnimations = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_disableAnimations != disableAnimations) {
      _disableAnimations = disableAnimations;
    }
    _restartRotationTimer();
  }

  @override
  void didUpdateWidget(covariant CyclingMediaBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) oldWidget.controller?._detach(this);
    final pathsChanged =
        widget.mediaKey != oldWidget.mediaKey ||
        !listEquals(widget.imagePaths, oldWidget.imagePaths) ||
        !listEquals(widget.fallbackImagePaths, oldWidget.fallbackImagePaths);
    if (pathsChanged) {
      _replacePaths();
    }
    if (pathsChanged || widget.active != oldWidget.active || widget.rotationInterval != oldWidget.rotationInterval) {
      _restartRotationTimer();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleResumed = state == AppLifecycleState.resumed;
    if (_lifecycleResumed) {
      _restartRotationTimer();
    } else {
      _rotationTimer?.cancel();
      _rotationTimer = null;
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    WidgetsBinding.instance.removeObserver(this);
    _rotationTimer?.cancel();
    super.dispose();
  }

  void _replacePaths() {
    _rotationPaths = _uniquePaths(widget.imagePaths);
    final rotating = _rotationPaths.toSet();
    _fallbackPaths = _uniquePaths(widget.fallbackImagePaths).where((path) => !rotating.contains(path)).toList();
    _failedPaths.clear();
    _pendingProviderFailures.clear();
    _rotationIndex = 0;
  }

  static List<String> _uniquePaths(List<String> paths) {
    if (paths.isEmpty) return const [];
    final unique = <String>[];
    for (final path in paths) {
      if (path.isEmpty || unique.contains(path)) continue;
      unique.add(path);
    }
    return unique;
  }

  int get _usableRotationCount => _rotationPaths.where((path) => !_failedPaths.contains(path)).length;

  bool get _canRotate =>
      widget.active &&
      !_paused &&
      !DevicePerformance.isReduced &&
      _lifecycleResumed &&
      _tickerEnabled &&
      !_disableAnimations &&
      _usableRotationCount > 1;

  void _restartRotationTimer() {
    _rotationTimer?.cancel();
    _rotationTimer = null;
    if (!_canRotate) return;
    _rotationTimer = Timer(widget.rotationInterval, _handleRotationTimer);
  }

  void _handleRotationTimer() {
    _rotationTimer = null;
    if (!mounted) return;
    if (!_canRotate) return;
    _advanceRotation();
    _restartRotationTimer();
  }

  void _selectPath(String path) {
    final index = _rotationPaths.indexOf(path);
    if (index < 0 || _failedPaths.contains(path)) return;
    setState(() => _rotationIndex = index);
    _restartRotationTimer();
  }

  void _togglePaused() {
    setState(() => _paused = !_paused);
    _restartRotationTimer();
  }

  void _advanceRotation() {
    if (_rotationPaths.isEmpty) return;
    for (var offset = 1; offset <= _rotationPaths.length; offset++) {
      final next = (_rotationIndex + offset) % _rotationPaths.length;
      if (_failedPaths.contains(_rotationPaths[next])) continue;
      if (next == _rotationIndex) return;
      setState(() => _rotationIndex = next);
      return;
    }
  }

  String? get _currentPath {
    if (_rotationPaths.isNotEmpty && !_failedPaths.contains(_rotationPaths[_rotationIndex])) {
      return _rotationPaths[_rotationIndex];
    }
    for (var offset = 0; offset < _rotationPaths.length; offset++) {
      final index = (_rotationIndex + offset) % _rotationPaths.length;
      if (!_failedPaths.contains(_rotationPaths[index])) return _rotationPaths[index];
    }
    for (final path in _fallbackPaths) {
      if (!_failedPaths.contains(path)) return path;
    }
    return null;
  }

  void _handleImageError(Object? key) {
    final path = key is String ? key : null;
    if (!mounted || path == null || _failedPaths.contains(path)) return;
    setState(() {
      _failedPaths.add(path);
      _pendingProviderFailures.remove(path);
      final rotationPosition = _rotationPaths.indexOf(path);
      if (rotationPosition >= 0) {
        for (var offset = 1; offset <= _rotationPaths.length; offset++) {
          final next = (rotationPosition + offset) % _rotationPaths.length;
          if (_failedPaths.contains(_rotationPaths[next])) continue;
          _rotationIndex = next;
          break;
        }
      }
    });
    _restartRotationTimer();
  }

  ImageProvider? _providerFor(BuildContext context, String path, File? localFile) {
    final providerOverride = widget.imageProviderResolver;
    if (providerOverride != null) return providerOverride(path);

    final size = MediaQuery.sizeOf(context);
    final width = widget.width.isFinite && widget.width > 0 ? widget.width : size.width;
    final height = widget.height.isFinite && widget.height > 0 ? widget.height : size.height;
    final pixelRatio = MediaImageHelper.artworkPixelRatio(context, imageType: ImageType.art);
    final (memWidth, memHeight) = MediaImageHelper.getMemCacheDimensions(
      displayWidth: (width * pixelRatio).round(),
      displayHeight: (height * pixelRatio).round(),
      imageType: ImageType.art,
    );

    if (localFile != null) {
      return MediaImageHelper.boundedDecode(FileImage(localFile), memWidth: memWidth, memHeight: memHeight);
    }
    if (!widget.allowNetwork) return null;

    final imageUrl = MediaImageHelper.getOptimizedImageUrl(
      client: widget.client,
      thumbPath: path,
      maxWidth: width,
      maxHeight: height,
      pixelRatio: pixelRatio,
      imageType: ImageType.art,
    );
    if (imageUrl.isEmpty) return null;
    return MediaImageHelper.serverArtworkProvider(imageUrl: imageUrl, memWidth: memWidth, memHeight: memHeight);
  }

  void _reportMissingProvider(String path) {
    if (!_pendingProviderFailures.add(path)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handleImageError(path);
    });
  }

  Widget _buildCrossfade(
    BuildContext context,
    String? path, {
    required LocalFileResolution localResolution,
    File? localFile,
  }) {
    final pending = localResolution == LocalFileResolution.pending;
    final provider = path == null || pending ? null : _providerFor(context, path, localFile);
    if (path != null && provider == null && !pending) _reportMissingProvider(path);
    final compose = widget.frameBuilder;
    if (compose != null || widget.focusCrop) {
      return _ComposedBackdropArtwork(
        artworkKey: (widget.mediaKey, path),
        image: provider,
        pending: pending,
        fit: widget.fit,
        alignment: widget.alignment,
        focusCrop: widget.focusCrop,
        fallbackColor: widget.fallbackColor,
        duration: _disableAnimations ? Duration.zero : DevicePerformance.reducedDuration(widget.fadeDuration),
        compose: compose,
        onImageError: () => _handleImageError(path),
      );
    }
    final fadeDuration = _disableAnimations ? Duration.zero : DevicePerformance.reducedDuration(widget.fadeDuration);

    return _BackdropArtworkCrossfade(
      artworkKey: (widget.mediaKey, path),
      imageErrorKey: path,
      image: provider,
      pending: pending,
      duration: fadeDuration,
      fit: widget.fit,
      alignment: widget.alignment,
      fallbackColor: widget.fallbackColor,
      onImageError: _handleImageError,
    );
  }

  @override
  Widget build(BuildContext context) {
    widget.controller?._update(this);
    return _buildArtwork(context);
  }

  Widget _buildArtwork(BuildContext context) {
    final path = _currentPath;
    if (path == null) {
      return _buildCrossfade(context, null, localResolution: LocalFileResolution.missing);
    }

    final localPath = widget.localArtworkPathResolver?.call(path);
    if (localPath == null) {
      return _buildCrossfade(context, path, localResolution: LocalFileResolution.missing);
    }

    return ResolvedLocalFile(
      path: localPath,
      cacheMissing: true,
      fileExists: widget.localFileExists,
      builder: (context, resolution, file) =>
          _buildCrossfade(context, path, localResolution: resolution, localFile: file),
    );
  }
}

/// Resolves artwork once before composing the blurred fill and sharp corner.
/// Duplicating Image widgets lets their independent async lifecycles briefly
/// show different titles when returning to a cached backdrop during scrolling.
class _ComposedBackdropArtwork extends StatefulWidget {
  const _ComposedBackdropArtwork({
    required this.artworkKey,
    required this.image,
    required this.pending,
    required this.fit,
    required this.alignment,
    required this.focusCrop,
    required this.fallbackColor,
    required this.compose,
    required this.duration,
    required this.onImageError,
  });

  final Object artworkKey;
  final ImageProvider? image;
  final bool pending;
  final BoxFit fit;
  final Alignment alignment;
  final bool focusCrop;
  final Color fallbackColor;
  final Widget Function(BuildContext, Widget)? compose;
  final Duration duration;
  final VoidCallback onImageError;

  @override
  State<_ComposedBackdropArtwork> createState() => _ComposedBackdropArtworkState();
}

class _ComposedBackdropArtworkState extends State<_ComposedBackdropArtwork> with SingleTickerProviderStateMixin {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _displayed;
  Object? _displayedKey;
  ImageInfo? _previous;
  Object? _previousKey;
  late final AnimationController _fade = AnimationController(vsync: this, value: 1)..addStatusListener(_fadeStatus);
  late final Animation<double> _opacity = _fade.drive(CurveTween(curve: AppMotion.curve));
  _BackdropHandoff? _handoff;
  bool _active = false;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _handoff = context.dependOnInheritedWidgetOfExactType<_BackdropMemory>()?.memory;
    final active = TickerMode.valuesOf(context).enabled;
    final wasActive = _active;
    if (wasActive && !active) {
      final frame = _opacity.value >= 0.5 ? _displayed : _previous;
      final key = _opacity.value >= 0.5 ? _displayedKey : _previousKey;
      if (frame != null) _handoff?.remember(frame, key);
    }
    _active = active;
    if (active && !wasActive) {
      final memory = _handoff;
      if (memory?.frame != null && memory!.key != _displayedKey) {
        _retire(_previous);
        _previous = memory.frame!.clone();
        _previousKey = memory.key;
        _fade.value = 0;
        if (_displayed != null) _beginFade();
      }
    }
    _resolve();
  }

  @override
  void didUpdateWidget(_ComposedBackdropArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkKey != widget.artworkKey ||
        oldWidget.image != widget.image ||
        oldWidget.pending != widget.pending) {
      _resolve();
    }
  }

  void _disconnect() {
    ++_generation;
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  // Render objects may still reference the outgoing frame until this paint.
  void _retire(ImageInfo? frame) {
    if (frame != null) WidgetsBinding.instance.addPostFrameCallback((_) => frame.dispose());
  }

  void _fadeStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _retire(_previous);
    _previous = null;
    _previousKey = null;
    if (_active && _displayed != null) _handoff?.remember(_displayed!, _displayedKey);
    if (mounted) setState(() {});
  }

  void _beginFade({double from = 0}) {
    final duration = widget.duration;
    _fade.duration = duration;
    if (!_active || _previous == null || duration == Duration.zero) {
      _fade.value = 1;
      // Setting an already-completed animation doesn't emit another status.
      _fadeStatus(AnimationStatus.completed);
    } else {
      _fade.forward(from: from);
    }
  }

  void _replaceFrame(ImageInfo frame) {
    if (_displayedKey == widget.artworkKey) {
      if (_displayed?.image.isCloneOf(frame.image) == true) {
        // Capture/focus/metrics changes may resolve the same cached stream.
        // Keep the current transition running rather than restarting its fade.
        frame.dispose();
        return;
      }
      _retire(_displayed);
      _displayed = frame;
      setState(() {});
      return;
    }
    final wasVisualOpacity = _opacity.value;
    final reversingToPrevious = _previous != null && _previousKey == widget.artworkKey;
    _fade.stop();
    if (_displayed != null) {
      if (_previous == null || reversingToPrevious || wasVisualOpacity >= 0.5) {
        _retire(_previous);
        _previous = _displayed;
        _previousKey = _displayedKey;
      } else {
        _retire(_displayed);
      }
    }
    _displayed = frame;
    _displayedKey = widget.artworkKey;
    _beginFade(from: reversingToPrevious ? (1.0 - wasVisualOpacity).clamp(0.0, 1.0) : 0.0);
    setState(() {});
  }

  void _resolve() {
    if (widget.pending || widget.image == null) {
      _disconnect();
      return; // Keep a complete frame instead of flashing a loading colour.
    }
    final provider = widget.image!;
    final configuration = createLocalImageConfiguration(context);
    final stream = provider.resolve(configuration);
    // Dependency notifications during screenshots must not detach and reload
    // a live image or queue another transition to the same frame.
    if (_stream?.key == stream.key) return;
    _disconnect();
    final generation = _generation;
    _stream = stream;
    _listener = ImageStreamListener(
      (frame, synchronous) {
        if (!mounted || generation != _generation) {
          frame.dispose();
          return;
        }
        _replaceFrame(frame);
        context.read<BackdropCache?>()?.retain(provider, configuration);
      },
      onError: (Object error, StackTrace? stackTrace) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation) widget.onImageError();
        });
      },
    );
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    _disconnect();
    _fade.dispose();
    _displayed?.dispose();
    _previous?.dispose();
    super.dispose();
  }

  Widget _image(ImageInfo frame, Object? key, {Animation<double>? opacity}) {
    Widget raw(Alignment alignment, {Key? key}) => RawImage(
      key: key,
      image: frame.image,
      scale: frame.scale,
      fit: widget.fit,
      alignment: alignment,
      opacity: opacity,
      filterQuality: MediaImageHelper.artworkFilterQuality(context, ImageType.art),
    );

    if (!widget.focusCrop || DevicePerformance.isReduced) return raw(widget.alignment, key: ValueKey(key));
    final imageSize = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    return LayoutBuilder(
      key: ValueKey(key),
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.isEmpty || !size.isFinite) return raw(widget.alignment);
        final visible = applyBoxFit(widget.fit, imageSize, size).source;
        if (visible.width / imageSize.width > .92 && visible.height / imageSize.height > .92) {
          return raw(widget.alignment);
        }
        return FutureBuilder<Offset>(
          future: ArtworkFocalPoint.resolve((key, imageSize), frame.image),
          builder: (context, snapshot) {
            final point = snapshot.data;
            return raw(
              point == null ? widget.alignment : ArtworkFocalPoint.alignment(point, imageSize, size, widget.fit),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = _displayed;
    final previous = _previous;
    // Blend the decoded pixels before composing the sharp corner/blurred
    // fill. RawImage applies alpha in its draw paint, avoiding full-screen
    // opacity layers and a second blur/mask pass on every animation frame.
    final artwork = Stack(
      fit: StackFit.expand,
      children: [
        if (previous != null) _image(previous, _previousKey),
        if (current != null) _image(current, _displayedKey, opacity: previous == null ? null : _opacity),
        if (previous == null && current == null) ColoredBox(color: widget.fallbackColor),
      ],
    );
    return widget.compose?.call(context, artwork) ?? artwork;
  }
}

class _BackdropArtworkCrossfade extends StatefulWidget {
  const _BackdropArtworkCrossfade({
    required this.artworkKey,
    required this.imageErrorKey,
    required this.image,
    required this.pending,
    required this.duration,
    required this.fit,
    required this.alignment,
    required this.fallbackColor,
    required this.onImageError,
  });

  final Object? artworkKey;
  final Object? imageErrorKey;
  final ImageProvider? image;
  final bool pending;
  final Duration duration;
  final BoxFit fit;
  final Alignment alignment;
  final Color fallbackColor;
  final ValueChanged<Object?> onImageError;

  @override
  State<_BackdropArtworkCrossfade> createState() => _BackdropArtworkCrossfadeState();
}

class _BackdropArtworkCrossfadeState extends State<_BackdropArtworkCrossfade> with SingleTickerProviderStateMixin {
  late final AnimationController _fade;

  /// The key this state last acted on. Not interchangeable with
  /// `oldWidget.artworkKey`: the element can be updated more than once between
  /// the frames this state reacts to, so `oldWidget` can still carry a key this
  /// state has already transitioned away from, which would restart a finished
  /// fade and leave both layers painted.
  late Object? _currentKey = widget.artworkKey;
  late ImageProvider? _base = widget.pending ? null : widget.image;
  late Object? _baseErrorKey = widget.imageErrorKey;
  ImageProvider? _incoming;
  Object? _incomingErrorKey;
  bool _incomingIsColor = false;
  bool _fadeStarted = false;
  int _transitionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: widget.duration);
  }

  @override
  void didUpdateWidget(covariant _BackdropArtworkCrossfade oldWidget) {
    super.didUpdateWidget(oldWidget);
    _fade.duration = widget.duration;
    if (widget.artworkKey == _currentKey) {
      if (widget.pending) return;
      if (oldWidget.pending) {
        _transitionToIncoming();
        return;
      }
      if (widget.image != null && widget.image != _base && _incoming == null) {
        _base = widget.image;
        _baseErrorKey = widget.imageErrorKey;
      }
      return;
    }

    _currentKey = widget.artworkKey;
    if (widget.pending) {
      if (_base == null && _incoming != null && _fade.value == 1) {
        _base = _incoming;
        _baseErrorKey = _incomingErrorKey;
      }
      setState(() {
        _fade.stop();
        _dropIncoming();
      });
      return;
    }
    if (widget.image != null && widget.image == _base) {
      _baseErrorKey = widget.imageErrorKey;
      _dropIncoming();
      return;
    }

    _transitionToIncoming();
  }

  void _transitionToIncoming() {
    ++_transitionGeneration;
    setState(() {
      _fade.stop();
      _fade.value = 0;
      _fadeStarted = false;
      _incoming = widget.image;
      _incomingErrorKey = widget.imageErrorKey;
      _incomingIsColor = widget.image == null;
      if (_incoming == null) _startFade();
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _startFade() {
    if (_fadeStarted) return;
    _fadeStarted = true;
    final generation = _transitionGeneration;
    _fade.forward().whenComplete(() {
      if (mounted && generation == _transitionGeneration) _promoteIncoming();
    });
  }

  void _promoteIncoming() {
    if (!mounted) return;
    setState(() {
      _base = _incoming;
      _baseErrorKey = _incomingErrorKey;
      _dropIncoming();
    });
  }

  void _dropIncoming() {
    ++_transitionGeneration;
    _incoming = null;
    _incomingErrorKey = null;
    _incomingIsColor = false;
    _fadeStarted = false;
    _fade.value = 0;
  }

  void _reportError(Object? imageErrorKey) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onImageError(imageErrorKey);
    });
  }

  Widget _image(ImageProvider provider, Object? imageErrorKey, {Animation<double>? opacity}) {
    final incoming = opacity != null;
    return Image(
      key: incoming ? ValueKey<ImageProvider>(provider) : null,
      image: provider,
      fit: widget.fit,
      filterQuality: MediaImageHelper.artworkFilterQuality(context, ImageType.art),
      alignment: widget.alignment,
      excludeFromSemantics: true,
      gaplessPlayback: true,
      opacity: opacity,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame != null || wasSynchronouslyLoaded) {
          context.read<BackdropCache?>()?.retain(provider, createLocalImageConfiguration(context));
          if (incoming) _startFade();
        }
        return child;
      },
      errorBuilder: (context, error, stackTrace) {
        _reportError(imageErrorKey);
        return incoming ? const SizedBox.shrink() : ColoredBox(color: widget.fallbackColor);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_base != null) _image(_base!, _baseErrorKey) else ColoredBox(color: widget.fallbackColor),
        if (_incoming != null) _image(_incoming!, _incomingErrorKey, opacity: _fade),
        if (_incomingIsColor)
          AnimatedBuilder(
            animation: _fade,
            builder: (context, _) =>
                ColoredBox(color: widget.fallbackColor.withValues(alpha: widget.fallbackColor.a * _fade.value)),
          ),
      ],
    );
  }
}
