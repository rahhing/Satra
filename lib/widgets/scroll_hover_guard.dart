import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

/// Keeps scrolling cards from repeatedly starting hover animations/previews or
/// changing the spotlight underneath a held cursor. Pointer/gesture hits stay
/// intact so dragging, reversing and interrupting momentum remain native.
class ScrollHoverGuard extends StatefulWidget {
  const ScrollHoverGuard({super.key, required this.child});
  final Widget child;

  @override
  State<ScrollHoverGuard> createState() => _ScrollHoverGuardState();
}

class _ScrollHoverGuardState extends State<ScrollHoverGuard> {
  bool _scrolling = false;
  bool _desiredScrolling = false;
  bool _updatePending = false;

  void _setScrolling(bool value) {
    if (_desiredScrolling == value) return;
    _desiredScrolling = value;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_updatePending) return;
      _updatePending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updatePending = false;
        if (mounted && _scrolling != _desiredScrolling) {
          setState(() => _scrolling = _desiredScrolling);
          if (!_desiredScrolling) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) RendererBinding.instance.mouseTracker.updateAllDevices();
            });
          }
        }
      });
    } else {
      setState(() => _scrolling = value);
      if (!value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) RendererBinding.instance.mouseTracker.updateAllDevices();
        });
      }
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.horizontal) return false;
    if (notification is ScrollStartNotification) {
      _setScrolling(true);
    } else if (notification is ScrollEndNotification) {
      _setScrolling(false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(
    onNotification: _onScroll,
    child: MouseRegion(
      cursor: _scrolling ? SystemMouseCursors.grabbing : MouseCursor.defer,
      child: _HoverHitFilter(suppressed: _scrolling, child: widget.child),
    ),
  );
}

class _HoverHitFilter extends SingleChildRenderObjectWidget {
  const _HoverHitFilter({required this.suppressed, required super.child});
  final bool suppressed;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHoverHitFilter(suppressed);

  @override
  void updateRenderObject(BuildContext context, _RenderHoverHitFilter renderObject) =>
      renderObject.suppressed = suppressed;
}

class _RenderHoverHitFilter extends RenderProxyBox {
  _RenderHoverHitFilter(this.suppressed);
  bool suppressed;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!suppressed) return super.hitTest(result, position: position);
    return size.contains(position) && (child?.hitTest(_WithoutHoverHits(result), position: position) ?? false);
  }
}

class _WithoutHoverHits extends BoxHitTestResult {
  _WithoutHoverHits(super.result) : super.wrap();

  @override
  void add(HitTestEntry entry) {
    if (entry.target is! MouseTrackerAnnotation) super.add(entry);
  }
}
