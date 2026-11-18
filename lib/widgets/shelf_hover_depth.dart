import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../theme/app_motion.dart';
import '../utils/platform_detector.dart';
import 'settings_builder.dart';

/// Shares pointer state between a shelf's cards and its heading. Only the
/// heading listens for changes, so hovering a card never rebuilds the shelf.
class ShelfHoverDepth extends StatefulWidget {
  const ShelfHoverDepth({super.key, required this.child});

  final Widget child;

  static bool get supported => PlatformDetector.isDesktopOS() && !PlatformDetector.isTVDevice();

  static ShelfHoverDepthState? maybeOf(BuildContext context) => context.findAncestorStateOfType<ShelfHoverDepthState>();

  @override
  State<ShelfHoverDepth> createState() => ShelfHoverDepthState();
}

class ShelfHoverDepthState extends State<ShelfHoverDepth> {
  final _heading = GlobalKey();
  final _cardNearHeading = ValueNotifier(false);
  BuildContext? _hoveredCard;
  bool _updateScheduled = false;

  void enterCard(BuildContext card) {
    _hoveredCard = card;
    _scheduleUpdate();
  }

  void leaveCard(BuildContext card) {
    if (_hoveredCard != card) return;
    _hoveredCard = null;
    _scheduleUpdate();
  }

  void _scheduleUpdate() {
    if (_updateScheduled) return;
    _updateScheduled = true;
    // Read paint bounds after layout, including when a stationary pointer
    // stays on a card as the shelf scrolls horizontally.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (mounted) _cardNearHeading.value = _isCardNearHeading();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _isCardNearHeading() {
    final cardContext = _hoveredCard;
    final heading = _heading.currentContext?.findRenderObject();
    if (cardContext == null || !cardContext.mounted || heading is! RenderBox || !heading.hasSize) return false;
    final card = cardContext.findRenderObject();
    if (card is! RenderBox || !card.hasSize || !card.attached || !heading.attached) return false;

    final cardBounds = MatrixUtils.transformRect(card.getTransformTo(heading), Offset.zero & card.size);
    final headingSize = heading.size;
    final horizontalSlack = headingSize.height * 0.75;
    return cardBounds.left < headingSize.width + horizontalSlack &&
        cardBounds.right > -horizontalSlack &&
        cardBounds.top < headingSize.height * 2.5 &&
        cardBounds.bottom > 0;
  }

  @override
  void dispose() {
    _cardNearHeading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollUpdateNotification>(
    onNotification: (notification) {
      if (notification.metrics.axis == Axis.horizontal && _hoveredCard != null) _scheduleUpdate();
      return false;
    },
    child: widget.child,
  );
}

class ShelfHeading extends StatelessWidget {
  const ShelfHeading({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!ShelfHoverDepth.supported) return child;
    final shelf = ShelfHoverDepth.maybeOf(context);
    if (shelf == null) return child;

    return SettingValueBuilder<double>(
      pref: SettingsService.shelfHeadingHoverOpacity,
      child: SizedBox(key: shelf._heading, child: child),
      builder: (context, opacity, child) => ValueListenableBuilder<bool>(
        valueListenable: shelf._cardNearHeading,
        child: child,
        builder: (context, cardNearHeading, child) {
          final accessible = MediaQuery.highContrastOf(context) || MediaQuery.accessibleNavigationOf(context);
          return AnimatedOpacity(
            opacity: enabled && cardNearHeading && !accessible ? opacity.clamp(0.55, 1.0) : 1,
            duration: AppMotion.duration(context, AppMotion.fast),
            curve: AppMotion.curve,
            child: child,
          );
        },
      ),
    );
  }
}
