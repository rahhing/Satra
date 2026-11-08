import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../utils/platform_detector.dart';
import 'cycling_media_backdrop.dart';
import 'hero_page_indicators.dart';

/// Desktop controls stay above the TV-style browsing foreground and artwork
/// scrims. A forced TV layout still has the desktop's pointer capabilities.
class BackdropPageControls extends StatefulWidget {
  const BackdropPageControls({super.key, required this.builder, required this.controlsBottom});

  final Widget Function(BuildContext context, BackdropRotationController? controller) builder;
  final double controlsBottom;

  @override
  State<BackdropPageControls> createState() => _BackdropPageControlsState();
}

class _BackdropPageControlsState extends State<BackdropPageControls> {
  final _rotation = BackdropRotationController();

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformDetector.isDesktopOS() || PlatformDetector.isTVDevice()) return widget.builder(context, null);
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.builder(context, _rotation),
        Positioned(
          left: 24,
          right: 24,
          bottom: widget.controlsBottom.clamp(
            24.0,
            MediaQuery.sizeOf(context).height.clamp(96.0, double.infinity) - 72,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: Material(
              type: MaterialType.transparency,
              child: ListenableBuilder(
                listenable: _rotation,
                builder: (context, _) => HeroPageIndicators(
                  itemCount: _rotation.itemCount,
                  currentIndex: _rotation.currentIndex,
                  paused: _rotation.paused,
                  onSelected: _rotation.select,
                  onTogglePaused: _rotation.togglePaused,
                  pauseLabel: _rotation.paused ? t.accessibility.autoScrollPlay : t.accessibility.autoScrollPause,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
