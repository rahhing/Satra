import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Reports a glass pane's physical bounds to the Linux video plane, which is
/// composited below Flutter and cannot be sampled by a BackdropFilter.
class LinuxVideoBlur extends SingleChildRenderObjectWidget {
  const LinuxVideoBlur({super.key, required this.borderRadius, required this.sigma, required super.child});

  final BorderRadius borderRadius;
  final double sigma;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLinuxVideoBlur(borderRadius, sigma, MediaQuery.devicePixelRatioOf(context));

  @override
  void updateRenderObject(BuildContext context, covariant RenderProxyBox renderObject) {
    (renderObject as _RenderLinuxVideoBlur)
      ..borderRadius = borderRadius
      ..sigma = sigma
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..markNeedsPaint();
  }
}

class _RenderLinuxVideoBlur extends RenderProxyBox {
  _RenderLinuxVideoBlur(this.borderRadius, this.sigma, this.devicePixelRatio);

  static const _channel = MethodChannel('com.satra/mpv_player');
  static int _nextId = 0;
  final int _id = _nextId++;
  BorderRadius borderRadius;
  double sigma;
  double devicePixelRatio;
  VoidCallback? _cancelCompositionCallback;
  List<double>? _lastGeometry;

  void _send(Map<String, Object> args) {
    unawaited(_updateNativeRegion(args));
  }

  Future<void> _updateNativeRegion(Map<String, Object> args) async {
    try {
      await _channel.invokeMethod<void>('setVideoBlurRegion', {'id': _id, ...args});
    } on MissingPluginException {
      // Widget previews and an older runner have no native video blur.
    } on PlatformException {
      // The player may already be shutting down as the pane detaches.
    }
  }

  void _reportGeometry(Layer layer) {
    // Flutter can detach a retained layer while rebuilding its ancestor's
    // composition. That does not mean the pane has closed.
    if (!attached || !layer.attached || !hasSize) return;
    final transform = getTransformTo(null);
    final rect = MatrixUtils.transformRect(transform, Offset.zero & size);
    final scale =
        MatrixUtils.transformPoint(transform, const Offset(1, 0)) - MatrixUtils.transformPoint(transform, Offset.zero);
    final factor = scale.distance * devicePixelRatio;
    final radii = borderRadius.toRRect(Offset.zero & size).scaleRadii();
    final geometry = [
      rect.left * devicePixelRatio,
      rect.top * devicePixelRatio,
      rect.width * devicePixelRatio,
      rect.height * devicePixelRatio,
      sigma * factor,
      radii.tlRadiusX * factor,
      radii.trRadiusX * factor,
      radii.brRadiusX * factor,
      radii.blRadiusX * factor,
    ];
    if (listEquals(_lastGeometry, geometry)) return;
    _lastGeometry = geometry;
    _send({'rect': geometry});
  }

  void _clear() {
    if (_lastGeometry == null) return;
    _lastGeometry = null;
    _send({});
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _cancelCompositionCallback?.call();
    _cancelCompositionCallback = context.addCompositionCallback(_reportGeometry);
    super.paint(context, offset);
  }

  @override
  void detach() {
    _cancelCompositionCallback?.call();
    _cancelCompositionCallback = null;
    super.detach();
    // Reparenting can detach and reattach the same pane during one frame.
    scheduleMicrotask(() {
      if (!attached) _clear();
    });
  }
}
