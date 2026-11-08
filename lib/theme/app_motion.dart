import 'package:flutter/material.dart';

import '../services/device_performance.dart';

/// Shared motion for the browsing UI, including the OS reduce-motion setting.
abstract final class AppMotion {
  // A quick response that gently settles, without overshooting artwork/text.
  static const curve = Cubic(0.22, 1, 0.36, 1);
  static const fast = Duration(milliseconds: 180);
  static const standard = Duration(milliseconds: 280);
  static const slow = Duration(milliseconds: 480);

  /// For roots above MediaQuery, such as MaterialApp's theme animation.
  static Duration systemDuration([Duration value = standard]) =>
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations
      ? Duration.zero
      : DevicePerformance.reducedDuration(value);

  static Duration duration(BuildContext context, [Duration value = standard]) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : DevicePerformance.reducedDuration(value);

  static bool effectsEnabled(BuildContext context) =>
      !DevicePerformance.isReduced && !MediaQuery.highContrastOf(context);

  static Widget transition(BuildContext context, Animation<double> animation, Widget child) {
    if (duration(context) == Duration.zero) return child;
    final progress = animation.drive(CurveTween(curve: curve));
    return FadeTransition(
      opacity: progress,
      child: SlideTransition(
        position: progress.drive(Tween(begin: const Offset(0, 0.025), end: Offset.zero)),
        child: child,
      ),
    );
  }
}

/// Desktop routes share the same gentle fade and vertical settling as tabs.
/// Touch platforms keep their native back gestures through the theme mapping.
class FluidPageTransitionsBuilder extends PageTransitionsBuilder {
  const FluidPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return AppMotion.transition(context, animation, child);
  }
}
