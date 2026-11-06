import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import '../theme/app_motion.dart';

/// A translucent pane with one GPU backdrop blur clipped to its bounds.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.tint,
    this.sigma = 28,
    this.opacity = 0.42,
    this.border = true,
    this.enabled = true,
    this.blurNativeVideo = false,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color? tint;
  final double sigma;
  final double opacity;
  final bool border;
  final bool enabled;

  /// macOS video is composited below Flutter, outside a BackdropFilter's
  /// input. Player overlays use an AppKit material to sample that surface.
  final bool blurNativeVideo;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final scheme = Theme.of(context).colorScheme;
    final effects = AppMotion.effectsEnabled(context);
    final surface = tint ?? scheme.surface;
    final effectiveAlpha = effects ? opacity : 1.0;
    final pane = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        color: surface.withValues(alpha: effectiveAlpha),
        border: border
            ? Border.all(color: Colors.white.withValues(alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.8))
            : null,
        gradient: effects
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white.withValues(alpha: 0.055), Colors.transparent],
              )
            : null,
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
    return ClipRRect(
      borderRadius: borderRadius,
      child: effects && blurNativeVideo && !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
          ? Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: AppKitView(
                      key: ValueKey(scheme.brightness),
                      viewType: 'com.satra/video_sheet_blur',
                      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                      creationParams: {'dark': scheme.brightness == Brightness.dark},
                      creationParamsCodec: const StandardMessageCodec(),
                    ),
                  ),
                ),
                pane,
              ],
            )
          : BackdropFilter(
              enabled: effects,
              filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: ui.TileMode.clamp),
              child: pane,
            ),
    );
  }
}
