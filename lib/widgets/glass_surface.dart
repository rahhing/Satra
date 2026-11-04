import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// A bounded frosted pane. Uses a crisp translucent surface with subtle
/// specular border and gradient highlight without per-frame GPU texture
/// readback blurs that drop frames during scrolling and crossfades.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.tint,
    this.sigma = 28,
    this.opacity = 0.76,
    this.border = true,
    this.enabled = true,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color? tint;
  final double sigma;
  final double opacity;
  final bool border;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final scheme = Theme.of(context).colorScheme;
    final effects = AppMotion.effectsEnabled(context);
    final surface = tint ?? scheme.surface;
    final effectiveAlpha = effects ? (opacity < 0.88 ? (opacity + 0.14).clamp(0.0, 0.96) : opacity) : 1.0;
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
      child: pane,
    );
  }
}
