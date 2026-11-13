import 'package:flutter/material.dart';

import '../../../utils/platform_detector.dart';
import '../../app_icon.dart';
import '../../glass_surface.dart';

/// Scrim or Liquid Glass sheet that hosts the content strip once it is on screen.
///
/// [chevron] points back at the controls the strip replaced — down for the
/// mobile swipe, up for D-pad focus. [padding] compensates for the strip's
/// own horizontal padding, which differs between touch and focus navigation.
class ContentStripPanel extends StatelessWidget {
  final EdgeInsetsGeometry padding;
  final IconData chevron;
  final Widget child;

  const ContentStripPanel({super.key, required this.padding, required this.chevron, required this.child});

  @override
  Widget build(BuildContext context) {
    final useIOSLiquidGlass = PlatformDetector.isHandheldIOS(context);
    final body = Column(
      mainAxisSize: .min,
      children: [
        AppIcon(chevron, color: Colors.white54, size: 20),
        const SizedBox(height: 4),
        child,
      ],
    );

    if (useIOSLiquidGlass) {
      return GlassSurface(
        blurNativeVideo: true,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        sigma: 30,
        opacity: 0.78,
        tint: const Color(0xFF07080C),
        child: Padding(padding: padding, child: body),
      );
    }

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.65), Colors.black.withValues(alpha: 0.7)],
          stops: const [0.0, 0.42, 1.0],
        ),
      ),
      child: body,
    );
  }
}

/// Chevron pinned to the bottom of the controls hinting that the content
/// strip can be pulled into view. Must be placed directly in a [Stack].
class ContentStripHint extends StatelessWidget {
  final IconData chevron;

  const ContentStripHint(this.chevron, {super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(left: 0, right: 0, bottom: 2, child: AppIcon(chevron, color: Colors.white38, size: 22));
  }
}
