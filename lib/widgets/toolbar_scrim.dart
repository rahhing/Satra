import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/fullscreen_state_manager.dart';
import '../utils/desktop_window_padding.dart';
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

  Widget _buildWithLeftExtra(BuildContext context, double extraLeft) {
    final safePadding = MediaQuery.paddingOf(context);
    return Padding(
      padding: EdgeInsets.only(
        top: safePadding.top + 8,
        left: safePadding.left + 16 + extraLeft,
        right: safePadding.right + 16,
        bottom: 16,
      ),
      child: GlassSurface(
        borderRadius: const BorderRadius.all(Radius.circular(22)),
        sigma: 22,
        opacity: 0.68,
        tint: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF07080C) : null,
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

  @override
  Widget build(BuildContext context) {
    if (Platform.isMacOS && !SideNavigationScope.isPresent(context)) {
      return ListenableBuilder(
        listenable: FullscreenStateManager(),
        builder: (context, _) => _buildWithLeftExtra(context, DesktopWindowPadding.macOSLeftCurrent),
      );
    }
    return _buildWithLeftExtra(context, 0);
  }
}
