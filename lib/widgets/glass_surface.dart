import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import '../theme/app_motion.dart';
import 'linux_video_blur.dart';

/// Drives a glass surface without placing its backdrop filter in an opacity layer.
class GlassTransitionScope extends InheritedNotifier<Animation<double>> {
  const GlassTransitionScope({super.key, required Animation<double> animation, required super.child})
    : super(notifier: animation);

  static Animation<double>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassTransitionScope>()?.notifier;
}

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

  /// Native video is composited below Flutter, outside a BackdropFilter's
  /// input. macOS uses an AppKit material; Linux blurs the video plane itself.
  final bool blurNativeVideo;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final scheme = Theme.of(context).colorScheme;
    final effects = AppMotion.effectsEnabled(context);
    final animation = GlassTransitionScope.of(context);
    final visibility = (animation?.value ?? 1.0).clamp(0.0, 1.0);
    final surface = tint ?? scheme.surface;
    final effectiveAlpha = (effects ? opacity : 1.0) * visibility;
    final pane = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        color: surface.withValues(alpha: effectiveAlpha),
        border: border
            ? Border.all(
                color: Colors.white.withValues(alpha: (scheme.brightness == Brightness.dark ? 0.10 : 0.8) * visibility),
              )
            : null,
        gradient: effects
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.055 * visibility),
                  Colors.transparent,
                ],
              )
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: animation == null ? child : Opacity(opacity: visibility, child: child),
      ),
    );
    final glass = ClipRRect(
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
              filter: ui.ImageFilter.blur(
                sigmaX: sigma * visibility,
                sigmaY: sigma * visibility,
                tileMode: ui.TileMode.clamp,
              ),
              child: pane,
            ),
    );
    if (effects && blurNativeVideo && !kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      return LinuxVideoBlur(borderRadius: borderRadius, sigma: sigma, child: glass);
    }
    return glass;
  }
}
