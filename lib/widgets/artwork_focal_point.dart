import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../services/image_cache_service.dart';

/// Keeps a small, shared cache of crop hints from already-decoded artwork.
class ArtworkFocalPoint {
  static const _cacheLimit = 64;
  static final _cache = <Object, Future<Offset>>{};
  static int _cacheRevision = -1;

  static void clearCache() {
    _cache.clear();
    _cacheRevision = artworkCacheRevision.value;
  }

  static Future<Offset> resolve(Object key, ui.Image image) {
    final revision = artworkCacheRevision.value;
    if (_cacheRevision != revision) {
      _cache.clear();
      _cacheRevision = revision;
    }
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    return _cache[key] = _sample(image);
  }

  static Future<Offset> _sample(ui.Image source) async {
    final scale = math.min(1.0, 64 / math.max(source.width, source.height));
    final width = math.max(1, (source.width * scale).round());
    final height = math.max(1, (source.height * scale).round());
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    final picture = recorder.endRecording();
    ui.Image? preview;
    try {
      preview = await picture.toImage(width, height);
      final rgba = await preview.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return const Offset(.5, .5);
      return estimate(rgba, width, height);
    } catch (_) {
      return const Offset(.5, .5);
    } finally {
      preview?.dispose();
      picture.dispose();
    }
  }

  /// Finds the most detailed region at thumbnail scale. Colour is a small
  /// tie-breaker, so a flat saturated background scores below a subject.
  static Offset estimate(ByteData rgba, int width, int height) {
    final columns = List<double>.filled(width, 0);
    final rows = List<double>.filled(height, 0);

    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final index = (y * width + x) * 4;
        if (rgba.getUint8(index + 3) < 128) continue;
        var detail = 0;
        var low = 255;
        var high = 0;
        for (var channel = 0; channel < 3; channel++) {
          final i = index + channel;
          final value = rgba.getUint8(i);
          low = math.min(low, value);
          high = math.max(high, value);
          detail += (rgba.getUint8(i - 4) - rgba.getUint8(i + 4)).abs();
          detail += (rgba.getUint8(i - width * 4) - rgba.getUint8(i + width * 4)).abs();
        }
        final score = math.min(detail, 280) * (1 + (high - low) / 1020);
        columns[x] += score;
        rows[y] += score;
      }
    }

    return Offset(_strongestRegion(columns), _strongestRegion(rows));
  }

  static double _strongestRegion(List<double> scores) {
    final span = math.max(3, (scores.length * .4).round());
    if (span >= scores.length) return .5;

    final center = (scores.length - span) ~/ 2;
    var best = center;
    var bestScore = 0.0;
    for (var i = center; i < center + span; i++) {
      bestScore += scores[i];
    }
    // Keep the intended centre unless an off-centre region wins clearly.
    bestScore *= 1.12;
    var score = 0.0;
    for (var i = 0; i < span; i++) {
      score += scores[i];
    }
    for (var start = 0; start + span <= scores.length; start++) {
      if (score > bestScore) {
        best = start;
        bestScore = score;
      }
      final next = start + span;
      if (next < scores.length) score += scores[next] - scores[start];
    }
    if (best == center) return .5;

    var total = 0.0;
    var weighted = 0.0;
    for (var i = best; i < best + span; i++) {
      total += scores[i];
      weighted += (i + .5) * scores[i];
    }
    return total > 0 ? weighted / total / scores.length : .5;
  }

  /// Positions the cover crop around [point], clamped to the original image.
  static Alignment alignment(Offset point, Size source, Size output, BoxFit fit) {
    if (source.isEmpty || output.isEmpty || !output.isFinite) return Alignment.center;
    final visible = applyBoxFit(fit, source, output).source;
    double axis(double focus, double full, double crop) {
      final excess = full - crop;
      if (excess <= .01) return 0;
      final start = (focus * full - crop / 2).clamp(0.0, excess);
      return 2 * start / excess - 1;
    }

    return Alignment(axis(point.dx, source.width, visible.width), axis(point.dy, source.height, visible.height));
  }
}
