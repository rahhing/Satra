import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../focus/focusable_chip_mixin.dart';
import '../focus/input_mode_tracker.dart';
import '../theme/app_motion.dart';
import '../theme/mono_tokens.dart';
import 'focus_builders.dart';

/// Retained browsing pages hand their current pill positions to the incoming
/// page, so Home/library transitions continue the same movement.
class TabChipMotionScope extends StatefulWidget {
  const TabChipMotionScope({super.key, required this.child});
  final Widget child;

  @override
  State<TabChipMotionScope> createState() => _TabChipMotionScopeState();
}

class _TabChipMotionScopeState extends State<TabChipMotionScope> {
  final positions = <String, Map<int, Rect>>{};

  @override
  Widget build(BuildContext context) => _TabChipMotionHistory(positions: positions, child: widget.child);
}

class _TabChipMotionHistory extends InheritedWidget {
  const _TabChipMotionHistory({required this.positions, required super.child});
  final Map<String, Map<int, Rect>> positions;

  @override
  bool updateShouldNotify(_TabChipMotionHistory oldWidget) => false;
}

/// Horizontally scrollable host for a row of [FocusableTabChip]s.
///
/// App-bar titles and header rows give the strip a bounded width; a plain
/// Row overflows it on narrow windows (visible as the striped overflow
/// indicator). The strip shrink-wraps like `mainAxisSize: min` and scrolls
/// instead. D-pad stays correct: chips center themselves on focus via the
/// chip mixin, so LEFT/RIGHT reaches off-screen tabs.
class TabChipStrip extends StatefulWidget {
  final List<Widget> children;
  final String? motionId;

  const TabChipStrip({super.key, required this.children, this.motionId});

  @override
  State<TabChipStrip> createState() => _TabChipStripState();
}

class _TabChipStripState extends State<TabChipStrip> with TickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);
  late final _indicatorController = AnimationController(vsync: this);
  late final _progress = CurvedAnimation(parent: _controller, curve: AppMotion.curve);
  bool _active = false;

  String _labels(TabChipStrip strip) =>
      strip.children.whereType<FocusableTabChip>().map((chip) => chip.label).join('\n');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = AppMotion.duration(context);
    _indicatorController.duration = AppMotion.duration(context);
    final active = TickerMode.valuesOf(context).enabled;
    final shared = widget.motionId != null && context.getInheritedWidgetOfExactType<_TabChipMotionHistory>() != null;
    if (shared) {
      _controller.value = 1;
    } else if (active && !_active) {
      _controller.forward(from: 0);
    }
    _active = active;
  }

  @override
  void didUpdateWidget(TabChipStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_active && widget.motionId == null && _labels(oldWidget) != _labels(widget)) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    _indicatorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: AnimatedSize(
      duration: AppMotion.duration(context),
      curve: AppMotion.curve,
      alignment: AlignmentDirectional.centerStart,
      child: FadeTransition(
        opacity: _progress,
        child: SlideTransition(
          position: Tween(begin: const Offset(0.015, 0), end: Offset.zero).animate(_progress),
          child: _TabIndicatorScope(
            child: _TabChipRow(
              active: _active,
              history: context.getInheritedWidgetOfExactType<_TabChipMotionHistory>()?.positions,
              motionId: widget.motionId,
              controller: _indicatorController,
              color: Theme.of(context).colorScheme.primary,
              cornerRadius: (Theme.of(context).extension<MonoTokens>()?.radiusSm ?? 12) * 5 / 3,
              textDirection: Directionality.of(context),
              selections: {
                for (var i = 0; i < widget.children.length; i++)
                  if (widget.children[i] case FocusableTabChip(isSelected: true, :final indicatorGroup))
                    i: indicatorGroup,
              },
              children: widget.children,
            ),
          ),
        ),
      ),
    ),
  );
}

/// A focusable tab chip that shows a color change when focused or selected.
///
/// Used for tab navigation in LibrariesScreen. Handles:
/// - SELECT key to activate the tab
/// - LEFT/RIGHT arrows to switch between tabs
/// - DOWN arrow to navigate to tab content
/// - BACK key to navigate to sidenav
class FocusableTabChip extends StatefulWidget {
  final String label;
  final bool isSelected;
  final int indicatorGroup;
  final VoidCallback onSelect;

  /// Optional external focus node for programmatic focus control.
  final FocusNode? focusNode;

  /// Called when the user presses LEFT from this chip.
  /// Should switch to the previous tab.
  final VoidCallback? onNavigateLeft;

  /// Called when the user presses RIGHT from this chip.
  /// Should switch to the next tab.
  final VoidCallback? onNavigateRight;

  /// Called when the user presses DOWN from this chip.
  final VoidCallback? onNavigateDown;

  /// Called when the user presses UP from this chip.
  final VoidCallback? onNavigateUp;

  /// Called when the user presses BACK from this chip.
  final VoidCallback? onBack;

  /// Called when SELECT key is held (D-pad long press).
  final VoidCallback? onLongPress;

  /// Optional image to show above the label (e.g. a poster).
  /// When provided, the chip lays out vertically with image on top, label below.
  final Widget? topImage;

  const FocusableTabChip({
    super.key,
    required this.label,
    required this.isSelected,
    this.indicatorGroup = 0,
    required this.onSelect,
    this.focusNode,
    this.onNavigateLeft,
    this.onNavigateRight,
    this.onNavigateDown,
    this.onNavigateUp,
    this.onBack,
    this.onLongPress,
    this.topImage,
  });

  @override
  State<FocusableTabChip> createState() => _FocusableTabChipState();
}

class _FocusableTabChipState extends State<FocusableTabChip> with FocusableChipStateMixin<FocusableTabChip> {
  @override
  void revealChipOnFocus() {
    final box = context.findRenderObject();
    if (context.getInheritedWidgetOfExactType<_TabIndicatorScope>() != null && box is RenderBox) {
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport is RenderBox) {
        final rect = MatrixUtils.transformRect(box.getTransformTo(viewport), box.paintBounds);
        if (rect.left >= 0 && rect.right <= (viewport as RenderBox).size.width) return;
      }
    }
    super.revealChipOnFocus();
  }

  @override
  FocusNode? get widgetFocusNode => widget.focusNode;

  @override
  String get debugLabel => 'tab_chip_${widget.label}';

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    return handleChipKeyEvent(
      node,
      event,
      ChipKeyCallbacks(
        onSelect: widget.onSelect,
        onLongPress: widget.onLongPress,
        onNavigateLeft: widget.onNavigateLeft,
        onNavigateRight: widget.onNavigateRight,
        onNavigateDown: widget.onNavigateDown,
        onNavigateUp: widget.onNavigateUp,
        onBack: widget.onBack,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Only show focus effects during keyboard/d-pad navigation
    final showFocus = isFocused && InputModeTracker.isKeyboardMode(context);

    final sharedIndicator = context.dependOnInheritedWidgetOfExactType<_TabIndicatorScope>() != null;
    final backgroundColor = widget.isSelected && !sharedIndicator ? colorScheme.primary : Colors.transparent;
    final foregroundColor = widget.isSelected ? colorScheme.onPrimary : colorScheme.onSurface;
    final duration = AppMotion.duration(context);
    final label = AnimatedDefaultTextStyle(
      duration: duration,
      curve: AppMotion.curve,
      style: Theme.of(context).textTheme.labelLarge!.copyWith(
        color: foregroundColor,
        fontWeight: widget.isSelected ? FontWeight.w600 : FontWeight.w500,
      ),
      child: Text(widget.label),
    );

    final hasImage = widget.topImage != null;
    final chip = FocusBuilders.buildFocusableChip(
      context: context,
      focusNode: focusNode,
      onKeyEvent: _handleKeyEvent,
      onTap: widget.onSelect,
      semanticLabel: widget.label,
      selected: widget.isSelected,
      padding: hasImage ? const EdgeInsets.all(8) : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      backgroundColor: backgroundColor,
      animationDuration: duration,
      borderRadius: hasImage
          ? (Theme.of(context).extension<MonoTokens>()?.radiusSm ?? 12)
          : (Theme.of(context).extension<MonoTokens>()?.radiusSm ?? 12) * 5 / 3,
      child: hasImage
          ? Column(
              mainAxisSize: .min,
              children: [
                ClipRRect(borderRadius: BorderRadius.circular(6), child: widget.topImage!),
                const SizedBox(height: 6),
                label,
              ],
            )
          : label,
    );
    return AnimatedContainer(
      duration: duration,
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(
          hasImage
              ? (Theme.of(context).extension<MonoTokens>()?.radiusSm ?? 12)
              : (Theme.of(context).extension<MonoTokens>()?.radiusSm ?? 12) * 5 / 3,
        ),
        border: Border.all(color: showFocus ? colorScheme.primary : Colors.transparent),
      ),
      child: chip,
    );
  }
}

// A single painted pill per navigation group moves between the actual laid-out
// chip bounds. Foreground widgets keep their focus nodes and hit-test paths.
class _TabIndicatorScope extends InheritedWidget {
  const _TabIndicatorScope({required super.child});

  @override
  bool updateShouldNotify(_TabIndicatorScope oldWidget) => false;
}

class _TabChipRow extends MultiChildRenderObjectWidget {
  const _TabChipRow({
    required this.active,
    required this.history,
    required this.motionId,
    required this.controller,
    required this.color,
    required this.textDirection,
    required this.selections,
    required this.cornerRadius,
    required super.children,
  });

  final AnimationController controller;
  final Color color;
  final TextDirection textDirection;
  final Map<int, int> selections;
  final double cornerRadius;
  final bool active;
  final Map<String, Map<int, Rect>>? history;
  final String? motionId;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTabChipRow(controller, color, selections, textDirection)
        ..history = history
        ..motionId = motionId
        ..active = active
        ..cornerRadius = cornerRadius;

  @override
  void updateRenderObject(BuildContext context, _RenderTabChipRow renderObject) {
    renderObject
      ..history = history
      ..motionId = motionId
      ..active = active
      ..cornerRadius = cornerRadius
      ..indicatorColor = color
      ..selectedGroups = selections
      ..textDirection = textDirection;
  }
}

class _RenderTabChipRow extends RenderFlex {
  _RenderTabChipRow(this.controller, this._color, this._selections, TextDirection direction)
    : super(direction: Axis.horizontal, mainAxisSize: MainAxisSize.min, textDirection: direction);

  final AnimationController controller;
  Color _color;
  double _cornerRadius = 20;
  set cornerRadius(double value) {
    if (_cornerRadius == value) return;
    _cornerRadius = value;
    markNeedsPaint();
  }

  Map<int, int> _selections;
  Map<int, Rect> _from = {};
  Map<int, Rect> _to = {};
  bool _laidOut = false;
  bool _active = false;
  bool _activationPending = false;
  Map<String, Map<int, Rect>>? history;
  String? motionId;

  set active(bool value) {
    if (value == _active) return;
    _active = value;
    _activationPending = value;
    markNeedsLayout();
  }

  set indicatorColor(Color color) {
    if (color == _color) return;
    _color = color;
    markNeedsPaint();
  }

  set selectedGroups(Map<int, int> groups) {
    if (mapEquals(groups, _selections)) return;
    _selections = groups;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    controller.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    controller.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    final targets = <int, Rect>{};
    var index = 0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final group = _selections[index++];
      if (group == null) continue;
      final data = child.parentData! as FlexParentData;
      targets[group] = (data.offset & child.size).deflate(1);
    }
    if (!_active) {
      _from = targets;
      _to = targets;
      _laidOut = true;
      return;
    }
    if (mapEquals(targets, _to) && !_activationPending) return;
    final shared = _activationPending && history != null ? history![motionId] : null;
    final progress = AppMotion.curve.transform(controller.value);
    _from =
        shared ??
        (_laidOut
            ? {
                for (final group in {..._from.keys, ..._to.keys}) group: Rect.lerp(_from[group], _to[group], progress)!,
              }
            : targets);
    _to = targets;
    if (_laidOut || shared != null) controller.forward(from: 0);
    _activationPending = false;
    _laidOut = true;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final progress = AppMotion.curve.transform(controller.value);
    final current = <int, Rect>{};
    for (final group in {..._from.keys, ..._to.keys}) {
      final rect = Rect.lerp(_from[group], _to[group], progress);
      if (rect == null) continue;
      current[group] = rect;
      final alpha = _from[group] == null ? progress : (_to[group] == null ? 1 - progress : 1.0);
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(rect.shift(offset), Radius.circular(_cornerRadius)),
        Paint()..color = _color.withValues(alpha: _color.a * alpha),
      );
    }
    if (_active && motionId != null) history?[motionId!] = current;
    super.paint(context, offset);
  }
}
