import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Composes the backdrop once, after the outgoing/incoming pixels are blended.
/// The sharp corner and blurred fill share that same animation and image data.
class SpotlightArtwork extends StatelessWidget {
  const SpotlightArtwork({super.key, required this.artwork, required this.size, this.corner = true});

  final Widget artwork;
  final Size size;
  final bool corner;

  @override
  Widget build(BuildContext context) {
    if (!corner) return artwork;
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          key: const ValueKey('spotlight_blurred_fill'),
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 70, sigmaY: 70, tileMode: ui.TileMode.clamp),
            child: Transform.scale(scale: 1.08, child: artwork),
          ),
        ),
        Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: size.width * 0.68,
            height: size.height * 0.72,
            child: ShaderMask(
              shaderCallback: (rect) =>
                  const LinearGradient(colors: [Colors.transparent, Colors.white], stops: [0, 0.35]).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: ShaderMask(
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white, Colors.white, Colors.transparent],
                  stops: [0, 0.55, 1],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: artwork,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
