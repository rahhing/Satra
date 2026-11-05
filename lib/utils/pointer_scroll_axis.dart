import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'memory_pressure_breadcrumbs.dart';
import 'semantics_tree_gate.dart';

/// Collapses a diagonal scroll signal onto the axis the viewer actually moved.
///
/// A wheel, trackpoint, trackball or button-scroll event expresses one-axis
/// intent, but the host can report both axes in the same event: on Linux only
/// touchpad-sourced scrolling becomes a pan/zoom sequence (which resolves in the
/// gesture arena), while wheel/continuous/tilt sources arrive as a single
/// [PointerScrollEvent] carrying whatever `dx` the device produced. A trackball
/// or libinput button-scrolling maps pointer motion straight onto both axes, so
/// `dx` is essentially never zero there.
///
/// That matters because [Scrollable] claims a scroll signal as soon as the delta
/// along *its own* axis is non-zero, and the deepest claimant wins the
/// [PointerSignalResolver]. One pixel of `dx` therefore hands the whole event to
/// a horizontal hub row and the page behind it never scrolls — the Home,
/// library Recommended and media-detail freeze reported in #2081, on exactly the
/// screens whose viewport is covered by horizontal rows.
///
/// Returns [event] unchanged when it is already single-axis, so the common wheel
/// path allocates nothing.
PointerScrollEvent lockScrollSignalToDominantAxis(PointerScrollEvent event) {
  final Offset delta = event.scrollDelta;
  if (delta.dx == 0.0 || delta.dy == 0.0) return event;
  // Ties go to the vertical axis: pages scroll vertically, rows are the nested
  // exception, so an ambiguous event should reach the page.
  final Offset dominant = delta.dx.abs() > delta.dy.abs() ? Offset(delta.dx, 0.0) : Offset(0.0, delta.dy);
  return PointerScrollEvent(
    viewId: event.viewId,
    timeStamp: event.timeStamp,
    kind: event.kind,
    device: event.device,
    position: event.position,
    scrollDelta: dominant,
    embedderId: event.embedderId,
    onRespond: event.respond,
  );
}

/// Applies [lockScrollSignalToDominantAxis] to every scroll signal before it is
/// hit-tested, which is the only place the delta can still be corrected: by the
/// time a [Scrollable] sees the event it has already registered with the
/// [PointerSignalResolver], and only the first (deepest) registration runs.
///
/// Trackpad pans also need an axis lock: nested horizontal and vertical drag
/// recognizers can both cross their drag threshold in one diagonal update.
/// The deepest recognizer wins even when its axis is the smaller movement.
mixin PointerScrollAxisLock on GestureBinding {
  final Map<int, Axis> _trackpadAxes = {};

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerPanZoomStartEvent || event is PointerPanZoomEndEvent || event is PointerCancelEvent) {
      _trackpadAxes.remove(event.pointer);
    } else if (event is PointerPanZoomUpdateEvent) {
      // Leave pinch/rotation gestures intact. Wait through the normal drag
      // slop before choosing, so initial finger jitter cannot lock the axis.
      if (event.scale != 1.0 || event.rotation != 0.0) {
        _trackpadAxes.remove(event.pointer);
      } else {
        var axis = _trackpadAxes[event.pointer];
        if (axis == null && event.pan.distanceSquared > kTouchSlop * kTouchSlop) {
          axis = event.pan.dx.abs() > event.pan.dy.abs() ? Axis.horizontal : Axis.vertical;
          _trackpadAxes[event.pointer] = axis;
        }
        if (axis != null) {
          event = PointerPanZoomUpdateEvent(
            viewId: event.viewId,
            timeStamp: event.timeStamp,
            device: event.device,
            pointer: event.pointer,
            position: event.position,
            embedderId: event.embedderId,
            synthesized: event.synthesized,
            pan: axis == Axis.horizontal ? Offset(event.pan.dx, 0) : Offset(0, event.pan.dy),
            panDelta: axis == Axis.horizontal ? Offset(event.panDelta.dx, 0) : Offset(0, event.panDelta.dy),
          );
        }
      }
    }
    super.handlePointerEvent(event is PointerScrollEvent ? lockScrollSignalToDominantAxis(event) : event);
  }
}

/// The app's binding: installs [PointerScrollAxisLock], [SemanticsTreeGate] and
/// [MemoryPressureBreadcrumbs].
class SatraWidgetsBinding extends WidgetsFlutterBinding
    with PointerScrollAxisLock, SemanticsTreeGate, MemoryPressureBreadcrumbs {
  static bool _initialized = false;

  /// Creates the binding on first call and returns it afterwards, mirroring
  /// [WidgetsFlutterBinding.ensureInitialized].
  static WidgetsBinding ensureInitialized() {
    if (!_initialized) {
      SatraWidgetsBinding();
      _initialized = true;
    }
    return WidgetsBinding.instance;
  }
}
