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
/// thumb scrubbing across tabs) and an optional detached Spotlight Search orb.
class MobileGlassTabBar extends StatelessWidget {
  const MobileGlassTabBar({
    super.key,
    required this.tabs,
    required this.selectedTab,
    required this.hideLabels,
    this.isLandscape = false,
    required this.onDestinationSelected,
    this.onActiveTabReselected,
    this.onLibrariesLongPress,
    this.onSearchPressed,
  });

  final List<NavigationTab> tabs;
  final NavigationTabId selectedTab;
  final bool hideLabels;
  final bool isLandscape;
  final ValueChanged<NavigationTabId> onDestinationSelected;
  final VoidCallback? onActiveTabReselected;
  final VoidCallback? onLibrariesLongPress;
  final VoidCallback? onSearchPressed;

  static const double _heightWithLabels = 64.0;
  static const double _heightCompact = 52.0;
  static const double _capsuleHorizontalInset = 3.0;
  static const double _capsuleVerticalInset = 4.0;
  static const BorderRadius _capsuleRadius = BorderRadius.all(Radius.circular(999));

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();

    final barHeight = hideLabels ? _heightCompact : _heightWithLabels;
    final selectedIndex = tabs.indexWhere((tab) => tab.id == selectedTab);
    final activeIndex = selectedIndex >= 0 ? selectedIndex : 0;

    final tabCapsule = IOSGlassControl.adaptive(
      native: (_) => SizedBox(
        height: hideLabels ? 58 : (isLandscape ? 86 : 78),
        child: IOSGlassControl(
          configuration: {
            'kind': 'tabBar',
            'tabs': [
              for (final tab in tabs) {'id': tab.id.name, 'label': tab.getLabel()},
            ],
            'selected': tabs[activeIndex].id.name,
            'hideLabels': hideLabels,
            if (onLibrariesLongPress != null) 'quickPicker': t.libraries.selectLibrary,
          },
          onAction: (action, value) {
            if (action == 'librariesHeld') {
              onLibrariesLongPress?.call();
            } else if (action == 'selected') {
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
      child: SizedBox(
        height: barHeight,
        child: _NavigationGlass(
          child: _TabCapsuleInterior(
            tabs: tabs,
            activeIndex: activeIndex,
            hideLabels: hideLabels,
            onDestinationSelected: onDestinationSelected,
            onActiveTabReselected: onActiveTabReselected,
            onLibrariesLongPress: onLibrariesLongPress,
          ),
        ),
      ),
    );

    final searchCallback = onSearchPressed;
    if (searchCallback == null) return tabCapsule;

    return Row(
      children: [
        Expanded(child: tabCapsule),
        SizedBox(width: isLandscape ? 12 : 8),
        _MobileGlassSearchOrb(
          key: const ValueKey('mobile_glass_search_orb'),
          size: hideLabels ? _heightCompact : (isLandscape ? 62 : 57),
          nativeVerticalOffset: -3,
          onPressed: searchCallback,
        ),
      ],
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

class _TabCapsuleInterior extends StatefulWidget {
  const _TabCapsuleInterior({
    required this.tabs,
    required this.activeIndex,
    required this.hideLabels,
    required this.onDestinationSelected,
    this.onActiveTabReselected,
    this.onLibrariesLongPress,
  });

  final List<NavigationTab> tabs;
  final int activeIndex;
  final bool hideLabels;
  final ValueChanged<NavigationTabId> onDestinationSelected;
  final VoidCallback? onActiveTabReselected;
  final VoidCallback? onLibrariesLongPress;

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

  @override
  void dispose() {
    _librariesLongPressTimer?.cancel();
    _loupeController.dispose();
    super.dispose();
  }

  int _logicalIndexForVisualSlot(int visualSlot) {
    final count = widget.tabs.length;
    if (count == 0) return 0;
    final clamped = visualSlot.clamp(0, count - 1);
    return _lastIsRtl ? (count - 1 - clamped) : clamped;
  }

  double _visualSlotFromDx(double dx) {
    if (_lastSlotWidth <= 0 || widget.tabs.isEmpty) return 0.0;
    final raw = (dx - MobileGlassTabBar._capsuleHorizontalInset) / _lastSlotWidth - 0.5;
    return raw.clamp(0.0, (widget.tabs.length - 1).toDouble());
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
    if (widget.tabs[touchedIndex].id == NavigationTabId.libraries && onLibrariesLongPress != null) {
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
    final hoveredIndex = _logicalIndexForVisualSlot(continuousVisual.round());
    setState(() {
      _scrubVisualSlot = continuousVisual;
    });
    final hoveredTab = widget.tabs[hoveredIndex].id;
    final previousTab = _lastScrubbedTab ?? widget.tabs[widget.activeIndex].id;
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
    final targetTab = widget.tabs[targetIndex].id;
    if (wasScrubbing ? targetTab != lastScrubbedTab : targetIndex != widget.activeIndex) {
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final innerWidth = (constraints.maxWidth - MobileGlassTabBar._capsuleHorizontalInset * 2).clamp(
          0.0,
          double.infinity,
        );
        final slotWidth = widget.tabs.isEmpty ? 0.0 : innerWidth / widget.tabs.length;
        _lastSlotWidth = slotWidth;
        _lastIsRtl = isRtl;

        final settledVisualSlot = (isRtl ? (widget.tabs.length - 1 - widget.activeIndex) : widget.activeIndex)
            .toDouble();
        final visualSlot = _scrubVisualSlot ?? settledVisualSlot;
        final indicatorLeft = MobileGlassTabBar._capsuleHorizontalInset + visualSlot * slotWidth;

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
                    tab: widget.tabs[i],
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
            ],
          ),
        );

        if (!widget.hideLabels && slotWidth > 0) {
          itemsRow = NavigationLabelScale(
            labels: [for (final tab in widget.tabs) tab.getLabel()],
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
              if (slotWidth > 0)
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
    required this.tab,
    required this.selected,
    required this.hideLabels,
    required this.labelStyle,
    required this.onSemanticsTap,
    this.onSemanticsLongPress,
  });

  final NavigationTab tab;
  final bool selected;
  final bool hideLabels;
  final TextStyle labelStyle;
  final VoidCallback onSemanticsTap;
  final VoidCallback? onSemanticsLongPress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final label = tab.getLabel();
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
            AppIcon(tab.icon, fill: selected ? 1 : 0, size: 24, color: fgColor),
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

class _MobileGlassSearchOrb extends StatelessWidget {
  const _MobileGlassSearchOrb({super.key, required this.size, this.nativeVerticalOffset = 0, required this.onPressed});

  final double size;
  final double nativeVerticalOffset;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return IOSGlassButton(
      label: t.common.search,
      symbol: 'magnifyingglass',
      symbolSize: 21,
      regularSymbolWeight: true,
      nativeOffset: Offset(0, nativeVerticalOffset),
      onPressed: onPressed,
      child: Tooltip(
        message: t.common.search,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.lightImpact();
            onPressed();
          },
          child: SizedBox(
            width: size,
            height: size,
            child: _NavigationGlass(
              child: Center(
                child: AppIcon(Symbols.search_rounded, size: 22, color: colorScheme.onSurface.withValues(alpha: 0.90)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
