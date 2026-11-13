import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../navigation/navigation_tabs.dart';
import '../theme/app_motion.dart';
import 'app_icon.dart';
import 'glass_surface.dart';
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
    required this.onDestinationSelected,
    this.onActiveTabReselected,
    this.onLibrariesLongPress,
    this.onSearchPressed,
  });

  final List<NavigationTab> tabs;
  final NavigationTabId selectedTab;
  final bool hideLabels;
  final ValueChanged<NavigationTabId> onDestinationSelected;
  final VoidCallback? onActiveTabReselected;
  final VoidCallback? onLibrariesLongPress;
  final VoidCallback? onSearchPressed;

  static const double _heightWithLabels = 60.0;
  static const double _heightCompact = 52.0;
  static const double _capsuleHorizontalInset = 6.0;
  static const double _capsuleVerticalInset = 4.0;
  static const BorderRadius _capsuleRadius = BorderRadius.all(Radius.circular(999));

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();

    return _NativeTabBar(
      tabs: tabs,
      selectedTab: selectedTab,
      hideLabels: hideLabels,
      onDestinationSelected: onDestinationSelected,
      onActiveTabReselected: onActiveTabReselected,
      onSearchPressed: onSearchPressed,
    );
  }
}

class _NativeTabBar extends StatefulWidget {
  const _NativeTabBar({
    required this.tabs,
    required this.selectedTab,
    required this.hideLabels,
    required this.onDestinationSelected,
    this.onActiveTabReselected,
    this.onSearchPressed,
  });
  final List<NavigationTab> tabs;
  final NavigationTabId selectedTab;
  final bool hideLabels;
  final ValueChanged<NavigationTabId> onDestinationSelected;
  final VoidCallback? onActiveTabReselected;
  final VoidCallback? onSearchPressed;
  @override
  State<_NativeTabBar> createState() => _NativeTabBarState();
}

class _NativeTabBarState extends State<_NativeTabBar> {
  MethodChannel? _channel;
  Map<String, Object> get _params => {
    'tabs': [
      for (final tab in widget.tabs) {'id': tab.id.name, 'label': tab.getLabel()},
    ],
    'selected': widget.tabs.indexWhere((tab) => tab.id == widget.selectedTab).clamp(0, widget.tabs.length - 1),
    'hideLabels': widget.hideLabels,
    'dark': Theme.of(context).brightness == Brightness.dark,
  };
  @override
  void didUpdateWidget(covariant _NativeTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _channel?.invokeMethod<void>('update', _params);
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: SizedBox(
          height: widget.hideLabels ? 52 : 60,
          child: UiKitView(
            viewType: 'com.satra/ios_tab_bar',
            creationParams: _params,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: (id) {
              final channel = MethodChannel('com.satra/ios_tab_bar/$id');
              _channel = channel;
              channel.setMethodCallHandler((call) async {
                if (call.method != 'selected' || !mounted) return;
                final index = call.arguments as int;
                if (index == widget.tabs.length) {
                  widget.onSearchPressed?.call();
                  channel.invokeMethod<void>('update', _params);
                  return;
                }
                if (index < 0 || index >= widget.tabs.length) return;
                final tab = widget.tabs[index];
                if (tab.id == widget.selectedTab) {
                  widget.onActiveTabReselected?.call();
                } else {
                  widget.onDestinationSelected(tab.id);
                }
              });
              channel.invokeMethod<void>('update', _params);
            },
          ),
        ),
      ),
      if (widget.onSearchPressed != null) ...[
        const SizedBox(width: 4),
        _MobileGlassSearchOrb(size: 48, onPressed: widget.onSearchPressed!),
      ],
    ],
  );
}

class _LegacyMobileGlassTabBar extends MobileGlassTabBar {
  const _LegacyMobileGlassTabBar({
    required super.tabs,
    required super.selectedTab,
    required super.hideLabels,
    required super.onDestinationSelected,
    super.onActiveTabReselected,
    super.onLibrariesLongPress,
    super.onSearchPressed,
  });
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glassTint = isDark ? const Color(0xFF07080C) : null;
    final barHeight = hideLabels ? MobileGlassTabBar._heightCompact : MobileGlassTabBar._heightWithLabels;
    final selectedIndex = tabs.indexWhere((tab) => tab.id == selectedTab);
    final activeIndex = selectedIndex >= 0 ? selectedIndex : 0;

    final tabCapsule = SizedBox(
      height: barHeight,
      child: GlassSurface(
        interactive: true,
        borderRadius: MobileGlassTabBar._capsuleRadius,
        sigma: 28,
        opacity: 0.68,
        tint: glassTint,
        child: _TabCapsuleInterior(
          tabs: tabs,
          activeIndex: activeIndex,
          hideLabels: hideLabels,
          onDestinationSelected: onDestinationSelected,
          onActiveTabReselected: onActiveTabReselected,
          onLibrariesLongPress: onLibrariesLongPress,
        ),
      ),
    );

    final searchCallback = onSearchPressed;
    if (searchCallback == null) return tabCapsule;

    return Row(
      children: [
        Expanded(child: tabCapsule),
        const SizedBox(width: 10),
        _MobileGlassSearchOrb(
          key: const ValueKey('mobile_glass_search_orb'),
          size: barHeight,
          tint: glassTint,
          onPressed: searchCallback,
        ),
      ],
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
    if (widget.tabs.isEmpty || _lastSlotWidth <= 0) return;
    _activePointer = event.pointer;
    _downLocalPosition = event.localPosition;
    _isScrubbing = false;
    _longPressFired = false;

    final touchedVisualSlot = _visualSlotFromDx(event.localPosition.dx).round();
    final touchedIndex = _logicalIndexForVisualSlot(touchedVisualSlot);
    setState(() {
      _scrubVisualSlot = touchedVisualSlot.toDouble();
    });
    _loupeController.forward();

    _librariesLongPressTimer?.cancel();
    if (widget.tabs[touchedIndex].id == NavigationTabId.libraries && widget.onLibrariesLongPress != null) {
      _librariesLongPressTimer = Timer(const Duration(milliseconds: 460), () {
        if (!mounted || _activePointer == null || _isScrubbing) return;
        _longPressFired = true;
        _loupeController.reverse();
        HapticFeedback.mediumImpact();
        widget.onLibrariesLongPress!();
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer || _longPressFired || _lastSlotWidth <= 0) return;
    final down = _downLocalPosition;
    if (down != null && (event.localPosition - down).distance > 8.0 && !_isScrubbing) {
      _isScrubbing = true;
      _librariesLongPressTimer?.cancel();
    }
    if (!_isScrubbing) return;

    final continuousVisual = _visualSlotFromDx(event.localPosition.dx);
    final hoveredIndex = _logicalIndexForVisualSlot(continuousVisual.round());
    setState(() {
      _scrubVisualSlot = continuousVisual;
    });
    if (hoveredIndex != widget.activeIndex) {
      HapticFeedback.selectionClick();
      widget.onDestinationSelected(widget.tabs[hoveredIndex].id);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_activePointer != event.pointer) return;
    _librariesLongPressTimer?.cancel();
    final wasLongPress = _longPressFired;
    final wasScrubbing = _isScrubbing;
    _activePointer = null;
    _downLocalPosition = null;
    _isScrubbing = false;
    _longPressFired = false;
    _loupeController.reverse();

    if (!wasLongPress && _lastSlotWidth > 0 && widget.tabs.isNotEmpty) {
      final targetVisual = _visualSlotFromDx(event.localPosition.dx).round();
      final targetIndex = _logicalIndexForVisualSlot(targetVisual);
      if (targetIndex != widget.activeIndex) {
        if (!wasScrubbing) HapticFeedback.selectionClick();
        widget.onDestinationSelected(widget.tabs[targetIndex].id);
      } else if (!wasScrubbing) {
        widget.onActiveTabReselected?.call();
      }
    }

    setState(() {
      _scrubVisualSlot = null;
    });
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_activePointer != event.pointer) return;
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

        final labelStyle = TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.15,
          color: theme.colorScheme.onSurface,
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
            labelWidth: (slotWidth - 8).clamp(1.0, double.infinity),
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
    required this.onSemanticsTap,
  });

  final NavigationTab tab;
  final bool selected;
  final bool hideLabels;
  final VoidCallback onSemanticsTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final label = tab.getLabel();
    final fgColor = selected ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.72);

    return Semantics(
      selected: selected,
      button: true,
      label: label,
      onTap: onSemanticsTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(tab.icon, fill: selected ? 1 : 0, size: hideLabels ? 23 : 21, color: fgColor),
            if (!hideLabels) ...[
              const SizedBox(height: 2),
              ExcludeSemantics(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.15,
                    letterSpacing: -0.15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fgColor,
                  ),
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
  const _MobileGlassSearchOrb({super.key, required this.size, required this.onPressed, this.tint});

  final double size;
  final VoidCallback onPressed;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: t.common.search,
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
            child: GlassSurface(
              interactive: true,
              borderRadius: MobileGlassTabBar._capsuleRadius,
              sigma: 28,
              opacity: 0.68,
              tint: tint,
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
