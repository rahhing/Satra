import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// A stable subtree keeps images and inline players mounted while the pointer
/// enters, presses, leaves, or reverses an in-flight animation.
class HoverLift extends StatefulWidget {
  const HoverLift({super.key, required this.child});

  final Widget child;

  static const hoverScale = 1.035;
  static const liftFraction = 0.018;

  /// Paint space required when this lift is composed with keyboard focus.
  /// Shelves can clip their horizontal edges without trimming a lifted card.
  static EdgeInsets paintOutsets(Size size, {double parentScale = 1}) {
    final scale = hoverScale * parentScale;
    final horizontal = size.width * (scale - 1) / 2;
    final vertical = size.height * (scale - 1) / 2;
    final lift = size.height * liftFraction * scale;
    return EdgeInsets.fromLTRB(horizontal, vertical + lift, horizontal, (vertical - lift).clamp(0, double.infinity));
  }

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final motion = AppMotion.duration(context) != Duration.zero;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          duration: AppMotion.duration(context, _pressed ? AppMotion.fast : AppMotion.standard),
          curve: AppMotion.curve,
          scale: !motion ? 1 : (_pressed ? 0.985 : (_hovered ? HoverLift.hoverScale : 1)),
          child: AnimatedSlide(
            duration: AppMotion.duration(context),
            curve: AppMotion.curve,
            offset: motion && _hovered && !_pressed ? const Offset(0, -HoverLift.liftFraction) : Offset.zero,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
