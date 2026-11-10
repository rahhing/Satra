import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ImageFilterConfig, ImageFilterContext, PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import '../services/settings_service.dart';
import '../theme/app_motion.dart';
import 'linux_video_blur.dart';

/// Drives a glass surface without placing its backdrop filter in an opacity layer
/// and without forcing the child widget subtree to rebuild on every animation tick.
class GlassTransitionScope extends InheritedWidget {
  const GlassTransitionScope({super.key, required this.animation, required super.child});

  final Animation<double> animation;

  static Animation<double>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassTransitionScope>()?.animation;

  @override
  bool updateShouldNotify(GlassTransitionScope oldWidget) => oldWidget.animation != animation;
}

/// Lazily loads and caches the compiled GLSL shaders for Liquid Glass.
abstract final class _LiquidGlassShaders {
  static ui.FragmentProgram? sheenProgram;
  static ui.FragmentShader? sheenShader;
  static ui.FragmentProgram? backdropProgram;
  static bool _loading = false;
  static final ValueNotifier<int> readyNotifier = ValueNotifier<int>(0);

  static void ensureLoaded() {
    if (_loading || sheenProgram != null) return;
    _loading = true;
    unawaited(_load());
  }

  static Future<void> _load() async {
    var updated = false;
    try {
      final prog = await ui.FragmentProgram.fromAsset('assets/shaders/liquid_glass_sheen.frag');
      sheenProgram = prog;
      sheenShader = prog.fragmentShader();
      updated = true;
    } catch (_) {
      // Headless unit test bindings without shader assets gracefully skip.
    }
    if (!kIsWeb && ui.ImageFilter.isShaderFilterSupported) {
      try {
        backdropProgram = await ui.FragmentProgram.fromAsset('assets/shaders/liquid_glass_backdrop.frag');
        updated = true;
      } catch (_) {}
    }
    if (updated) {
      readyNotifier.value++;
    }
  }
}

/// A translucent pane with GPU backdrop blur (or optical Liquid Glass lens
/// refraction when [SettingsService.liquidGlass] is enabled) clipped to its bounds.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.tint,
    this.sigma = 28,
    this.opacity = 0.62,
    this.border = true,
    this.enabled = true,
    this.blurNativeVideo = false,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color? tint;
  final double sigma;
  final double opacity;
  final bool border;
  final bool enabled;

  /// Native video is composited below Flutter, outside a BackdropFilter's
  /// input. macOS uses an AppKit material; Linux blurs the video plane itself.
  final bool blurNativeVideo;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    // Warm up SPIR-V shaders once in the background so opening routes or toggling
    // Liquid Glass never stalls a transition frame.
    _LiquidGlassShaders.ensureLoaded();
    final settings = SettingsService.instanceOrNull;
    if (settings == null) {
      return _buildGlass(context, liquidGlass: false);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: settings.listenable(SettingsService.liquidGlass),
      builder: (context, liquidGlass, _) => _buildGlass(context, liquidGlass: liquidGlass),
    );
  }

  Widget _buildGlass(BuildContext context, {required bool liquidGlass}) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final effects = AppMotion.effectsEnabled(context);
    final useLiquid = effects && liquidGlass;

    final animation = GlassTransitionScope.of(context);
    final rawSurface = tint ?? scheme.surface;
    final surface = isDark
        ? Color.lerp(rawSurface, const Color(0xFF050609), useLiquid ? 0.48 : 0.28)!
        : rawSurface;

    // Rich smoked dark density so bright artwork behind Spotlight, toolbars, or
    // panels never washes out the glass, while native-video sheets let blurred
    // video colors glow richly underneath.
    final double baseOpacity;
    if (blurNativeVideo && effects) {
      baseOpacity = isDark ? (useLiquid ? 0.56 : 0.48) : opacity.clamp(0.36, 0.72);
    } else if (useLiquid) {
      baseOpacity = isDark ? (opacity + (1.0 - opacity) * 0.24).clamp(0.68, 0.88) : (opacity * 0.94).clamp(0.46, 0.86);
    } else {
      baseOpacity = opacity;
    }

    if (animation == null) {
      final staticContent = RepaintBoundary(
        child: Material(type: MaterialType.transparency, child: child),
      );
      return _buildGlassFrame(
        context,
        scheme: scheme,
        isDark: isDark,
        effects: effects,
        useLiquid: useLiquid,
        surface: surface,
        baseOpacity: baseOpacity,
        visibility: 1.0,
        content: staticContent,
      );
    }

    // Cache the child subtree inside a RepaintBoundary so opening/closing a route
    // (Settings, Appearance, Downloads, Spotlight, menus) builds and rasterizes
    // its UI once into a GPU texture instead of rebuilding every animation frame.
    final cachedSubtree = RepaintBoundary(
      child: Material(type: MaterialType.transparency, child: child),
    );

    return AnimatedBuilder(
      animation: animation,
      child: cachedSubtree,
      builder: (context, cachedChild) {
        final visibility = animation.value.clamp(0.0, 1.0);
        return _buildGlassFrame(
          context,
          scheme: scheme,
          isDark: isDark,
          effects: effects,
          useLiquid: useLiquid,
          surface: surface,
          baseOpacity: baseOpacity,
          visibility: visibility,
          // Keep Opacity permanently in the element tree (RenderOpacity is a
          // no-op at alpha 255) so child State and FocusNodes never unmount
          // when an opening sheet animation reaches 1.0.
          content: Opacity(opacity: visibility, child: cachedChild),
        );
      },
    );
  }

  Widget _buildGlassFrame(
    BuildContext context, {
    required ColorScheme scheme,
    required bool isDark,
    required bool effects,
    required bool useLiquid,
    required Color surface,
    required double baseOpacity,
    required double visibility,
    required Widget content,
  }) {
    final effectiveAlpha = (effects ? baseOpacity : 1.0) * visibility;
    final baseFill = surface.withValues(alpha: effectiveAlpha);

    // Keep `color` and `gradient` on separate DecoratedBoxes because Flutter's
    // BoxDecoration replaces `paint.color` RGB when `paint.shader` is non-null.
    final Widget gradedContent = effects
        ? DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        Colors.white.withValues(alpha: 0.016 * visibility),
                        Colors.black.withValues(alpha: 0.04 * visibility),
                        Colors.black.withValues(alpha: (useLiquid ? 0.14 : 0.10) * visibility),
                      ]
                    : (useLiquid
                          ? [
                              Colors.white.withValues(alpha: 0.18 * visibility),
                              Colors.transparent,
                              Colors.white.withValues(alpha: 0.08 * visibility),
                            ]
                          : [Colors.white.withValues(alpha: 0.06 * visibility), Colors.transparent]),
              ),
            ),
            child: content,
          )
        : content;

    final pane = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        color: baseFill,
        border: border
            ? Border.all(
                width: 1.0,
                color: Colors.white.withValues(
                  alpha: ((isDark ? (useLiquid ? 0.11 : 0.085) : 0.80) * visibility).clamp(0.0, 1.0),
                ),
              )
            : null,
      ),
      child: gradedContent,
    );

    final Widget filteredContent;
    if (effects && blurNativeVideo && !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      filteredContent = Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AppKitView(
                key: ValueKey(scheme.brightness),
                viewType: 'com.satra/video_sheet_blur',
                hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                creationParams: {'dark': isDark},
                creationParamsCodec: const StandardMessageCodec(),
              ),
            ),
          ),
          if (useLiquid)
            Positioned.fill(
              child: IgnorePointer(
                child: _LiquidSheenLayer(borderRadius: borderRadius, visibility: visibility, isDark: isDark),
              ),
            ),
          pane,
        ],
      );
    } else if (useLiquid) {
      filteredContent = _LiquidGlassBackdrop(
        borderRadius: borderRadius,
        sigma: sigma,
        visibility: visibility,
        isDark: isDark,
        child: pane,
      );
    } else {
      filteredContent = BackdropFilter(
        enabled: effects,
        filter: ui.ImageFilter.blur(
          sigmaX: sigma * visibility,
          sigmaY: sigma * visibility,
          tileMode: ui.TileMode.clamp,
        ),
        child: pane,
      );
    }

    final glass = ClipRRect(borderRadius: borderRadius, child: filteredContent);
    if (effects && blurNativeVideo && !kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      return LinuxVideoBlur(borderRadius: borderRadius, sigma: sigma, child: glass);
    }
    return glass;
  }
}

class _LiquidGlassBackdrop extends StatelessWidget {
  const _LiquidGlassBackdrop({
    required this.borderRadius,
    required this.sigma,
    required this.visibility,
    required this.isDark,
    required this.child,
  });

  final BorderRadius borderRadius;
  final double sigma;
  final double visibility;
  final bool isDark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final resolvedRadius = borderRadius.resolve(textDirection);

    return ListenableBuilder(
      listenable: _LiquidGlassShaders.readyNotifier,
      builder: (context, _) {
        final backdropProgram = _LiquidGlassShaders.backdropProgram;
        if (backdropProgram != null && ui.ImageFilter.isShaderFilterSupported) {
          final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? View.maybeOf(context)?.devicePixelRatio ?? 1.0;
          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    filterConfig: _ImpellerLiquidShaderFilterConfig(
                      program: backdropProgram,
                      borderRadius: resolvedRadius,
                      devicePixelRatio: dpr,
                      sigma: sigma * 0.72 * visibility,
                      strength: visibility,
                      isDark: isDark,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: _LiquidSheenLayer(borderRadius: resolvedRadius, visibility: visibility, isDark: isDark),
                ),
              ),
              child,
            ],
          );
        }

        // Universal GPU multi-zone optical lens distortion (works natively on
        // Skia Linux/Windows and Impeller without CPU texture readbacks).
        return Stack(
          children: [
            // Zone 1: Convex dome core (subtle magnification + velvety diffusion)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipPath(
                  clipper: _MeniscusCoreClipper(borderRadius: resolvedRadius),
                  child: BackdropFilter(
                    filterConfig: _LiquidZoneFilterConfig(
                      sigma: sigma * 0.75 * visibility,
                      scale: 1.0 + 0.014 * visibility,
                      dilate: 0.0,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            // Zone 2: Curved meniscus mid-bevel ring (gentle lens curvature)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipPath(
                  clipper: _MeniscusRingClipper(borderRadius: resolvedRadius, outerLipOnly: false),
                  child: BackdropFilter(
                    filterConfig: _LiquidZoneFilterConfig(
                      sigma: math.max(3.4, sigma * 0.46) * visibility,
                      scale: 1.0 + 0.044 * visibility,
                      dilate: 0.42 * visibility,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            // Zone 3: Outer glass lip (understated Snell's-law edge bend)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipPath(
                  clipper: _MeniscusRingClipper(borderRadius: resolvedRadius, outerLipOnly: true),
                  child: BackdropFilter(
                    filterConfig: _LiquidZoneFilterConfig(
                      sigma: math.max(2.8, sigma * 0.30) * visibility,
                      scale: 1.0 + 0.088 * visibility,
                      dilate: 0.32 * visibility,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            // Layer 4: GLSL fragment shader Fresnel specular rim & chromatic dispersion
            Positioned.fill(
              child: IgnorePointer(
                child: _LiquidSheenLayer(borderRadius: resolvedRadius, visibility: visibility, isDark: isDark),
              ),
            ),
            child,
          ],
        );
      },
    );
  }
}

class _LiquidSheenLayer extends StatelessWidget {
  const _LiquidSheenLayer({required this.borderRadius, required this.visibility, required this.isDark});

  final BorderRadiusGeometry borderRadius;
  final double visibility;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final resolved = borderRadius.resolve(Directionality.maybeOf(context) ?? TextDirection.ltr);
    return ListenableBuilder(
      listenable: _LiquidGlassShaders.readyNotifier,
      builder: (context, _) {
        return CustomPaint(
          painter: _LiquidSheenPainter(
            shader: _LiquidGlassShaders.sheenShader,
            borderRadius: resolved,
            visibility: visibility,
            isDark: isDark,
          ),
        );
      },
    );
  }
}

double _meniscusBevelFor(Size size) => (math.min(size.width, size.height) * 0.32).clamp(8.0, 24.0);
double _meniscusLipFor(Size size) => (_meniscusBevelFor(size) * 0.32).clamp(3.0, 7.5);

RRect _deflateRRect(RRect rrect, double delta) {
  final outer = rrect.outerRect;
  final topDocked =
      rrect.tlRadiusX <= 0.5 && rrect.trRadiusX <= 0.5 && (rrect.blRadiusX > 0.5 || rrect.brRadiusX > 0.5);
  final bottomDocked =
      rrect.blRadiusX <= 0.5 && rrect.brRadiusX <= 0.5 && (rrect.tlRadiusX > 0.5 || rrect.trRadiusX > 0.5);
  final rect = Rect.fromLTRB(
    outer.left + delta,
    topDocked ? outer.top : outer.top + delta,
    outer.right - delta,
    bottomDocked ? outer.bottom : outer.bottom - delta,
  );
  if (rect.width <= 0 || rect.height <= 0) {
    return RRect.fromRectXY(Rect.fromCenter(center: rrect.center, width: 0, height: 0), 0, 0);
  }
  Radius shrink(Radius r) => Radius.elliptical(math.max(0.0, r.x - delta), math.max(0.0, r.y - delta));
  return RRect.fromRectAndCorners(
    rect,
    topLeft: shrink(rrect.tlRadius),
    topRight: shrink(rrect.trRadius),
    bottomRight: shrink(rrect.brRadius),
    bottomLeft: shrink(rrect.blRadius),
  );
}

class _MeniscusCoreClipper extends CustomClipper<Path> {
  const _MeniscusCoreClipper({required this.borderRadius});

  final BorderRadius borderRadius;

  @override
  Path getClip(Size size) {
    final outer = borderRadius.toRRect(Offset.zero & size);
    final inner = _deflateRRect(outer, _meniscusBevelFor(size));
    return Path()..addRRect(inner);
  }

  @override
  bool shouldReclip(covariant _MeniscusCoreClipper oldClipper) => oldClipper.borderRadius != borderRadius;
}

class _MeniscusRingClipper extends CustomClipper<Path> {
  const _MeniscusRingClipper({required this.borderRadius, required this.outerLipOnly});

  final BorderRadius borderRadius;
  final bool outerLipOnly;

  @override
  Path getClip(Size size) {
    final full = borderRadius.toRRect(Offset.zero & size);
    final lip = _meniscusLipFor(size);
    final bevel = _meniscusBevelFor(size);
    final outer = outerLipOnly ? full : _deflateRRect(full, lip);
    final inner = _deflateRRect(full, outerLipOnly ? lip : bevel);
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(outer)
      ..addRRect(inner);
  }

  @override
  bool shouldReclip(covariant _MeniscusRingClipper oldClipper) =>
      oldClipper.borderRadius != borderRadius || oldClipper.outerLipOnly != outerLipOnly;
}

class _LiquidZoneFilterConfig implements ImageFilterConfig {
  const _LiquidZoneFilterConfig({required this.sigma, required this.scale, required this.dilate});

  final double sigma;
  final double scale;
  final double dilate;

  @override
  ui.ImageFilter? get filter => null;

  @override
  String get debugShortDescription => 'liquidZone(sigma: $sigma, scale: $scale, dilate: $dilate)';

  @override
  ui.ImageFilter resolve(ImageFilterContext context) {
    final center = context.bounds.center;
    final tx = center.dx * (1.0 - scale);
    final ty = center.dy * (1.0 - scale);
    final matrix = Float64List(16)
      ..[0] = scale
      ..[5] = scale
      ..[10] = 1.0
      ..[12] = tx
      ..[13] = ty
      ..[15] = 1.0;

    ui.ImageFilter current = ui.ImageFilter.matrix(matrix, filterQuality: FilterQuality.medium);
    if (dilate > 0.05) {
      current = ui.ImageFilter.compose(
        outer: ui.ImageFilter.dilate(radiusX: dilate, radiusY: dilate),
        inner: current,
      );
    }
    if (sigma > 0.05) {
      current = ui.ImageFilter.compose(
        outer: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: ui.TileMode.clamp),
        inner: current,
      );
    }
    return current;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _LiquidZoneFilterConfig && other.sigma == sigma && other.scale == scale && other.dilate == dilate);

  @override
  int get hashCode => Object.hash(sigma, scale, dilate);
}

class _ImpellerLiquidShaderFilterConfig implements ImageFilterConfig {
  const _ImpellerLiquidShaderFilterConfig({
    required this.program,
    required this.borderRadius,
    required this.devicePixelRatio,
    required this.sigma,
    required this.strength,
    required this.isDark,
  });

  final ui.FragmentProgram program;
  final BorderRadius borderRadius;
  final double devicePixelRatio;
  final double sigma;
  final double strength;
  final bool isDark;

  @override
  ui.ImageFilter? get filter => null;

  @override
  String get debugShortDescription => 'impellerLiquid(sigma: $sigma, strength: $strength, dpr: $devicePixelRatio)';

  @override
  ui.ImageFilter resolve(ImageFilterContext context) {
    final shader = program.fragmentShader();
    // u_size (0, 1) is populated to physical texture dimensions.
    // In FlutterFragCoord (+y down), p.y > 0 is bottom and p.y <= 0 is top, so
    // sdRoundBox expects u_radii = (bottomRight, topRight, bottomLeft, topLeft).
    shader.setFloat(0, math.max(1.0, context.bounds.width * devicePixelRatio));
    shader.setFloat(1, math.max(1.0, context.bounds.height * devicePixelRatio));
    shader.setFloat(2, borderRadius.bottomRight.x * devicePixelRatio);
    shader.setFloat(3, borderRadius.topRight.x * devicePixelRatio);
    shader.setFloat(4, borderRadius.bottomLeft.x * devicePixelRatio);
    shader.setFloat(5, borderRadius.topLeft.x * devicePixelRatio);
    shader.setFloat(6, strength);
    shader.setFloat(7, isDark ? 1.0 : 0.0);

    // Run `shaderFilter` as `inner` directly on the raw backdrop snapshot
    // (where `ShouldRasterizeForRuntimeEffects()` is false), then diffuse with
    // `outer` Gaussian blur so refracted colors & meniscus bend stay aligned
    // inside TransformLayers and HiDPI viewports.
    final shaderFilter = ui.ImageFilter.shader(shader);
    if (sigma <= 0.05) return shaderFilter;
    return ui.ImageFilter.compose(
      outer: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: ui.TileMode.clamp),
      inner: shaderFilter,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _ImpellerLiquidShaderFilterConfig &&
          other.program == program &&
          other.borderRadius == borderRadius &&
          other.devicePixelRatio == devicePixelRatio &&
          other.sigma == sigma &&
          other.strength == strength &&
          other.isDark == isDark);

  @override
  int get hashCode => Object.hash(program, borderRadius, devicePixelRatio, sigma, strength, isDark);
}

class _LiquidSheenPainter extends CustomPainter {
  const _LiquidSheenPainter({
    required this.shader,
    required this.borderRadius,
    required this.visibility,
    required this.isDark,
  });

  final ui.FragmentShader? shader;
  final BorderRadius borderRadius;
  final double visibility;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || visibility <= 0.001) return;
    final rect = Offset.zero & size;
    final bevel = _meniscusBevelFor(size);

    final fragShader = shader;
    if (fragShader != null) {
      // sdRoundBox expects u_radii = (bottomRight, topRight, bottomLeft, topLeft).
      fragShader.setFloat(0, size.width);
      fragShader.setFloat(1, size.height);
      fragShader.setFloat(2, borderRadius.bottomRight.x);
      fragShader.setFloat(3, borderRadius.topRight.x);
      fragShader.setFloat(4, borderRadius.bottomLeft.x);
      fragShader.setFloat(5, borderRadius.topLeft.x);
      fragShader.setFloat(6, bevel);
      fragShader.setFloat(7, visibility);
      fragShader.setFloat(8, isDark ? 1.0 : 0.0);
      canvas.drawRect(rect, Paint()..shader = fragShader);
      return;
    }

    // Fallback specular meniscus rim before shader program finishes loading
    final topDocked = borderRadius.topLeft.x <= 0.5 &&
        borderRadius.topRight.x <= 0.5 &&
        (borderRadius.bottomLeft.x > 0.5 || borderRadius.bottomRight.x > 0.5);
    final bottomDocked = borderRadius.bottomLeft.x <= 0.5 &&
        borderRadius.bottomRight.x <= 0.5 &&
        (borderRadius.topLeft.x > 0.5 || borderRadius.topRight.x > 0.5);
    final rimRect = Rect.fromLTRB(
      rect.left + 0.75,
      topDocked ? rect.top - 4.0 : rect.top + 0.75,
      rect.right - 0.75,
      bottomDocked ? rect.bottom + 4.0 : rect.bottom - 0.75,
    );
    final rrect = borderRadius.toRRect(rimRect);
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        [
          Colors.white.withValues(alpha: 0.24 * visibility),
          Colors.cyanAccent.withValues(alpha: 0.05 * visibility),
          Colors.white.withValues(alpha: 0.16 * visibility),
        ],
        const [0.0, 0.5, 1.0],
      );
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawRRect(rrect, rimPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LiquidSheenPainter oldDelegate) =>
      oldDelegate.shader != shader ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.visibility != visibility ||
      oldDelegate.isDark != isDark;
}
