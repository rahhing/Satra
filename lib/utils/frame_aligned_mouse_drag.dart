import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

/// Delivers held-mouse movement at Flutter's display cadence instead of doing
/// hit testing, gesture updates and viewport work for every polling sample.
/// Touch, trackpad pans, hover and non-primary-button input remain immediate.
/// Pending movement is dispatched before release/cancel so native drag velocity
/// tracking receives the final position with its original event timestamp.
mixin FrameAlignedMouseDrag on GestureBinding {
  final Map<int, PointerMoveEvent> _pendingMouseMoves = {};
  final Map<int, double> _postDownDistance = {};
  final Set<int> _activeDragPointers = {};
  int? _mouseFrameCallback;
  int _idleDragFrames = 0;

  void _scheduleMouseFrame() {
    if (_mouseFrameCallback != null) return;
    _mouseFrameCallback = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _mouseFrameCallback = null;
      if (locked) {
        _scheduleMouseFrame();
        return;
      }
      if (_pendingMouseMoves.isNotEmpty) {
        _idleDragFrames = 0;
        final pending = _pendingMouseMoves.values.toList();
        _pendingMouseMoves.clear();
        for (final event in pending) {
          super.handlePointerEvent(event);
        }
      } else {
        _idleDragFrames++;
      }
      if (_activeDragPointers.isNotEmpty && _idleDragFrames <= 6) {
        _scheduleMouseFrame();
      }
    });
  }

  void _flushMouseDevice(int device) {
    if (_pendingMouseMoves.isNotEmpty) {
      final pointers = _pendingMouseMoves.entries
          .where((entry) => entry.value.device == device)
          .map((entry) => entry.key)
          .toList();
      for (final pointer in pointers) {
        super.handlePointerEvent(_pendingMouseMoves.remove(pointer)!);
      }
    }
    if (_pendingMouseMoves.isEmpty && _activeDragPointers.isEmpty && _mouseFrameCallback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(_mouseFrameCallback!);
      _mouseFrameCallback = null;
    }
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent && event.kind == PointerDeviceKind.mouse && event.buttons == kPrimaryMouseButton) {
      _postDownDistance[event.pointer] = 0.0;
      super.handlePointerEvent(event);
      return;
    }
    if (event is PointerMoveEvent && event.kind == PointerDeviceKind.mouse && event.buttons == kPrimaryMouseButton) {
      // Deliver initial post-press movement samples immediately until pointer
      // slop is crossed so DragStartBehavior.start accepts the drag without
      // swallowing a coalesced frame delta.
      if (!_activeDragPointers.contains(event.pointer)) {
        final dist = (_postDownDistance[event.pointer] ?? 0.0) + event.delta.distance;
        _postDownDistance[event.pointer] = dist;
        if (dist > kPrecisePointerHitSlop) {
          _activeDragPointers.add(event.pointer);
          _idleDragFrames = 0;
          _scheduleMouseFrame();
        }
        super.handlePointerEvent(event);
        return;
      }
      _idleDragFrames = 0;
      final pending = _pendingMouseMoves[event.pointer];
      _pendingMouseMoves[event.pointer] = pending == null ? event : event.copyWith(delta: pending.delta + event.delta);
      _scheduleMouseFrame();
      return;
    }
    if (event.kind == PointerDeviceKind.mouse) {
      _postDownDistance.remove(event.pointer);
      _activeDragPointers.remove(event.pointer);
      _flushMouseDevice(event.device);
    }
    super.handlePointerEvent(event);
  }
}
