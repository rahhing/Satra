import 'dart:async';

import 'package:flutter/material.dart';

import '../media/media_item.dart';
import '../services/hover_preview_controller.dart';
import '../theme/app_motion.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import 'media_preview_surface.dart';

/// Artwork-only feedback: captions keep their layout and every overlay shares
/// the exact same silhouette as the poster, including Continue Watching.
class MediaCardArtwork extends StatefulWidget {
  const MediaCardArtwork({
    super.key,
    required this.child,
    required this.borderRadius,
    this.item,
    this.previewOnHover = false,
  });

  final Widget child;
  final double borderRadius;
  final MediaItem? item;
  final bool previewOnHover;

  @override
  State<MediaCardArtwork> createState() => _MediaCardArtworkState();
}

class _MediaCardArtworkState extends State<MediaCardArtwork> with WidgetsBindingObserver {
  final _previews = HoverPreviewController.instance;
  Timer? _hoverDelay;
  HoverPreviewSession? _session;
  bool _hovered = false;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _previews.addListener(_previewChanged);
  }

  void _previewChanged() {
    if (_previews.isOwner(this)) return;
    _hoverDelay?.cancel();
    if (_session != null && mounted) setState(() => _session = null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled && (ModalRoute.isCurrentOf(context) ?? true);
    if (!_visible || MediaQuery.disableAnimationsOf(context)) _stop();
  }

  @override
  void didUpdateWidget(MediaCardArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.globalKey != widget.item?.globalKey || !widget.previewOnHover) _stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      setState(() {
        _hovered = false;
        _stop();
      });
    }
  }

  void _enter() {
    if (!PlatformDetector.isDesktopOS() || PlatformDetector.isTVDevice()) return;
    _hoverDelay?.cancel();
    setState(() => _hovered = true);
    if (_session != null) return;
    final item = widget.item;
    if (!widget.previewOnHover || item == null || !_visible || MediaQuery.disableAnimationsOf(context)) return;
    _hoverDelay?.cancel();
    _hoverDelay = Timer(const Duration(milliseconds: 650), () async {
      if (!mounted || !_hovered || !_visible) return;
      final client = context.getMediaClientForItemOrNull(item);
      if (client == null) return;
      final session = await _previews.start(
        this,
        item,
        client,
        onSession: (session) {
          if (mounted && _hovered && _visible && _previews.isOwner(this)) setState(() => _session = session);
        },
      );
      if (!mounted || !_hovered || !_visible || !_previews.isOwner(this)) return;
      setState(() => _session = session);
    });
  }

  void _stop() {
    _hoverDelay?.cancel();
    _hoverDelay = null;
    _session = null;
    unawaited(_previews.stop(owner: this));
  }

  void _exit() {
    setState(() => _hovered = false);
    _hoverDelay?.cancel();
    if (_session == null || !_session!.ready.value) {
      _stop();
      return;
    }
    // Let the texture dissolve back into its poster before releasing it.
    // Clicks, scrolling, route changes, and backgrounding still stop at once.
    _hoverDelay = Timer(AppMotion.duration(context), () {
      if (mounted) setState(_stop);
    });
  }

  @override
  void deactivate() {
    _hovered = false;
    _stop();
    super.deactivate();
  }

  @override
  void dispose() {
    _previews.removeListener(_previewChanged);
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.borderRadius);
    final effects = AppMotion.effectsEnabled(context);
    final session = _session;
    return MouseRegion(
      onEnter: (event) {
        if (event.buttons == 0) _enter();
      },
      onExit: (_) => _exit(),
      child: Listener(
        onPointerDown: (_) {
          if (_session != null || _hoverDelay != null) setState(_stop);
        },
        child: AnimatedContainer(
          duration: AppMotion.duration(context),
          curve: AppMotion.curve,
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: _hovered && effects
                ? [BoxShadow(color: Colors.black.withValues(alpha: 0.38), blurRadius: 22, offset: const Offset(0, 10))]
                : const [],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: Colors.white.withValues(alpha: _hovered ? 0.65 : 0.18),
              width: _hovered ? 1 : 0.7,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              children: [
                MediaPreviewSurface(
                  poster: widget.child,
                  ready: session?.ready,
                  showPreview: _hovered,
                  preview: session == null
                      ? null
                      : ValueListenableBuilder<bool>(
                          valueListenable: session.ready,
                          builder: (context, loaded, _) {
                            final textureId = session.textureId;
                            if (!loaded || textureId == null) return const SizedBox.shrink();
                            return ClipRRect(
                              borderRadius: radius,
                              child: FittedBox(
                                fit: BoxFit.cover,
                                clipBehavior: Clip.hardEdge,
                                child: SizedBox(
                                  width: 480,
                                  height: 270,
                                  child: Texture(textureId: textureId, filterQuality: FilterQuality.low),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (_session case final session?)
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: IgnorePointer(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: session.ready,
                        builder: (context, loaded, _) => AnimatedOpacity(
                          opacity: loaded && _hovered ? 1 : 0,
                          duration: AppMotion.duration(context, AppMotion.fast),
                          child: const Icon(Icons.volume_off_rounded, size: 18, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
