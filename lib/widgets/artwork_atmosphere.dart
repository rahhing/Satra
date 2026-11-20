import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_server_client.dart';
import '../services/settings_service.dart';
import '../theme/app_motion.dart';
import '../utils/desktop_ui_scale.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import 'cycling_media_backdrop.dart';
import 'settings_builder.dart';

/// Selection is debounced so quickly crossing a shelf does not fetch a backdrop
/// for every poster. Only this shared background listens, never the card grid.
class ArtworkAtmosphereController extends ValueNotifier<MediaItem?> {
  ArtworkAtmosphereController() : super(null);

  Timer? _settle;
  String? _pendingKey;

  void select(MediaItem? item) {
    if (_pendingKey == item?.globalKey) return;
    _settle?.cancel();
    _pendingKey = item?.globalKey;
    _settle = Timer(const Duration(milliseconds: 160), () => value = item);
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }
}

class ArtworkAtmosphereScope extends InheritedWidget {
  const ArtworkAtmosphereScope({super.key, required this.controller, required this.enabled, required super.child});

  final ArtworkAtmosphereController controller;
  final bool enabled;

  static bool supportsDesktopArtwork(BuildContext context) =>
      !PlatformDetector.isTVDevice() && DesktopUiScale.isDesktopPlatform(Theme.of(context).platform);

  static ArtworkAtmosphereController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ArtworkAtmosphereScope>()?.controller;

  static bool isEnabled(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArtworkAtmosphereScope>()?.enabled ?? false;

  static Color backgroundColorOf(BuildContext context) =>
      isEnabled(context) ? Colors.transparent : Theme.of(context).scaffoldBackgroundColor;

  static void select(BuildContext context, Object item, {bool onlyIfEmpty = false}) {
    if (item is! MediaItem) return;
    final scope = context.getInheritedWidgetOfExactType<ArtworkAtmosphereScope>();
    if (scope == null || !scope.enabled) return;
    if (onlyIfEmpty && scope.controller._pendingKey != null) return;
    final hide = SettingsService.instance.read(SettingsService.hideSpoilers) && item.shouldHideSpoiler;
    scope.controller.select(hide ? null : item);
  }

  @override
  bool updateShouldNotify(ArtworkAtmosphereScope oldWidget) => enabled != oldWidget.enabled;
}

/// A canvas with a soft wash from the selected title's artwork.
/// Foreground pages remain independent; glass chrome samples this same canvas.
class ArtworkAtmosphereHost extends StatefulWidget {
  const ArtworkAtmosphereHost({super.key, required this.child, this.allowNetwork = true});

  final Widget child;
  final bool allowNetwork;

  @override
  State<ArtworkAtmosphereHost> createState() => _ArtworkAtmosphereHostState();
}

class _ArtworkAtmosphereHostState extends State<ArtworkAtmosphereHost> {
  final _controller = ArtworkAtmosphereController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingValueBuilder<bool>(
    pref: SettingsService.useClassicMobileBackdrop,
    child: widget.child,
    builder: (context, classic, child) {
      final enabled = !classic && AppMotion.effectsEnabled(context);
      return ArtworkAtmosphereScope(
        controller: _controller,
        enabled: enabled,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (enabled)
              Positioned.fill(
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: RepaintBoundary(
                      child: ValueListenableBuilder<MediaItem?>(
                        valueListenable: _controller,
                        builder: (context, item, _) => SettingsBuilder(
                          prefs: const [
                            SettingsService.hideSpoilers,
                            SettingsService.darkenMobileBackdrop,
                            SettingsService.mobileBackdropDarkness,
                          ],
                          builder: (context) => ArtworkAtmosphere(
                            item: item,
                            allowNetwork: widget.allowNetwork,
                            darkness: desktopArtworkDarkness(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            child!,
          ],
        ),
      );
    },
  );
}

double desktopArtworkDarkness() {
  final settings = SettingsService.instance;
  return settings.read(SettingsService.darkenMobileBackdrop)
      ? settings.read(SettingsService.mobileBackdropDarkness).clamp(0.0, 1.0)
      : 0.0;
}

class ArtworkAtmosphere extends StatelessWidget {
  const ArtworkAtmosphere({
    super.key,
    required this.item,
    this.client,
    this.allowNetwork = true,
    this.localArtworkPathResolver,
    this.darkness,
  });

  final MediaItem? item;
  final MediaServerClient? client;
  final bool allowNetwork;
  final String? Function(String artworkPath)? localArtworkPathResolver;
  final double? darkness;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = item;
    final effects = AppMotion.effectsEnabled(context);
    final hideSpoilers = SettingsService.instanceOrNull?.read(SettingsService.hideSpoilers) ?? false;
    if (media == null || MediaQuery.highContrastOf(context) || (hideSpoilers && media.shouldHideSpoiler)) {
      return ColoredBox(color: theme.scaffoldBackgroundColor);
    }
    final size = MediaQuery.sizeOf(context);
    final paths = [
      ...media.heroArtCandidates(containerAspectRatio: size.aspectRatio),
      if (darkness != null && (media.thumbPath?.isNotEmpty ?? false)) media.thumbPath!,
    ];
    if (paths.isEmpty) return ColoredBox(color: theme.scaffoldBackgroundColor);
    final mediaClient =
        client ?? (allowNetwork ? context.tryGetMediaClientForServer(serverIdOrNull(media.serverId)) : null);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: AnimatedSwitcher(
        duration: AppMotion.duration(context, const Duration(milliseconds: 650)),
        child: SizedBox.expand(
          key: const ValueKey('artwork-atmosphere'),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                enabled: effects,
                imageFilter: ImageFilter.blur(sigmaX: 42, sigmaY: 42, tileMode: TileMode.clamp),
                child: CyclingMediaBackdrop(
                  mediaKey: media.globalKey,
                  imagePaths: darkness == null ? paths.take(1).toList() : paths,
                  client: mediaClient,
                  allowNetwork: allowNetwork,
                  localArtworkPathResolver: localArtworkPathResolver,
                  width: 640,
                  height: 400,
                  fallbackColor: theme.scaffoldBackgroundColor,
                  active: false,
                  fadeDuration: AppMotion.duration(context, const Duration(milliseconds: 650)),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: darkness == null
                        ? [
                            theme.scaffoldBackgroundColor.withValues(alpha: effects ? 0.58 : 0.78),
                            theme.scaffoldBackgroundColor.withValues(alpha: 0.82),
                            theme.scaffoldBackgroundColor,
                          ]
                        : [
                            for (final base in const [0.40, 0.58, 0.75])
                              theme.scaffoldBackgroundColor.withValues(alpha: base + (1 - base) * darkness!),
                          ],
                    stops: const [0, 0.65, 1],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
