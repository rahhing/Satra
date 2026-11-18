import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../theme/app_motion.dart';
import 'settings_builder.dart';
import 'shelf_hover_depth.dart';

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
  ShelfHoverDepthState? _shelf;

  void _startHover() {
    if (_hovered) return;
    _shelf = ShelfHoverDepth.maybeOf(context);
    _shelf?.enterCard(context);
    setState(() => _hovered = true);
  }

  void _leaveShelf() {
    _shelf?.leaveCard(context);
    _shelf = null;
  }

  @override
  void deactivate() {
    // MouseRegion doesn't send onExit when a card is removed during a refresh.
    _leaveShelf();
    _hovered = false;
    _pressed = false;
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    final motion = AppMotion.duration(context) != Duration.zero;
    return MouseRegion(
      onEnter: (event) {
        if (event.buttons == 0) _startHover();
      },
      onHover: (event) {
        if (event.buttons == 0) _startHover();
      },
      onExit: (_) {
        _leaveShelf();
        setState(() {
          _hovered = false;
          _pressed = false;
        });
      },
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: SettingValueBuilder<bool>(
          pref: SettingsService.cardHoverLift,
          child: widget.child,
          builder: (context, liftEnabled, child) {
            final lifted = motion && liftEnabled && _hovered && !_pressed;
            return AnimatedScale(
              duration: AppMotion.duration(context, _pressed ? AppMotion.fast : AppMotion.standard),
              curve: AppMotion.curve,
              scale: lifted ? HoverLift.hoverScale : (motion && _pressed ? 0.985 : 1),
              child: AnimatedSlide(
                duration: AppMotion.duration(context),
                curve: AppMotion.curve,
                offset: lifted ? const Offset(0, -HoverLift.liftFraction) : Offset.zero,
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }
}
