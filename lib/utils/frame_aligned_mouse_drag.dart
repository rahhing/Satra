import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

/// Delivers held-mouse movement at Flutter's display cadence instead of doing
/// hit testing, gesture updates and viewport work for every polling sample.
/// Touch, trackpad pans, hover and non-primary-button input remain immediate.
/// Pending movement is dispatched before release/cancel so native drag velocity
/// tracking receives the final position with its original event timestamp.
mixin FrameAlignedMouseDrag on GestureBinding {
  final Map<int, PointerMoveEvent> _pendingMouseMoves = {};
  int? _mouseFrameCallback;

  void _scheduleMouseFrame() {
    if (_mouseFrameCallback != null) return;
    _mouseFrameCallback = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _mouseFrameCallback = null;
      if (locked) {
        _scheduleMouseFrame();
        return;
      }
      final pending = _pendingMouseMoves.values.toList();
      _pendingMouseMoves.clear();
      for (final event in pending) {
        super.handlePointerEvent(event);
      }
    });
  }

  void _flushMouseDevice(int device) {
    if (_pendingMouseMoves.isEmpty) return;
    final pointers = _pendingMouseMoves.entries
        .where((entry) => entry.value.device == device)
        .map((entry) => entry.key)
        .toList();
    for (final pointer in pointers) {
      super.handlePointerEvent(_pendingMouseMoves.remove(pointer)!);
    }
    if (_pendingMouseMoves.isEmpty && _mouseFrameCallback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(_mouseFrameCallback!);
      _mouseFrameCallback = null;
    }
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerMoveEvent && event.kind == PointerDeviceKind.mouse && event.buttons == kPrimaryMouseButton) {
      final pending = _pendingMouseMoves[event.pointer];
      _pendingMouseMoves[event.pointer] = pending == null ? event : event.copyWith(delta: pending.delta + event.delta);
      _scheduleMouseFrame();
      return;
    }
    if (event.kind == PointerDeviceKind.mouse) _flushMouseDevice(event.device);
    super.handlePointerEvent(event);
  }
}
