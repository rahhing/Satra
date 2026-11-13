import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:satra/utils/formatters.dart';

import '../../../media/media_item.dart';
import '../../../i18n/strings.g.dart';
import '../../../utils/platform_detector.dart';
import '../../../watch_together/widgets/watch_together_overlay.dart';
import '../../../watch_together/providers/watch_together_provider.dart';
import '../../app_bar_back_button.dart';
import '../../glass_surface.dart';
import '../../system_clock.dart';

/// Header layout style for video controls
enum VideoHeaderStyle {
  /// Multi-line: Series name on first line, episode info on second line
  multiLine,

  /// Single-line: All info combined with separators (for macOS)
  singleLine,
}

/// Shared header widget for video controls with back button and title.
///
/// Displays the video title with optional series/episode information.
/// On handheld iOS, groups the trailing Satra player controls into a sleek
/// floating interactive Liquid Glass capsule matching iOS 26's Files player.
class VideoControlsHeader extends StatelessWidget {
  final MediaItem metadata;
  final VideoHeaderStyle style;

  /// Optional trailing widget (e.g., track/chapter controls)
  final Widget? trailing;

  /// Optional callback for back button. If null, defaults to Navigator.pop(true).
  final VoidCallback? onBack;
  final VoidCallback? onCancelAutoHide;
  final VoidCallback? onStartAutoHide;

  /// Whether to show the system clock. Off for a portrait phone, where the
  /// header is too narrow to fit the clock beside the title and trailing
  /// controls.
  final bool showClock;

  const VideoControlsHeader({
    super.key,
    required this.metadata,
    this.style = VideoHeaderStyle.multiLine,
    this.trailing,
    this.onBack,
    this.onCancelAutoHide,
    this.onStartAutoHide,
    this.showClock = true,
  });

  @override
  Widget build(BuildContext context) {
    final itemTitle = metadata.title ?? t.common.unknown;
    final useIOSLiquidGlass = PlatformDetector.isHandheldIOS(context);

    final watchTogetherBadge = Selector<WatchTogetherProvider, bool>(
      selector: (_, p) => p.isInSession,
      builder: (context, inSession, child) {
        if (!inSession) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: WatchTogetherSessionIndicator(
            onCancelAutoHide: onCancelAutoHide,
            onStartAutoHide: onStartAutoHide,
          ),
        );
      },
    );

    Widget? trailingCluster;
    if (useIOSLiquidGlass && trailing != null) {
      trailingCluster = GlassSurface(
        interactive: true,
        blurNativeVideo: true,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        sigma: 26,
        opacity: 0.56,
        tint: const Color(0xFF07080C),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showClock)
                const Padding(
                  padding: EdgeInsets.only(left: 8, right: 4),
                  child: SystemClock(
                    style: TextStyle(color: Colors.white70, fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                ),
              trailing!,
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        AppBarBackButton(style: BackButtonStyle.video, onPressed: onBack ?? () => Navigator.of(context).pop(true)),
        SizedBox(width: useIOSLiquidGlass ? 12 : 16),
        Expanded(
          child: style == VideoHeaderStyle.singleLine
              ? _buildSingleLineTitle(itemTitle, shadowed: useIOSLiquidGlass)
              : _buildMultiLineTitle(itemTitle, shadowed: useIOSLiquidGlass),
        ),
        watchTogetherBadge,
        if (trailingCluster != null) ...[
          const SizedBox(width: 8),
          trailingCluster,
        ] else ...[
          if (showClock)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SystemClock(
                style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: .w500),
              ),
            ),
          ?trailing,
        ],
      ],
    );
  }

  static const _iosTitleShadows = [Shadow(color: Color(0x99000000), blurRadius: 12, offset: Offset(0, 1))];

  Widget _buildSingleLineTitle(String itemTitle, {bool shadowed = false}) {
    final seriesName = metadata.grandparentTitle ?? itemTitle;
    final hasEpisodeInfo = metadata.parentIndex != null && metadata.index != null;

    final List<String> parts = [seriesName];

    if (hasEpisodeInfo) {
      parts.add('S${metadata.parentIndex}E${metadata.index}');
      parts.add(itemTitle);
    }

    return Text(
      toBulletedString(parts),
      style: TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: .w500,
        shadows: shadowed ? _iosTitleShadows : null,
      ),
      maxLines: 1,
      overflow: .ellipsis,
    );
  }

  Widget _buildMultiLineTitle(String itemTitle, {bool shadowed = false}) {
    final List<String> secondLineParts = [];

    if (metadata.parentIndex != null && metadata.index != null) {
      secondLineParts.add('S${metadata.parentIndex}');
      secondLineParts.add('E${metadata.index}');
      secondLineParts.add(itemTitle);
    }

    if (metadata.durationMs != null) {
      secondLineParts.add(formatDurationTextual(metadata.durationMs!));
    }

    return Column(
      crossAxisAlignment: .start,
      children: [
        Text(
          metadata.grandparentTitle ?? itemTitle,
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: .bold,
            letterSpacing: -0.2,
            shadows: shadowed ? _iosTitleShadows : null,
          ),
          maxLines: 1,
          overflow: .ellipsis,
        ),
        if (secondLineParts.isNotEmpty)
          Text(
            toBulletedString(secondLineParts),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.80),
              fontSize: 13.5,
              shadows: shadowed ? _iosTitleShadows : null,
            ),
            maxLines: 1,
            overflow: .ellipsis,
          ),
      ],
    );
  }
}
