import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Bakes the static readability scrims into one small texture. Backdrop fades
/// and scrolling then blend a single quad instead of five full-screen shaders.
class SpotlightShading extends StatefulWidget {
  const SpotlightShading({super.key, required this.size, required this.shelfStart, required this.dockBand});

  final Size size;
  final double shelfStart;
  final double dockBand;

  @override
  State<SpotlightShading> createState() => _SpotlightShadingState();
}

class _SpotlightShadingState extends State<SpotlightShading> {
  ui.Image? _texture;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _bake();
  }

  @override
  void didUpdateWidget(SpotlightShading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.size != widget.size ||
        oldWidget.shelfStart != widget.shelfStart ||
        oldWidget.dockBand != widget.dockBand) {
      _bake();
    }
  }

  Future<void> _bake() async {
    if (widget.size.isEmpty) return;
    final generation = ++_generation;
    const width = 512;
    final height = math.min(1024, math.max(1, (width * widget.size.height / widget.size.width).round()));
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    _ShadingPainter.paintScrims(
      canvas,
      Size(width.toDouble(), height.toDouble()),
      widget.size.height,
      widget.shelfStart,
      widget.dockBand,
    );
    final picture = recorder.endRecording();
    ui.Image image;
    try {
      image = await picture.toImage(width, height);
    } catch (_) {
      return; // Retain the shader fallback if GPU allocation/readback fails.
    } finally {
      picture.dispose();
    }
    if (!mounted || generation != _generation) {
      image.dispose();
      return;
    }
    final previous = _texture;
    setState(() => _texture = image);
    if (previous != null) WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  @override
  void dispose() {
    _generation++;
    _texture?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _ShadingPainter(
        texture: _texture,
        screenHeight: widget.size.height,
        shelfStart: widget.shelfStart,
        dockBand: widget.dockBand,
      ),
    ),
  );
}

class _ShadingPainter extends CustomPainter {
  const _ShadingPainter({
    required this.texture,
    required this.screenHeight,
    required this.shelfStart,
    required this.dockBand,
  });
  final ui.Image? texture;
  final double screenHeight;
  final double shelfStart;
  final double dockBand;

  static void paintScrims(Canvas canvas, Size size, double screenHeight, double shelfStart, double dockBand) {
    final rect = Offset.zero & size;
    void gradient(Gradient gradient) => canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
    gradient(
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.black.withValues(alpha: .66), Colors.black.withValues(alpha: .52), Colors.transparent],
        stops: [0, (80 / screenHeight).clamp(.04, .14), (240 / screenHeight).clamp(.20, .40)],
      ),
    );
    gradient(
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.transparent,
          Colors.black.withValues(alpha: .48),
          Colors.black.withValues(alpha: .62),
          Colors.black.withValues(alpha: .72),
        ],
        stops: const [0, .30, .50, .72, 1],
      ),
    );
    gradient(
      RadialGradient(
        center: const Alignment(-.85, .12),
        radius: 1.05,
        colors: [Colors.black.withValues(alpha: .58), Colors.transparent],
      ),
    );
    gradient(
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.transparent,
          Colors.black.withValues(alpha: .48),
          Colors.black.withValues(alpha: .68),
        ],
        stops: [0, shelfStart, (shelfStart + .10).clamp(0, .95), 1],
      ),
    );
    gradient(
      LinearGradient(
        colors: [Colors.black.withValues(alpha: .55), Colors.black.withValues(alpha: .40), Colors.transparent],
        stops: [0, dockBand * .6, dockBand],
      ),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final image = texture;
    if (image == null) {
      paintScrims(canvas, size, screenHeight, shelfStart, dockBand);
    } else {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
  }

  @override
  bool shouldRepaint(_ShadingPainter oldDelegate) =>
      texture != oldDelegate.texture ||
      screenHeight != oldDelegate.screenHeight ||
      shelfStart != oldDelegate.shelfStart ||
      dockBand != oldDelegate.dockBand;
}
