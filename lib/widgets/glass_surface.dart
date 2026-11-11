import 'dart:async';
import 'dart:io' as io show Platform;
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

  /// Overrides native AppKit glass/blur in widget tests (`TestWidgetsFlutterBinding`
  /// defaults to [blurNativeVideo] so unmocked `RepaintBoundary.toImage()` tests
  /// continue to rasterize pure-Flutter backdrops unless native glass is under test).
  @visibleForTesting
  static bool? debugEnableMacOSNativeGlass;

  static final bool _hostMacOSSupportsLiquidGlass = () {
    if (kIsWeb || !io.Platform.isMacOS) return true;
    final match = RegExp(r'(\d+)').firstMatch(io.Platform.operatingSystemVersion);
    final major = match != null ? int.tryParse(match.group(1)!) : null;
    return major == null || major >= 26;
  }();

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

  bool _useMacOSNativeBackdrop() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return false;
    final override = debugEnableMacOSNativeGlass;
    if (override != null) return override;
    return WidgetsBinding.instance is WidgetsFlutterBinding ? true : blurNativeVideo;
  }

  static const List<Pref<Object?>> _glassPrefs = [
    SettingsService.liquidGlass,
    SettingsService.liquidGlassOpacity,
    SettingsService.glassBlurAmount,
    SettingsService.glassBackgroundBrightness,
  ];

  static List<double> _backdropBrightnessMatrix(double scale) => <double>[
    scale, 0, 0, 0, 0,
    0, scale, 0, 0, 0,
    0, 0, scale, 0, 0,
    0, 0, 0, 1, 0,
  ];

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    if (!_useMacOSNativeBackdrop() || !_hostMacOSSupportsLiquidGlass) {
      // Warm up SPIR-V shaders once in the background so opening routes or toggling
      // Liquid Glass never stalls a transition frame.
      _LiquidGlassShaders.ensureLoaded();
    }
    final settings = SettingsService.instanceOrNull;
    if (settings == null) {
      return _buildGlass(
        context,
        liquidGlass: false,
        liquidGlassOpacity: SettingsService.liquidGlassOpacity.defaultValue,
        blurAmount: SettingsService.glassBlurAmount.defaultValue,
        backgroundBrightness: SettingsService.glassBackgroundBrightness.defaultValue,
      );
    }
    return ListenableBuilder(
      listenable: settings.listenableOfAll(_glassPrefs),
      builder: (context, _) => _buildGlass(
        context,
        liquidGlass: settings.read(SettingsService.liquidGlass),
        liquidGlassOpacity: settings.read(SettingsService.liquidGlassOpacity),
        blurAmount: settings.read(SettingsService.glassBlurAmount),
        backgroundBrightness: settings.read(SettingsService.glassBackgroundBrightness),
      ),
    );
  }

  Widget _buildGlass(
    BuildContext context, {
    required bool liquidGlass,
    required double liquidGlassOpacity,
    required double blurAmount,
    required double backgroundBrightness,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final effects = AppMotion.effectsEnabled(context);
    final useLiquid = effects && liquidGlass;

    final clampedLiquidOpacity = liquidGlassOpacity.clamp(0.0, 1.0);
    final clampedBlurAmount = blurAmount.clamp(0.0, 2.0);
    final clampedBgBrightness = backgroundBrightness.clamp(0.0, 2.0);

    final surfaceWeight = blurNativeVideo ? 0.65 : (opacity / 0.84).clamp(0.68, 1.05);
    final effectiveLiquidOpacity = ui
        .lerpDouble(clampedLiquidOpacity * surfaceWeight, clampedLiquidOpacity, clampedLiquidOpacity)!
        .clamp(0.0, 1.0);

    final animation = GlassTransitionScope.of(context);
    final rawSurface = tint ?? scheme.surface;
    final surface = isDark
        ? Color.lerp(rawSurface, const Color(0xFF050609), useLiquid ? 0.48 : 0.28)!
        : rawSurface;

    final double baseOpacity;
    if (useLiquid) {
      baseOpacity = (effectiveLiquidOpacity * (isDark ? 0.92 : 0.88)).clamp(0.0, 0.94);
    } else {
      final rawBaseOpacity = (blurNativeVideo && effects)
          ? (isDark ? 0.48 : opacity.clamp(0.36, 0.72))
          : opacity;
      if (effects && clampedBgBrightness > 1.001 && isDark) {
        final brighten = (clampedBgBrightness - 1.0).clamp(0.0, 1.0);
        baseOpacity = rawBaseOpacity * (1.0 - 0.75 * brighten);
      } else {
        baseOpacity = rawBaseOpacity;
      }
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
        effectiveLiquidOpacity: effectiveLiquidOpacity,
        blurAmount: clampedBlurAmount,
        backgroundBrightness: clampedBgBrightness,
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
          effectiveLiquidOpacity: effectiveLiquidOpacity,
          blurAmount: clampedBlurAmount,
          backgroundBrightness: clampedBgBrightness,
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
    required double effectiveLiquidOpacity,
    required double blurAmount,
    required double backgroundBrightness,
    required Color surface,
    required double baseOpacity,
    required double visibility,
    required Widget content,
  }) {
    if (effects && _useMacOSNativeBackdrop()) {
      final resolvedRadius = borderRadius.resolve(Directionality.maybeOf(context) ?? TextDirection.ltr);
      final nativeLiquid = useLiquid && _hostMacOSSupportsLiquidGlass;

      final double nativeTintStrength;
      final double macOSOverlayAlpha;
      if (nativeLiquid) {
        // NSGlassEffectView(.clear) stays crystal-clear at low opacity while
        // scaling native tintColor and foreground glaze smoothly up to 100%.
        nativeTintStrength = (effectiveLiquidOpacity * (isDark ? 0.82 : 0.68)).clamp(0.0, 0.86);
        macOSOverlayAlpha = (effectiveLiquidOpacity * effectiveLiquidOpacity * (isDark ? 0.68 : 0.52) +
                effectiveLiquidOpacity * 0.04)
            .clamp(0.0, 0.72);
      } else {
        nativeTintStrength = 0.0;
        final baseMacOSAlpha = blurNativeVideo
            ? (isDark ? 0.14 : 0.10)
            : (isDark ? (opacity * 0.34).clamp(0.16, 0.32) : (opacity * 0.28).clamp(0.12, 0.26));
        if (backgroundBrightness > 1.001) {
          final brighten = (backgroundBrightness - 1.0).clamp(0.0, 1.0);
          macOSOverlayAlpha = baseMacOSAlpha * (1.0 - 0.85 * brighten);
        } else {
          macOSOverlayAlpha = baseMacOSAlpha;
        }
      }

      final gradedContent = nativeLiquid
          ? content
          : DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: resolvedRadius,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [
                          Colors.white.withValues(alpha: 0.016 * visibility),
                          Colors.black.withValues(alpha: 0.03 * visibility),
                        ]
                      : [Colors.white.withValues(alpha: 0.05 * visibility), Colors.transparent],
                ),
              ),
              child: content,
            );

      Widget macOSPane = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: resolvedRadius,
          color: surface.withValues(alpha: macOSOverlayAlpha * visibility),
          border: (border && !nativeLiquid)
              ? Border.all(
                  width: 1.0,
                  color: Colors.white.withValues(
                    alpha: ((isDark ? 0.10 : 0.65) * visibility).clamp(0.0, 1.0),
                  ),
                )
              : null,
        ),
        child: gradedContent,
      );

      if (!nativeLiquid && backgroundBrightness < 0.999) {
        final darken = (1.0 - backgroundBrightness).clamp(0.0, 1.0);
        macOSPane = DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: resolvedRadius,
            color: Colors.black.withValues(alpha: 0.62 * darken * visibility),
          ),
          child: macOSPane,
        );
      }

      // Keep AppKitView outside ClipRRect so FlutterCompositor never wraps it
      // in a FlutterPathClipView (which isolates Core Animation's backdrop
      // group). Native corner shaping happens inside MacOSGlassSurfaceView.
      return Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: _MacOSNativeGlassBackdrop(
                liquidGlass: nativeLiquid,
                isDark: isDark,
                borderRadius: resolvedRadius,
                visibility: visibility,
                tintArgb: surface.toARGB32(),
                tintStrength: nativeTintStrength,
                blurScale: nativeLiquid ? 1.0 : blurAmount,
                backgroundBrightness: nativeLiquid ? 1.0 : backgroundBrightness,
              ),
            ),
          ),
          if (useLiquid && !nativeLiquid)
            Positioned.fill(
              child: IgnorePointer(
                child: _LiquidSheenLayer(borderRadius: resolvedRadius, visibility: visibility, isDark: isDark),
              ),
            ),
          ClipRRect(borderRadius: resolvedRadius, child: macOSPane),
        ],
      );
    }

    final effectiveAlpha = (effects ? baseOpacity : 1.0) * visibility;
    final baseFill = surface.withValues(alpha: effectiveAlpha);
    final gradientScale = useLiquid
        ? (effectiveLiquidOpacity * 1.4).clamp(0.0, 1.0)
        : (backgroundBrightness > 1.001 && isDark
              ? (1.0 - 0.75 * (backgroundBrightness - 1.0).clamp(0.0, 1.0))
              : 1.0);

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
                        Colors.white.withValues(alpha: 0.016 * gradientScale * visibility),
                        Colors.black.withValues(alpha: 0.04 * gradientScale * visibility),
                        Colors.black.withValues(alpha: (useLiquid ? 0.14 : 0.10) * gradientScale * visibility),
                      ]
                    : (useLiquid
                          ? [
                              Colors.white.withValues(alpha: 0.18 * gradientScale * visibility),
                              Colors.transparent,
                              Colors.white.withValues(alpha: 0.08 * gradientScale * visibility),
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

    final effectiveSigma = sigma * blurAmount;
    final Widget filteredContent;
    if (useLiquid) {
      filteredContent = _LiquidGlassBackdrop(
        borderRadius: borderRadius,
        sigma: sigma,
        visibility: visibility,
        isDark: isDark,
        child: pane,
      );
    } else {
      final blurFilter = ui.ImageFilter.blur(
        sigmaX: effectiveSigma * visibility,
        sigmaY: effectiveSigma * visibility,
        tileMode: ui.TileMode.clamp,
      );
      final ui.ImageFilter backdropFilter;
      if (!effects || (backgroundBrightness - 1.0).abs() <= 0.001) {
        backdropFilter = blurFilter;
      } else {
        final targetScale = backgroundBrightness < 1.0
            ? backgroundBrightness
            : 1.0 + 0.65 * (backgroundBrightness - 1.0);
        final scale = 1.0 + (targetScale - 1.0) * visibility;
        backdropFilter = ui.ImageFilter.compose(
          outer: ColorFilter.matrix(_backdropBrightnessMatrix(scale)),
          inner: blurFilter,
        );
      }
      filteredContent = BackdropFilter(
        enabled: effects,
        filter: backdropFilter,
        child: pane,
      );
    }

    final glass = ClipRRect(borderRadius: borderRadius, child: filteredContent);
    if (effects && blurNativeVideo && !kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      return LinuxVideoBlur(borderRadius: borderRadius, sigma: useLiquid ? sigma : effectiveSigma, child: glass);
    }
    return glass;
  }
}

class _MacOSNativeGlassBackdrop extends StatefulWidget {
  const _MacOSNativeGlassBackdrop({
    required this.liquidGlass,
    required this.isDark,
    required this.borderRadius,
    required this.visibility,
    required this.tintArgb,
    required this.tintStrength,
    required this.blurScale,
    required this.backgroundBrightness,
  });

  final bool liquidGlass;
  final bool isDark;
  final BorderRadius borderRadius;
  final double visibility;
  final int tintArgb;
  final double tintStrength;
  final double blurScale;
  final double backgroundBrightness;

  @override
  State<_MacOSNativeGlassBackdrop> createState() => _MacOSNativeGlassBackdropState();
}

class _MacOSNativeGlassBackdropState extends State<_MacOSNativeGlassBackdrop> {
  static const _channel = MethodChannel('com.satra/macos_glass_surface');

  int? _viewId;
  late final Map<String, Object> _creationParams = _buildParams();
  late Map<String, Object> _lastSentParams = _creationParams;

  Map<String, Object> _buildParams() => <String, Object>{
    'liquidGlass': widget.liquidGlass,
    'dark': widget.isDark,
    'tl': widget.borderRadius.topLeft.x,
    'tr': widget.borderRadius.topRight.x,
    'bl': widget.borderRadius.bottomLeft.x,
    'br': widget.borderRadius.bottomRight.x,
    'visibility': widget.visibility,
    'tintArgb': widget.tintArgb,
    'tintStrength': widget.tintStrength,
    'blurScale': widget.blurScale,
    'backgroundBrightness': widget.backgroundBrightness,
  };

  static bool _paramsEqual(Map<String, Object> a, Map<String, Object> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _handlePlatformViewCreated(int id) {
    _viewId = id;
    final current = _buildParams();
    if (!_paramsEqual(current, _lastSentParams)) {
      _lastSentParams = current;
      _sendUpdate(id, current);
    }
  }

  void _sendUpdate(int id, Map<String, Object> params) {
    _channel.invokeMethod<void>('update', <String, Object>{'viewId': id, ...params}).ignore();
  }

  @override
  void didUpdateWidget(covariant _MacOSNativeGlassBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    final id = _viewId;
    if (id == null) return;
    final next = _buildParams();
    if (_paramsEqual(next, _lastSentParams)) return;
    _lastSentParams = next;
    _sendUpdate(id, next);
  }

  @override
  Widget build(BuildContext context) {
    return AppKitView(
      viewType: 'com.satra/macos_glass_surface',
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      creationParams: _creationParams,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _handlePlatformViewCreated,
    );
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
