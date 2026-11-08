import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// Paint the video beneath its poster while it loads, so texture allocation,
/// seeking, and rebuffering never replace the card with a black placeholder.
class MediaPreviewSurface extends StatelessWidget {
  static const _notReady = AlwaysStoppedAnimation<bool>(false);
  const MediaPreviewSurface({super.key, required this.poster, this.preview, this.ready, this.showPreview = true});

  final Widget poster;
  final Widget? preview;
  final ValueListenable<bool>? ready;
  final bool showPreview;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ready ?? _notReady,
      child: poster,
      builder: (context, loaded, poster) => Stack(
        children: [
          Positioned.fill(child: IgnorePointer(child: preview ?? const SizedBox.shrink())),
          AnimatedOpacity(
            // Restore the poster immediately when buffering starts; only the
            // reveal of decoded video and the hover-out transition dissolve.
            duration: loaded ? AppMotion.duration(context) : Duration.zero,
            curve: AppMotion.curve,
            opacity: preview != null && loaded && showPreview ? 0 : 1,
            child: poster,
          ),
        ],
      ),
    );
  }
}
