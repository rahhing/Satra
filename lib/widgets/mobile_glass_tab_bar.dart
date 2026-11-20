import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../navigation/navigation_tabs.dart';
import '../theme/app_motion.dart';
import 'app_icon.dart';
import 'glass_surface.dart';
import 'ios_glass_control.dart';
import 'navigation_label_fit.dart';

/// iOS 26-style floating Liquid Glass capsule tab bar with a press-and-hold
/// expandable Liquid Glass selection loupe (supporting continuous horizontal
/// thumb scrubbing across tabs) and an integrated Spotlight Search item.
class MobileGlassTabBar extends StatelessWidget {
  const MobileGlassTabBar({
    super.key,
    required this.tabs,
    required this.selectedTab,
    required this.hideLabels,
    this.isLandscape = false,
    this.separateSearch = false,
    this.isSearchSelected = false,
    this.fallbackPadding = EdgeInsets.zero,
    required this.onDestinationSelected,
    this.onActiveTabReselected,
    this.onLibrariesLongPress,
    this.onSearchPressed,
  });

  final List<NavigationTab> tabs;
  final NavigationTabId selectedTab;
  final bool hideLabels;
  final bool isLandscape;
  final bool separateSearch;
  final bool isSearchSelected;
  final EdgeInsets fallbackPadding;
  final ValueChanged<NavigationTabId> onDestinationSelected;
  final VoidCallback? onActiveTabReselected;
  final VoidCallback? onLibrariesLongPress;
  final VoidCallback? onSearchPressed;

  static const double _heightWithLabels = 70.0;
  static const double _heightCompact = 58.0;
  static const double _heightLandscapeWithLabels = 54.0;
  static const double _heightLandscapeCompact = 48.0;
  static const double _capsuleHorizontalInset = 3.0;
  static const double _capsuleVerticalInset = 4.0;
  static const BorderRadius _capsuleRadius = BorderRadius.all(Radius.circular(999));

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();

    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final barHeight = isLandscape
        ? (hideLabels ? _heightLandscapeCompact : _heightLandscapeWithLabels)
        : (hideLabels ? _heightCompact : _heightWithLabels);
    // Native UITabBar sits flush at the physical bottom edge (matching
    // UITabBarController / SwiftUI TabView) so UIKit's real safeAreaInsets
    // size and position the floating Liquid Glass capsule identically to
    // every native iOS app.
    final nativeHeight = (isLandscape ? 58.0 : 64.0) + safeBottom;
    final selectedIndex = tabs.indexWhere((tab) => tab.id == selectedTab);
    final activeIndex = selectedIndex >= 0 ? selectedIndex : 0;
    final searchCallback = onSearchPressed;
    final searchSelected = isSearchSelected && searchCallback != null;
    final useSeparateSearchOrb = searchCallback != null && separateSearch;

    final mainCapsule = _NavigationGlass(
      child: _TabCapsuleInterior(
        tabs: tabs,
        activeIndex: searchSelected ? (useSeparateSearchOrb ? -1 : tabs.length) : activeIndex,
        hideLabels: hideLabels,
        onDestinationSelected: onDestinationSelected,
        onActiveTabReselected: onActiveTabReselected,
        onLibrariesLongPress: onLibrariesLongPress,
        onSearchPressed: useSeparateSearchOrb ? null : searchCallback,
      ),
    );

    final fallbackBar = SizedBox(
      height: barHeight,
      child: useSeparateSearchOrb
          ? Row(
              children: [
                Expanded(child: mainCapsule),
                const SizedBox(width: 10),
                _SeparateSearchOrb(size: barHeight, selected: searchSelected, onPressed: searchCallback),
              ],
            )
          : mainCapsule,
    );

    return IOSGlassControl.adaptive(
      native: (_) => SizedBox(
        width: double.infinity,
        height: nativeHeight,
        child: IOSGlassControl(
          configuration: {
            'kind': 'tabBar',
            'tabs': [
              for (final tab in tabs) {'id': tab.id.name, 'label': tab.getLabel()},
              if (searchCallback != null) {'id': 'search', 'label': t.common.search},
            ],
            'selected': searchSelected ? 'search' : tabs[activeIndex].id.name,
            'hideLabels': hideLabels,
            'isLandscape': isLandscape,
            'separateSearch': separateSearch,
            if (onLibrariesLongPress != null) 'quickPicker': t.libraries.selectLibrary,
          },
          onAction: (action, value) {
            if (action == 'librariesHeld') {
              onLibrariesLongPress?.call();
            } else if (action == 'searchPressed') {
              searchCallback?.call();
            } else if (action == 'selected') {
              if (value == 'search') {
                searchCallback?.call();
                return;
              }
              for (final tab in tabs) {
                if (tab.id.name != value) continue;
                if (tab.id == selectedTab) {
                  onActiveTabReselected?.call();
                } else {
                  onDestinationSelected(tab.id);
                }
                break;
              }
            }
          },
        ),
      ),
      child: Padding(
        padding: fallbackPadding,
        child: isLandscape
            ? Center(
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: fallbackBar),
              )
            : fallbackBar,
      ),
    );
  }
}

class _NavigationGlass extends StatelessWidget {
  const _NavigationGlass({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassSurface(
      interactive: true,
      borderRadius: MobileGlassTabBar._capsuleRadius,
      sigma: 28,
      opacity: 0.80,
      tint: isDark ? const Color(0xFF07080C) : null,
      child: child,
    );
  }
}

class _SeparateSearchOrb extends StatelessWidget {
  const _SeparateSearchOrb({required this.size, this.selected = false, required this.onPressed});

  final double size;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final fgColor = selected ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.92);
    return Semantics(
      button: true,
      selected: selected,
      label: t.common.search,
      child: SizedBox.square(
        key: const ValueKey('mobile_glass_search_orb'),
        dimension: size,
        child: _NavigationGlass(
          child: DecoratedBox(
            decoration: selected
                ? BoxDecoration(
                    shape: BoxShape.circle,
                    color: (isDark ? Colors.white : Colors.black).withValues(alpha: isDark ? 0.14 : 0.08),
                  )
                : const BoxDecoration(),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  HapticFeedback.lightImpact();
                  onPressed();
                },
                child: Center(
                  child: AppIcon(Symbols.search_rounded, size: 25, color: fgColor),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabCapsuleInterior extends StatefulWidget {
  const _TabCapsuleInterior({
    required this.tabs,
    required this.activeIndex,
    required this.hideLabels,
    required this.onDestinationSelected,
    this.onActiveTabReselected,
    this.onLibrariesLongPress,
    this.onSearchPressed,
  });

  final List<NavigationTab> tabs;
  final int activeIndex;
  final bool hideLabels;
  final ValueChanged<NavigationTabId> onDestinationSelected;
  final VoidCallback? onActiveTabReselected;
  final VoidCallback? onLibrariesLongPress;
  final VoidCallback? onSearchPressed;

  @override
  State<_TabCapsuleInterior> createState() => _TabCapsuleInteriorState();
}

class _TabCapsuleInteriorState extends State<_TabCapsuleInterior> with SingleTickerProviderStateMixin {
  late final AnimationController _loupeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
    reverseDuration: const Duration(milliseconds: 250),
  );

  int? _activePointer;
  Offset? _downLocalPosition;
  double? _scrubVisualSlot;
  bool _isScrubbing = false;
  bool _longPressFired = false;
  NavigationTabId? _lastScrubbedTab;
  Timer? _librariesLongPressTimer;
  double _lastSlotWidth = 0.0;
  bool _lastIsRtl = false;

  bool get _hasSearch => widget.onSearchPressed != null;
  int get _slotCount => widget.tabs.length + (_hasSearch ? 1 : 0);
  int get _searchLogicalIndex => widget.tabs.length;

  @override
  void dispose() {
    _librariesLongPressTimer?.cancel();
    _loupeController.dispose();
    super.dispose();
  }

  int _logicalIndexForVisualSlot(int visualSlot) {
    final count = _slotCount;
    if (count == 0) return 0;
    final clamped = visualSlot.clamp(0, count - 1);
    return _lastIsRtl ? (count - 1 - clamped) : clamped;
  }

  double _visualSlotFromDx(double dx) {
    final count = _slotCount;
    if (_lastSlotWidth <= 0 || count == 0) return 0.0;
    final raw = (dx - MobileGlassTabBar._capsuleHorizontalInset) / _lastSlotWidth - 0.5;
    return raw.clamp(0.0, (count - 1).toDouble());
  }

  double _visualSlotForLogicalIndex(int logicalIndex) {
    final count = _slotCount;
    return (_lastIsRtl ? (count - 1 - logicalIndex) : logicalIndex).toDouble();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_activePointer != null || _lastSlotWidth <= 0 || event.buttons != kPrimaryButton) return;
    _activePointer = event.pointer;
    _downLocalPosition = event.localPosition;
    _isScrubbing = false;
    _longPressFired = false;
    _lastScrubbedTab = null;

    final touchedVisualSlot = _visualSlotFromDx(event.localPosition.dx).round();
    final touchedIndex = _logicalIndexForVisualSlot(touchedVisualSlot);
    setState(() {
      _scrubVisualSlot = touchedVisualSlot.toDouble();
    });
    _loupeController.forward();

    _librariesLongPressTimer?.cancel();
    final onLibrariesLongPress = widget.onLibrariesLongPress;
    if (touchedIndex < widget.tabs.length &&
        widget.tabs[touchedIndex].id == NavigationTabId.libraries &&
        onLibrariesLongPress != null) {
      _librariesLongPressTimer = Timer(const Duration(milliseconds: 460), () {
        if (!mounted || _activePointer == null || _isScrubbing) return;
        _longPressFired = true;
        _loupeController.reverse();
        HapticFeedback.mediumImpact();
        onLibrariesLongPress();
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer || _longPressFired || _lastSlotWidth <= 0) return;
    final delta = event.localPosition - _downLocalPosition!;
    if (!_isScrubbing && delta.distance > 8.0) {
      if (delta.dy.abs() > delta.dx.abs()) {
        _resetPointer();
        return;
      }
      _isScrubbing = true;
      _librariesLongPressTimer?.cancel();
    }
    if (!_isScrubbing) return;

    final continuousVisual = _visualSlotFromDx(event.localPosition.dx);
    final rawHoveredIndex = _logicalIndexForVisualSlot(continuousVisual.round());
    final clampedTabIndex = rawHoveredIndex.clamp(0, widget.tabs.length - 1);
    final displayVisual = rawHoveredIndex >= widget.tabs.length
        ? _visualSlotForLogicalIndex(clampedTabIndex)
        : continuousVisual;
    setState(() {
      _scrubVisualSlot = displayVisual;
    });
    final hoveredTab = widget.tabs[clampedTabIndex].id;
    final previousTab =
        _lastScrubbedTab ??
        (widget.activeIndex >= 0 && widget.activeIndex < widget.tabs.length
            ? widget.tabs[widget.activeIndex].id
            : null);
    _lastScrubbedTab = hoveredTab;
    if (hoveredTab != previousTab) {
      HapticFeedback.selectionClick();
      widget.onDestinationSelected(hoveredTab);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_activePointer != event.pointer) return;
    final wasLongPress = _longPressFired;
    final wasScrubbing = _isScrubbing;
    final lastScrubbedTab = _lastScrubbedTab;
    _resetPointer();

    final size = context.size;
    if (wasLongPress ||
        _lastSlotWidth <= 0 ||
        (!wasScrubbing && (size == null || !(Offset.zero & size).contains(event.localPosition)))) {
      return;
    }

    final targetIndex = _logicalIndexForVisualSlot(_visualSlotFromDx(event.localPosition.dx).round());
    if (_hasSearch && targetIndex == _searchLogicalIndex) {
      if (!wasScrubbing) {
        HapticFeedback.lightImpact();
        widget.onSearchPressed?.call();
      }
      return;
    }

    final safeTabIndex = targetIndex.clamp(0, widget.tabs.length - 1);
    final targetTab = widget.tabs[safeTabIndex].id;
    if (wasScrubbing ? targetTab != lastScrubbedTab : safeTabIndex != widget.activeIndex) {
      HapticFeedback.selectionClick();
      widget.onDestinationSelected(targetTab);
    } else if (!wasScrubbing) {
      widget.onActiveTabReselected?.call();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_activePointer == event.pointer) _resetPointer();
  }

  void _resetPointer() {
    _librariesLongPressTimer?.cancel();
    _activePointer = null;
    _downLocalPosition = null;
    _isScrubbing = false;
    _longPressFired = false;
    _loupeController.reverse();
    setState(() {
      _scrubVisualSlot = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final duration = AppMotion.duration(context, const Duration(milliseconds: 240));
    final slotCount = _slotCount;

    return LayoutBuilder(
      builder: (context, constraints) {
        final innerWidth = (constraints.maxWidth - MobileGlassTabBar._capsuleHorizontalInset * 2).clamp(
          0.0,
          double.infinity,
        );
        final slotWidth = slotCount == 0 ? 0.0 : innerWidth / slotCount;
        _lastSlotWidth = slotWidth;
        _lastIsRtl = isRtl;

        final hasSettledSelection = widget.activeIndex >= 0 && widget.activeIndex < slotCount;
        final settledVisualSlot = hasSettledSelection
            ? (isRtl ? (slotCount - 1 - widget.activeIndex) : widget.activeIndex).toDouble()
            : null;
        final visualSlot = _scrubVisualSlot ?? settledVisualSlot;
        final indicatorLeft = visualSlot != null
            ? MobileGlassTabBar._capsuleHorizontalInset + visualSlot * slotWidth
            : 0.0;

        final labelStyle = (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
          fontSize: 11,
          height: 1.15,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.15,
        );

        Widget itemsRow = Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MobileGlassTabBar._capsuleHorizontalInset,
            vertical: MobileGlassTabBar._capsuleVerticalInset,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < widget.tabs.length; i++)
                Expanded(
                  child: _MobileGlassTabButton(
                    icon: widget.tabs[i].icon,
                    label: widget.tabs[i].getLabel(),
                    selected: i == widget.activeIndex,
                    hideLabels: widget.hideLabels,
                    labelStyle: labelStyle,
                    onSemanticsLongPress: widget.tabs[i].id == NavigationTabId.libraries
                        ? widget.onLibrariesLongPress
                        : null,
                    onSemanticsTap: () {
                      if (i != widget.activeIndex) {
                        HapticFeedback.selectionClick();
                        widget.onDestinationSelected(widget.tabs[i].id);
                      } else {
                        widget.onActiveTabReselected?.call();
                      }
                    },
                  ),
                ),
              if (_hasSearch)
                Expanded(
                  child: _MobileGlassTabButton(
                    key: const ValueKey('mobile_glass_search_button'),
                    icon: Symbols.search_rounded,
                    label: t.common.search,
                    selected: widget.activeIndex == _searchLogicalIndex,
                    hideLabels: widget.hideLabels,
                    labelStyle: labelStyle,
                    onSemanticsTap: () {
                      HapticFeedback.lightImpact();
                      widget.onSearchPressed?.call();
                    },
                  ),
                ),
            ],
          ),
        );

        if (!widget.hideLabels && slotWidth > 0) {
          itemsRow = NavigationLabelScale(
            labels: [
              for (final tab in widget.tabs) tab.getLabel(),
              if (_hasSearch) t.common.search,
            ],
            labelWidth: (slotWidth - 4).clamp(1.0, double.infinity),
            style: labelStyle,
            child: itemsRow,
          );
        }

        final pillDuration = _scrubVisualSlot != null ? Duration.zero : duration;

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              if (slotWidth > 0 && visualSlot != null)
                AnimatedPositioned(
                  duration: pillDuration,
                  curve: Curves.easeOutCubic,
                  left: indicatorLeft,
                  top: MobileGlassTabBar._capsuleVerticalInset,
                  bottom: MobileGlassTabBar._capsuleVerticalInset,
                  width: slotWidth,
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _loupeController,
                      builder: (context, _) {
                        final t = Curves.easeOutCubic.transform(_loupeController.value);
                        final scaleX = 1.0 + 0.08 * t;
                        final scaleY = 1.0 + 0.14 * t;
                        final fillAlpha = isDark ? (0.15 + 0.11 * t) : (0.09 + 0.09 * t);
                        final borderAlpha = isDark ? (0.18 + 0.28 * t) : (0.58 + 0.30 * t);

                        return Transform.scale(
                          scaleX: scaleX,
                          scaleY: scaleY,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: MobileGlassTabBar._capsuleRadius,
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: isDark
                                    ? [
                                        Colors.white.withValues(alpha: fillAlpha + 0.06 * t),
                                        Colors.white.withValues(alpha: fillAlpha * 0.68),
                                      ]
                                    : [
                                        Colors.white.withValues(alpha: 0.65 * t + 0.18),
                                        Colors.black.withValues(alpha: fillAlpha),
                                      ],
                              ),
                              border: Border.all(
                                width: 0.8 + 0.35 * t,
                                color: Colors.white.withValues(alpha: borderAlpha.clamp(0.0, 1.0)),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              itemsRow,
            ],
          ),
        );
      },
    );
  }
}

class _MobileGlassTabButton extends StatelessWidget {
  const _MobileGlassTabButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.hideLabels,
    required this.labelStyle,
    required this.onSemanticsTap,
    this.onSemanticsLongPress,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool hideLabels;
  final TextStyle labelStyle;
  final VoidCallback onSemanticsTap;
  final VoidCallback? onSemanticsLongPress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fgColor = selected ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.88);

    return Semantics(
      selected: selected,
      button: true,
      label: label,
      onTap: onSemanticsTap,
      onLongPress: onSemanticsLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(icon, fill: selected ? 1 : 0, size: 24, color: fgColor),
            if (!hideLabels) ...[
              const SizedBox(height: 3),
              ExcludeSemantics(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: labelStyle.copyWith(fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: fgColor),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
