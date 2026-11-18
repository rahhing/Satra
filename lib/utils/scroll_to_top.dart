import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Implemented by tab screens that can smoothly return their active scroll
/// view to the top when the user taps the top-left header pill or re-taps the
/// active bottom tab.
abstract interface class ScrollToTopable {
  void scrollToTop();
}

/// Scrolls all positions attached to [controller] back to `0.0` with a
/// distance-adaptive duration:
/// - Short offsets (~150px) glide gently (~290ms).
/// - Deep offsets accelerate briskly (~450–640ms) and stage multi-page jumps
///   so returning from thousands of pixels down stays locked at 120fps.
Future<void> smoothScrollToTop(ScrollController controller) async {
  if (!controller.hasClients) return;

  final futures = <Future<void>>[];
  for (final position in controller.positions) {
    final current = position.pixels;
    if (current <= 1.0) continue;

    final viewport = position.viewportDimension > 0 ? position.viewportDimension : 800.0;
    if (current > viewport * 4.5) {
      position.jumpTo(viewport * 3.5);
    }

    final remaining = position.pixels;
    final durationMs = (210 + math.sqrt(remaining) * 7.8).round().clamp(240, 650);
    futures.add(
      position.animateTo(
        0.0,
        duration: Duration(milliseconds: durationMs),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  if (futures.isNotEmpty) {
    unawaited(HapticFeedback.lightImpact());
    await Future.wait(futures);
  }
}
