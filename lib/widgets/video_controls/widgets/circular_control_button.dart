import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:satra/widgets/app_icon.dart';

import '../../../utils/platform_detector.dart';
import '../../glass_surface.dart';
import '../../ios_glass_control.dart';

/// A circular transport button used in the mobile video controls.
///
/// On handheld iOS, renders as a native interactive Liquid Glass orb (`blurNativeVideo: true`)
/// matching iOS 26's Files / QuickLook video player. On other mobile platforms,
/// renders on a semi-transparent dark circle.
class CircularControlButton extends StatelessWidget {
  final String semanticLabel;
  final IconData icon;
  final double iconSize;
  final VoidCallback? onPressed;

  const CircularControlButton({
    super.key,
    required this.semanticLabel,
    required this.icon,
    required this.iconSize,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null;
    final useIOSLiquidGlass = PlatformDetector.isHandheldIOS(context);

    if (useIOSLiquidGlass) {
      final isPrimary = iconSize >= 64;
      final orbDiameter = isPrimary ? 78.0 : 54.0;
      final glyphSize = isPrimary ? 40.0 : 27.0;

      final fallback = Semantics(
        label: semanticLabel,
        button: true,
        enabled: isEnabled,
        onTap: onPressed,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: isEnabled
              ? () {
                  HapticFeedback.lightImpact();
                  onPressed!();
                }
              : null,
          child: SizedBox(
            width: orbDiameter,
            height: orbDiameter,
            child: GlassSurface(
              interactive: isEnabled,
              blurNativeVideo: true,
              borderRadius: const BorderRadius.all(Radius.circular(999)),
              sigma: 26,
              opacity: isEnabled ? 0.54 : 0.34,
              tint: const Color(0xFF07080C),
              child: Center(
                child: AppIcon(
                  icon,
                  fill: 1,
                  color: isEnabled ? Colors.white : Colors.white.withValues(alpha: 0.34),
                  size: glyphSize,
                ),
              ),
            ),
          ),
        ),
      );
      final symbol = switch (icon) {
        Symbols.skip_previous_rounded => 'backward.end.fill',
        Symbols.skip_next_rounded => 'forward.end.fill',
        Symbols.pause_rounded => 'pause.fill',
        Symbols.play_arrow_rounded => 'play.fill',
        _ => null,
      };
      if (symbol == null) return fallback;
      return IOSGlassButton(
        label: semanticLabel,
        symbol: symbol,
        symbolSize: glyphSize,
        onPressed: onPressed,
        child: fallback,
      );
    }

    return Container(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
      child: Semantics(
        label: semanticLabel,
        button: true,
        enabled: isEnabled,
        onTap: onPressed,
        excludeSemantics: true,
        child: IconButton(
          icon: AppIcon(
            icon,
            fill: 1,
            color: isEnabled ? Colors.white : Colors.white.withValues(alpha: 0.3),
            size: iconSize,
          ),
          iconSize: iconSize,
          onPressed: onPressed,
        ),
      ),
    );
  }
}
