import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'spotlight_dialog.dart';
import 'spotlight_settings_index.dart';

/// Matches `Ctrl + Space` on ALL platforms (Linux, macOS, Windows, Android, iOS)
/// whenever the app is focused. Deliberately checks `Control` on every OS so
/// macOS does not conflict with system Spotlight (`Cmd + Space`).
bool isSpotlightShortcut(
  KeyEvent event, {
  bool? isControlPressed,
  bool? isAltPressed,
  bool? isMetaPressed,
  bool? isShiftPressed,
}) {
  if (event is! KeyDownEvent) return false;
  if (event.logicalKey != LogicalKeyboardKey.space) return false;

  final kb = HardwareKeyboard.instance;
  final ctrl = isControlPressed ?? kb.isControlPressed;
  final alt = isAltPressed ?? kb.isAltPressed;
  final meta = isMetaPressed ?? kb.isMetaPressed;
  final shift = isShiftPressed ?? kb.isShiftPressed;

  return ctrl && !alt && !meta && !shift;
}

/// Tracks whether the Universal Spotlight route is currently on the navigator
/// stack so pressing `Ctrl + Space` toggles it open and closed cleanly.
class SpotlightRouteTracker extends NavigatorObserver {
  Route<dynamic>? _activeSpotlightRoute;

  bool get isSpotlightOpen => _activeSpotlightRoute != null;

  bool closeIfOpen() {
    final route = _activeSpotlightRoute;
    final nav = navigator;
    if (route == null || nav == null) return false;
    if (route.isCurrent) {
      nav.pop();
      return true;
    }
    nav.removeRoute(route);
    return true;
  }

  static bool _isSpotlight(Route<dynamic>? route) => route?.settings.name == spotlightRouteName;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isSpotlight(route)) _activeSpotlightRoute = route;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, _activeSpotlightRoute)) _activeSpotlightRoute = null;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, _activeSpotlightRoute)) _activeSpotlightRoute = null;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(oldRoute, _activeSpotlightRoute)) _activeSpotlightRoute = null;
    if (_isSpotlight(newRoute)) _activeSpotlightRoute = newRoute;
  }
}

/// Registry allowing [MainScreen] to provide its live shell callbacks to the
/// session-wide [SpotlightShortcut] controller, and allowing buttons/remotes to
/// open Spotlight imperatively.
class SpotlightController {
  static SpotlightController? activeInstance;

  SpotlightShellCallbacks Function()? callbacksProvider;
  void Function({String? initialQuery})? _opener;

  void open({String? initialQuery}) => _opener?.call(initialQuery: initialQuery);
}

class SpotlightScope extends InheritedWidget {
  const SpotlightScope({super.key, required this.controller, required super.child});

  final SpotlightController controller;

  static SpotlightController? maybeOf(BuildContext context) {
    return context.getElementForInheritedWidgetOfExactType<SpotlightScope>()?.widget is SpotlightScope
        ? (context.getElementForInheritedWidgetOfExactType<SpotlightScope>()!.widget as SpotlightScope).controller
        : null;
  }

  static void open(BuildContext context, {String? initialQuery}) {
    maybeOf(context)?.open(initialQuery: initialQuery);
  }

  @override
  bool updateShouldNotify(SpotlightScope oldWidget) => controller != oldWidget.controller;
}

/// Wraps a [Navigator] so pressing `Ctrl + Space` anywhere in the focused app
/// toggles the Universal Spotlight bubble.
class SpotlightShortcut extends StatefulWidget {
  const SpotlightShortcut({
    super.key,
    required this.navigatorKey,
    required this.routeTracker,
    required this.controller,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final SpotlightRouteTracker routeTracker;
  final SpotlightController controller;
  final Widget child;

  @override
  State<SpotlightShortcut> createState() => _SpotlightShortcutState();
}

class _SpotlightShortcutState extends State<SpotlightShortcut> {
  @override
  void initState() {
    super.initState();
    widget.controller._opener = _openSpotlight;
    SpotlightController.activeInstance = widget.controller;
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
  }

  @override
  void didUpdateWidget(covariant SpotlightShortcut oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._opener = null;
      widget.controller._opener = _openSpotlight;
      SpotlightController.activeInstance = widget.controller;
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    if (identical(widget.controller._opener, _openSpotlight)) {
      widget.controller._opener = null;
    }
    if (identical(SpotlightController.activeInstance, widget.controller)) {
      SpotlightController.activeInstance = null;
    }
    super.dispose();
  }

  /// Intercepts `Ctrl + Space` at the [HardwareKeyboard] layer BEFORE any
  /// focused [TextField] can insert a literal space character!
  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    final sessionModal = ModalRoute.of(context);
    if (sessionModal != null && !sessionModal.isCurrent) return false;
    if (!isSpotlightShortcut(event)) return false;

    if (widget.routeTracker.isSpotlightOpen) {
      widget.routeTracker.closeIfOpen();
      return true;
    }

    _openSpotlight();
    return true;
  }

  void _openSpotlight({String? initialQuery}) {
    final nav = widget.navigatorKey.currentState;
    final overlayContext = nav?.overlay?.context;
    if (nav == null || overlayContext == null || !overlayContext.mounted) return;

    if (widget.routeTracker.isSpotlightOpen) {
      if (initialQuery == null || initialQuery.trim().isEmpty) {
        widget.routeTracker.closeIfOpen();
        return;
      }
      widget.routeTracker.closeIfOpen();
    }

    final callbacks = widget.controller.callbacksProvider?.call() ?? const SpotlightShellCallbacks();
    unawaited(
      nav.push(
        buildSpotlightRoute(
          hostContext: overlayContext,
          hostNavigator: nav,
          callbacks: callbacks,
          initialQuery: initialQuery,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SpotlightScope(controller: widget.controller, child: widget.child);
  }
}
