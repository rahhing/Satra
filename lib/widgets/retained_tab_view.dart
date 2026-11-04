import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// Keeps each tab mounted with its scroll and focus state, animating only the
/// newly selected tab. Hidden tabs cannot paint, tick, receive input or semantics.
class RetainedTabView extends StatefulWidget {
  const RetainedTabView({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<RetainedTabView> createState() => _RetainedTabViewState();
}

class _RetainedTabViewState extends State<RetainedTabView> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: 1);
  late final _curve = CurvedAnimation(parent: _controller, curve: AppMotion.curve);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.duration(context) == Duration.zero) _controller.value = 1;
  }

  @override
  void didUpdateWidget(RetainedTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      _controller.duration = AppMotion.duration(context);
      if (_controller.duration == Duration.zero) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    clipBehavior: Clip.none,
    children: [
      for (var i = 0; i < widget.children.length; i++)
        Offstage(
          offstage: i != widget.index,
          child: ExcludeFocus(
            excluding: i != widget.index,
            child: TickerMode(
              enabled: i == widget.index,
              child: FadeTransition(
                opacity: _curve,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.018), end: Offset.zero).animate(_curve),
                  child: widget.children[i],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
