import 'package:flutter/material.dart';

import 'glass_surface.dart';

/// A floating frosted toolbar, inset from the system chrome. A single tint
/// keeps artwork visible through the pane without a second dark scrim.
class ToolbarScrim extends StatelessWidget {
  const ToolbarScrim({super.key, required this.child});

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
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: child),
      ),
    );
  }
}
