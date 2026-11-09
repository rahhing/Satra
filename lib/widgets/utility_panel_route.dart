import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../utils/desktop_window_padding.dart';
import 'glass_surface.dart';

class UtilityPanelScope extends InheritedWidget {
  const UtilityPanelScope({super.key, required super.child});

  static bool isPresent(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtilityPanelScope>() != null;

  @override
  bool updateShouldNotify(UtilityPanelScope oldWidget) => false;
}

/// Panel pages have transparent scaffolds, so both routes must animate when
/// navigating; otherwise the previous page remains visible through the next.
class _PanelPageTransitionsBuilder extends PageTransitionsBuilder {
  const _PanelPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.duration(context) == Duration.zero) return child;
    final incoming = animation.drive(CurveTween(curve: const Interval(0.45, 1, curve: Curves.easeOut)));
    final outgoing = secondaryAnimation.drive(CurveTween(curve: const Interval(0, 0.45, curve: Curves.easeIn)));
    return FadeTransition(
      opacity: ReverseAnimation(outgoing),
      child: FadeTransition(
        opacity: incoming,
        child: SlideTransition(
          position: Tween(begin: const Offset(0.015, 0), end: Offset.zero).animate(incoming),
          child: child,
        ),
      ),
    );
  }
}

/// A desktop utility stays above the current page while its own navigation
/// stack keeps settings subpages and download actions inside the panel.
Route<void> utilityPanelRoute({required Widget child, String? name, bool search = false}) => PageRouteBuilder<void>(
  settings: RouteSettings(name: name),
  opaque: false,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: Colors.black.withValues(alpha: 0.48),
  transitionDuration: AppMotion.systemDuration(const Duration(milliseconds: 320)),
  reverseTransitionDuration: AppMotion.systemDuration(const Duration(milliseconds: 220)),
  pageBuilder: (context, animation, secondaryAnimation) {
    final theme = Theme.of(context);
    final panelTheme = theme.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: theme.colorScheme.surface,
      appBarTheme: theme.appBarTheme.copyWith(backgroundColor: Colors.transparent),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.macOS: _PanelPageTransitionsBuilder(),
          TargetPlatform.windows: _PanelPageTransitionsBuilder(),
          TargetPlatform.linux: _PanelPageTransitionsBuilder(),
        },
      ),
    );
    return SafeArea(
      child: Align(
        alignment: search ? const Alignment(0, -0.7) : Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FractionallySizedBox(
            heightFactor: search ? 0.68 : 0.82,
            child: SizedBox(
              width: search ? 680 : 680,
              child: GlassSurface(
                tint: theme.scaffoldBackgroundColor,
                opacity: 0.84,
                sigma: 36,
                borderRadius: BorderRadius.circular(22),
                child: UtilityPanelScope(
                  child: SideNavigationScope(
                    child: Theme(
                      data: panelTheme,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            top: 32,
                            child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => child)),
                          ),
                          Positioned(
                            right: 10,
                            top: 2,
                            child: IconButton(
                              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  },
  transitionsBuilder: (context, animation, _, child) {
    if (AppMotion.duration(context) == Duration.zero) return child;
    final curved = CurvedAnimation(parent: animation, curve: AppMotion.curve, reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: Offset(0, search ? -0.025 : 0.035), end: Offset.zero).animate(curved),
        child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(curved), child: child),
      ),
    );
  },
);
