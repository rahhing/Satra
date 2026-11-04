import 'package:flutter/material.dart';

/// Keeps each tab mounted with its scroll and focus state.
/// Hidden tabs cannot paint, tick, receive input or semantics.
class RetainedTabView extends StatelessWidget {
  const RetainedTabView({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    clipBehavior: Clip.none,
    children: [
      for (var i = 0; i < children.length; i++)
        Offstage(
          offstage: i != index,
          child: ExcludeFocus(
            excluding: i != index,
            child: TickerMode(
              enabled: i == index,
              child: RepaintBoundary(child: children[i]),
            ),
          ),
        ),
    ],
  );
}
