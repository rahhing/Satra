import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Corrects desktop embedders that expose a high-resolution monitor at 1×.
/// An already density-correct 4K/2× display stays at its native UI scale.
abstract final class DesktopUiScale {
  static const automatic = 0.0;
  static const options = [automatic, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5];
  static const _minimumLayoutViewport = Size(480, 360);

  static bool isDesktopPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.linux || platform == TargetPlatform.windows || platform == TargetPlatform.macOS;

  static double normalize(double value) =>
      !value.isFinite || value == automatic ? automatic : value.clamp(0.75, 2.5).toDouble();

  static double resolve({
    required Size displaySize,
    required double devicePixelRatio,
    required Size viewportSize,
    double preference = automatic,
  }) {
    final saved = normalize(preference);
    final density = devicePixelRatio.isFinite && devicePixelRatio > 0 ? devicePixelRatio : 1.0;
    final logicalShortSide = displaySize.shortestSide / density;
    final automaticScale = ((logicalShortSide / 1080).clamp(1.0, 2.0) * 4).round() / 4;
    final desired = saved == automatic ? automaticScale : saved;
    // Keep enough room for the desktop rail and the main toolbar as well as
    // their content. The smaller 320x240 cap let the rail crowd narrow
    // windowed layouts even though every individual control still fit.
    final fitting = math
        .min(viewportSize.width / _minimumLayoutViewport.width, viewportSize.height / _minimumLayoutViewport.height)
        .clamp(0.75, 2.5);
    return math.min(desired, fitting).toDouble();
  }
}
