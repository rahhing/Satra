import 'package:flutter/material.dart';

/// Dependency aspects for [MainScreenFocusScope].
enum MainScreenScopeAspect {
  /// `foregroundLeft` / `sideNavigationWidth` — positioning offsets.
  offset,

  /// `foregroundWidth` / `viewportWidth` / `reservedSideNavigationWidth` —
  /// window geometry metrics.
  layout,
}

class MainScreenFocusScope extends InheritedModel<MainScreenScopeAspect> {
  final double sideNavigationWidth;
  final double? reservedSideNavigationWidth;
  final double? foregroundLeft;
  final double? foregroundWidth;
  final double? viewportWidth;
  final void Function(String libraryGlobalKey)? selectLibrary;
  final VoidCallback? selectHome;
  final VoidCallback? selectExplore;
  final VoidCallback? selectLiveTv;
  final VoidCallback? openDownloads;
  final VoidCallback? openSettings;
  final void Function({String? initialQuery})? openSpotlight;
  final VoidCallback? reconnectOffline;

  const MainScreenFocusScope({
    super.key,
    this.sideNavigationWidth = 0,
    this.reservedSideNavigationWidth,
    this.foregroundLeft,
    this.foregroundWidth,
    this.viewportWidth,
    this.selectLibrary,
    this.selectHome,
    this.selectExplore,
    this.selectLiveTv,
    this.openDownloads,
    this.openSettings,
    this.openSpotlight,
    this.reconnectOffline,
    required super.child,
  });

  /// Whole-scope access. With `listen: true` this registers an aspect-less
  /// dependency (notified on ANY scope change) — use the aspect-scoped static
  /// getters instead wherever possible. Callback access should always pass
  /// `listen: false`.
  static MainScreenFocusScope? of(BuildContext context, {bool listen = true}) {
    if (listen) return context.dependOnInheritedWidgetOfExactType<MainScreenFocusScope>();
    return context.getElementForInheritedWidgetOfExactType<MainScreenFocusScope>()?.widget as MainScreenFocusScope?;
  }

  static MainScreenFocusScope? _dependOn(BuildContext context, MainScreenScopeAspect aspect) {
    return InheritedModel.inheritFrom<MainScreenFocusScope>(context, aspect: aspect);
  }

  /// Content bleed target.
  static double sideNavigationBleedOf(BuildContext context) {
    return _dependOn(context, MainScreenScopeAspect.offset)?.sideNavigationWidth ?? 0.0;
  }

  /// Content box left edge.
  static double foregroundLeftOf(BuildContext context) {
    final left = _dependOn(context, MainScreenScopeAspect.offset)?.foregroundLeft;
    if (left != null) return left;
    return 0.0;
  }

  static double foregroundWidthOf(BuildContext context) {
    final width = _dependOn(context, MainScreenScopeAspect.layout)?.foregroundWidth;
    if (width != null && width > 0) return width;
    return MediaQuery.sizeOf(context).width;
  }

  static Size foregroundSizeOf(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Size(foregroundWidthOf(context), size.height);
  }

  static double fullBleedWidthOf(BuildContext context) {
    final width = _dependOn(context, MainScreenScopeAspect.layout)?.viewportWidth;
    if (width != null && width > 0) return width;
    return MediaQuery.sizeOf(context).width;
  }

  @override
  bool updateShouldNotify(MainScreenFocusScope oldWidget) {
    return sideNavigationWidth != oldWidget.sideNavigationWidth ||
        reservedSideNavigationWidth != oldWidget.reservedSideNavigationWidth ||
        foregroundLeft != oldWidget.foregroundLeft ||
        foregroundWidth != oldWidget.foregroundWidth ||
        viewportWidth != oldWidget.viewportWidth;
  }

  @override
  bool updateShouldNotifyDependent(MainScreenFocusScope oldWidget, Set<MainScreenScopeAspect> dependencies) {
    if (dependencies.contains(MainScreenScopeAspect.offset) &&
        (foregroundLeft != oldWidget.foregroundLeft || sideNavigationWidth != oldWidget.sideNavigationWidth)) {
      return true;
    }
    if (dependencies.contains(MainScreenScopeAspect.layout) &&
        (foregroundWidth != oldWidget.foregroundWidth ||
            viewportWidth != oldWidget.viewportWidth ||
            reservedSideNavigationWidth != oldWidget.reservedSideNavigationWidth)) {
      return true;
    }
    return false;
  }
}

/// Animates toward [targetBleed] for viewport-pinned overlays.
class SideNavigationBleedBuilder extends StatelessWidget {
  static const expandDuration = Duration(milliseconds: 220);
  static const expandCurve = Curves.easeOutCubic;

  final double targetBleed;
  final Widget? child;
  final Widget Function(BuildContext context, double bleed, Widget? child) builder;

  const SideNavigationBleedBuilder({super.key, required this.targetBleed, this.child, required this.builder});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: targetBleed),
      duration: expandDuration,
      curve: expandCurve,
      builder: builder,
      child: child,
    );
  }
}
