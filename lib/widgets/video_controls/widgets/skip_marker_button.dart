import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, KeyDownEvent, LogicalKeyboardKey;
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focus_theme.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/media_source_info.dart';
import '../../../theme/mono_tokens.dart';
import '../../../utils/platform_detector.dart';
import '../../app_icon.dart';
import '../../glass_surface.dart';
import '../../ios_glass_control.dart';

class SkipMarkerButton extends StatelessWidget {
  final MediaMarker marker;
  final Duration playerDuration;
  final bool hasNextEpisode;
  final bool isAutoSkipActive;
  final bool shouldShowAutoSkip;
  final int autoSkipDelay;
  final double autoSkipProgress;
  final FocusNode focusNode;
  final VoidCallback onActivate;
  final VoidCallback onFocusDown;

  const SkipMarkerButton({
    super.key,
    required this.marker,
    required this.playerDuration,
    required this.hasNextEpisode,
    required this.isAutoSkipActive,
    required this.shouldShowAutoSkip,
    required this.autoSkipDelay,
    required this.autoSkipProgress,
    required this.focusNode,
    required this.onActivate,
    required this.onFocusDown,
  });

  @override
  Widget build(BuildContext context) {
    final isCredits = marker.isCredits;
    final creditsAtEnd =
        isCredits && playerDuration > Duration.zero && (playerDuration - marker.endTime).inMilliseconds <= 1000;
    final showNextEpisode = creditsAtEnd && hasNextEpisode;
    String baseButtonText;
    if (showNextEpisode) {
      baseButtonText = t.videoControls.nextEpisode;
    } else if (isCredits) {
      baseButtonText = t.videoControls.skipCredits;
    } else {
      baseButtonText = t.videoControls.skipIntro;
    }

    final remainingSeconds = isAutoSkipActive && shouldShowAutoSkip
        ? (autoSkipDelay - (autoSkipProgress * autoSkipDelay)).ceil().clamp(0, autoSkipDelay)
        : 0;

    final showAutoSkipCountdown = isAutoSkipActive && shouldShowAutoSkip;
    final buttonText = showAutoSkipCountdown && remainingSeconds > 0
        ? '$baseButtonText ($remainingSeconds)'
        : baseButtonText;
    final buttonIcon = showNextEpisode ? Symbols.skip_next_rounded : Symbols.fast_forward_rounded;
    final useIOSLiquidGlass = PlatformDetector.isHandheldIOS(context);
    final radiusValue = useIOSLiquidGlass ? 999.0 : tokens(context).radiusSm;
    final borderRadius = BorderRadius.circular(radiusValue);

    return FocusableWrapper(
      focusNode: focusNode,
      onSelect: _activate,
      borderRadius: radiusValue,
      useBackgroundFocus: true,
      focusColor: FocusTheme.onMediaFocusFill,
      autoScroll: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
          onFocusDown();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: useIOSLiquidGlass
          ? IOSGlassButton(
              label: buttonText,
              title: buttonText,
              titleSize: 15.5,
              symbol: showNextEpisode ? 'forward.end.fill' : 'forward.fill',
              symbolSize: 17,
              progress: showAutoSkipCountdown ? autoSkipProgress : null,
              onPressed: _activate,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.lightImpact();
                  _activate();
                },
                child: GlassSurface(
                  interactive: true,
                  blurNativeVideo: true,
                  borderRadius: borderRadius,
                  sigma: 26,
                  opacity: 0.62,
                  tint: const Color(0xFF07080C),
                  child: Stack(
                    children: [
                      if (isAutoSkipActive && shouldShowAutoSkip)
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: borderRadius,
                            child: Row(
                              children: [
                                Expanded(
                                  flex: (autoSkipProgress * 100).round(),
                                  child: ColoredBox(color: Colors.white.withValues(alpha: 0.20)),
                                ),
                                Expanded(
                                  flex: ((1.0 - autoSkipProgress) * 100).round(),
                                  child: const ColoredBox(color: Colors.transparent),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        child: Row(
                          mainAxisSize: .min,
                          children: [
                            Text(
                              buttonText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15.5,
                                fontWeight: .w600,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(width: 8),
                            AppIcon(buttonIcon, fill: 1, color: Colors.white, size: 20),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _activate,
                borderRadius: borderRadius,
                child: Stack(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        borderRadius: borderRadius,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: .min,
                        children: [
                          Text(
                            buttonText,
                            style: const TextStyle(color: Colors.black, fontSize: 16, fontWeight: .w600),
                          ),
                          const SizedBox(width: 8),
                          AppIcon(buttonIcon, fill: 1, color: Colors.black, size: 20),
                        ],
                      ),
                    ),
                    if (isAutoSkipActive && shouldShowAutoSkip)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: borderRadius,
                          child: Row(
                            children: [
                              Expanded(
                                flex: (autoSkipProgress * 100).round(),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                    borderRadius: borderRadius,
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: ((1.0 - autoSkipProgress) * 100).round(),
                                child: Container(decoration: const BoxDecoration(color: Colors.transparent)),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  void _activate() => onActivate();
}
