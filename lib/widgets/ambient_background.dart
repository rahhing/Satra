import 'package:flutter/material.dart';

/// Quiet pools of palette colour behind onboarding and account surfaces.
/// Painted gradients keep the background still and inexpensive while chrome
/// above them supplies the actual backdrop blur.
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        gradient: RadialGradient(
          center: const Alignment(-0.8, -0.7),
          radius: 1.4,
          colors: [scheme.primary.withValues(alpha: 0.10), scheme.surface.withValues(alpha: 0)],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(1, 0.9),
            radius: 1.1,
            colors: [scheme.primary.withValues(alpha: 0.05), scheme.surface.withValues(alpha: 0)],
          ),
        ),
        child: child,
      ),
    );
  }
}
