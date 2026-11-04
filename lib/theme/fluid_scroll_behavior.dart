import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'app_motion.dart';

/// Smooths discrete wheel signals while leaving touch/trackpad gestures and
/// their native momentum to Flutter. The pointer resolver still chooses the
/// deepest scrollable that can actually move along the requested axis.
class FluidScrollBehavior extends MaterialScrollBehavior {
  const FluidScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) =>
      _WheelScroll(details: details, child: child);
}

class _WheelScroll extends StatefulWidget {
  const _WheelScroll({required this.details, required this.child});

  final ScrollableDetails details;
  final Widget child;

  @override
  State<_WheelScroll> createState() => _WheelScrollState();
}

class _WheelScrollState extends State<_WheelScroll> {
  double? _target;
  int _generation = 0;

  void _onSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent || signal.kind != PointerDeviceKind.mouse) return;
    if (AppMotion.duration(context) == Duration.zero) return;
    final controller = widget.details.controller;
    if (controller == null || !controller.hasClients || controller.positions.length != 1) return;
    final position = controller.position;
    if (!position.hasContentDimensions || !position.physics.shouldAcceptUserOffset(position)) return;
    final axis = axisDirectionToAxis(widget.details.direction);
    final delta = HardwareKeyboard.instance.isShiftPressed
        ? (axis == Axis.vertical ? signal.scrollDelta.dx : signal.scrollDelta.dy)
        : (axis == Axis.vertical ? signal.scrollDelta.dy : signal.scrollDelta.dx);
    final directedDelta = axisDirectionIsReversed(widget.details.direction) ? -delta : delta;
    if (directedDelta == 0) return;
    final remaining = (_target ?? position.pixels) - position.pixels;
    // Reverse immediately, without waiting for queued forward travel.
    final origin = remaining * directedDelta < 0 ? position.pixels : _target ?? position.pixels;
    final target = math.max(position.minScrollExtent, math.min(position.maxScrollExtent, origin + directedDelta));
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(signal, (_) {
      if (!mounted || !controller.hasClients || controller.position != position) return;
      final generation = ++_generation;
      _target = target;
      signal.respond(allowPlatformDefault: false);
      position.animateTo(target, duration: const Duration(milliseconds: 240), curve: AppMotion.curve).whenComplete(() {
        if (generation == _generation) _target = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {
      _generation++;
      _target = null;
    },
    child: _WheelSignalRegion(onSignal: _onSignal, child: widget.child),
  );
}

/// ScrollBehavior decorates the outside of Scrollable, whose own signal
/// listener would otherwise claim the event first. Insert our signal entry
/// immediately before that listener, retaining all descendant hit-test entries
/// ahead of it. Nested lists, page views, and the standard pointer resolver
/// therefore keep exactly their usual priority and boundary hand-off.
class _WheelSignalRegion extends SingleChildRenderObjectWidget {
  const _WheelSignalRegion({required this.onSignal, required super.child});

  final ValueChanged<PointerSignalEvent> onSignal;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderWheelSignalRegion(onSignal);

  @override
  void updateRenderObject(BuildContext context, _RenderWheelSignalRegion renderObject) =>
      renderObject.onSignal = onSignal;
}

class _RenderWheelSignalRegion extends RenderProxyBox {
  _RenderWheelSignalRegion(this.onSignal);

  ValueChanged<PointerSignalEvent> onSignal;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      size.contains(position) &&
      (child?.hitTest(_WheelHitTestResult(result, this, position), position: position) ?? false);

  @override
  void handleEvent(PointerEvent event, covariant HitTestEntry entry) {
    if (event is PointerSignalEvent) onSignal(event);
  }
}

class _WheelHitTestResult extends BoxHitTestResult {
  _WheelHitTestResult(super.result, this.region, this.position) : super.wrap();

  final _RenderWheelSignalRegion region;
  final Offset position;

  @override
  void add(HitTestEntry entry) {
    final target = entry.target;
    if (target is RenderPointerListener && target.onPointerSignal != null && _isOwnListener(target)) {
      super.add(BoxHitTestEntry(region, position));
    }
    super.add(entry);
  }

  bool _isOwnListener(RenderObject target) {
    for (var parent = target.parent; parent != null; parent = parent.parent) {
      if (parent == region) return true;
      if (parent is RenderPointerListener && parent.onPointerSignal != null) return false;
    }
    return false;
  }
}
