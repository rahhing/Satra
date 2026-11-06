import 'package:flutter/material.dart';

import 'glass_surface.dart';

/// A floating frosted toolbar, inset from the system chrome. A single tint
/// keeps artwork visible through the pane without a second dark scrim.
class ToolbarScrim extends StatelessWidget {
  const ToolbarScrim({super.key, required this.child});

  ToolbarScrim.navigation({super.key, required Widget navigation, required Widget actions})
    : child = Row(
        children: [
          Expanded(
            child: Align(alignment: AlignmentDirectional.centerStart, child: navigation),
          ),
          const SizedBox(width: 12),
          actions,
        ],
      );

  static const contentHeight = 48.0;

  static double layoutHeight(BuildContext context) => MediaQuery.paddingOf(context).top + 8 + contentHeight + 8 + 16;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final safePadding = MediaQuery.paddingOf(context);
    return Padding(
      padding: EdgeInsets.only(
        top: safePadding.top + 8,
        left: safePadding.left + 16,
        right: safePadding.right + 16,
        bottom: 16,
      ),
      child: GlassSurface(
        borderRadius: const BorderRadius.all(Radius.circular(22)),
        sigma: 20,
        opacity: 0.24,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: contentHeight),
            child: child,
          ),
        ),
      ),
    );
  }
}
