import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// Pointer feedback uses paint transforms so a shelf never shifts its layout.
class HoverLift extends StatefulWidget {
  const HoverLift({super.key, required this.child});

  final Widget child;

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hovered = false;
  bool _pressed = false;
  bool _engaged = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _pressed;
    final duration = AppMotion.duration(context, const Duration(milliseconds: 200));
    Widget content = widget.child;
    if ((active || _engaged) && duration != Duration.zero) {
      content = AnimatedScale(
        duration: duration,
        curve: AppMotion.curve,
        scale: _pressed ? 0.985 : (_hovered ? 1.025 : 1),
        onEnd: () {
          if (!mounted || _hovered || _pressed) return;
          setState(() => _engaged = false);
        },
        child: AnimatedSlide(
          duration: duration,
          curve: AppMotion.curve,
          offset: _hovered ? const Offset(0, -0.012) : Offset.zero,
          child: content,
        ),
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() {
        _hovered = true;
        _engaged = true;
      }),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() {
          _pressed = true;
          _engaged = true;
        }),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: content,
      ),
    );
  }
}
