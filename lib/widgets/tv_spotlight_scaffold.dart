import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../media/catalog_item_ref.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../models/catalog/catalog_item.dart';
import '../navigation/main_screen_scope.dart';
import '../services/settings_service.dart';
import '../utils/debouncer.dart';
import '../utils/layout_constants.dart';
import '../utils/formatters.dart';
import 'tv_browse_rail.dart';
import 'settings_builder.dart';
import 'tv_spotlight_background.dart';
import 'backdrop_page_controls.dart';
import 'cycling_media_backdrop.dart';

class TvSpotlightController extends ValueNotifier<MediaItem?> {
  TvSpotlightController({Duration settleDelay = const Duration(milliseconds: 150)})
    : _settleDelay = settleDelay,
      _debouncer = Debouncer(settleDelay),
      super(null);

  final Duration _settleDelay;
  final Debouncer _debouncer;

  void select(MediaItem item) {
    void apply() {
      if (value?.globalKey == item.globalKey) return;
      value = item;
    }

    if (_settleDelay == Duration.zero) {
      apply();
    } else {
      _debouncer.run(apply);
    }
  }

  void restore(MediaItem? item) {
    _debouncer.cancel();
    value = item;
  }

  MediaItem? resolve(Iterable<MediaHub> hubs) {
    MediaItem? fallback;
    final current = value;
    for (final hub in hubs) {
      if (hub.items.isEmpty) continue;
      fallback ??= hub.items.first;
      if (current == null) continue;
      for (final item in hub.items) {
        if (item.globalKey == current.globalKey) return item;
      }
    }
    return fallback;
  }

  @override
  void dispose() {
    _debouncer.dispose();
    super.dispose();
  }
}

typedef TvSpotlightClientResolver = MediaServerClient? Function(MediaItem? item);

/// Shared full-screen TV backdrop and foreground stack used by hub rails.
class TvSpotlightScaffold extends StatelessWidget {
  const TvSpotlightScaffold({
    super.key,
    required this.hubs,
    required this.spotlightListenable,
    required this.resolveSpotlight,
    required this.resolveClient,
    required this.foreground,
    this.hideSpoilers,
  });

  final List<MediaHub> hubs;
  final ValueListenable<MediaItem?> spotlightListenable;
  final MediaItem? Function() resolveSpotlight;
  final TvSpotlightClientResolver resolveClient;
  final Widget foreground;
  final bool? hideSpoilers;

  @override
  Widget build(BuildContext context) => SettingsBuilder(
    prefs: const [
      SettingsService.libraryDensity,
      SettingsService.episodePosterMode,
      SettingsService.tvFullCardLayout,
      SettingsService.gridSpacing,
      SettingsService.hideSpoilers,
    ],
    builder: _buildContent,
  );

  Widget _buildContent(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final settings = SettingsService.instance;
    final scale = TvLayoutConstants.scaleForSize(size);
    final railSize = MainScreenFocusScope.foregroundSizeOf(context);
    final fullBleedWidth = MainScreenFocusScope.fullBleedWidthOf(context);
    final railHeight = hubs.isEmpty
        ? 0.0
        : TvBrowseRailLayout.estimateHeight(
            size: railSize,
            hubs: hubs,
            density: settings.read(SettingsService.libraryDensity),
            episodePosterMode: settings.read(SettingsService.episodePosterMode),
            fullCardLayout: settings.read(SettingsService.tvFullCardLayout),
            gridSpacing: settings.read(SettingsService.gridSpacing),
            tallPosterScale: TvBrowseRailLayout.compactTallPosterScale,
            widePosterScale: TvBrowseRailLayout.compactEpisodeThumbnailScale,
          );
    final spotlightTop = (size.height * 0.075).clamp(64.0 * scale, 120.0 * scale).toDouble();
    final minimumSpotlightBottom = railHeight + (8 * scale);
    final baseSpotlightBottom = (size.height * 0.48).clamp(160.0, 820.0).toDouble();
    final desiredSpotlightBottom = minimumSpotlightBottom > baseSpotlightBottom
        ? minimumSpotlightBottom
        : baseSpotlightBottom;
    final maxSpotlightBottom = (size.height - spotlightTop - (96 * scale)).clamp(0.0, double.infinity).toDouble();
    final spotlightBottom = desiredSpotlightBottom > maxSpotlightBottom ? maxSpotlightBottom : desiredSpotlightBottom;
    final spotlightLeft = (24 * scale).clamp(18.0, 40.0).toDouble();

    return BackdropPageControls(
      controlsBottom: spotlightBottom + 16,
      builder: (context, rotation) => Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Builder(
                builder: (context) {
                  final foregroundLeft = MainScreenFocusScope.foregroundLeftOf(context);
                  return SideNavigationBleedBuilder(
                    targetBleed: foregroundLeft,
                    child: GestureDetector(
                      supportedDevices: const {PointerDeviceKind.trackpad},
                      onVerticalDragStart: (details) =>
                          _findDescendantBrowseRail(context)?.startTrackpadScroll(details),
                      onVerticalDragUpdate: (details) =>
                          _findDescendantBrowseRail(context)?.updateTrackpadScroll(details),
                      onVerticalDragEnd: (details) => _findDescendantBrowseRail(context)?.endTrackpadScroll(details),
                      onVerticalDragCancel: () => _findDescendantBrowseRail(context)?.cancelTrackpadScroll(),
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerSignal: (signal) {
                          if (signal is PointerScrollEvent && signal.scrollDelta.dy != 0) {
                            GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
                              if (event is PointerScrollEvent) {
                                _findDescendantBrowseRail(context)?.stepHubByScroll(event.scrollDelta.dy);
                              }
                            });
                          }
                        },
                        child: RepaintBoundary(
                          child: ValueListenableBuilder<MediaItem?>(
                            valueListenable: spotlightListenable,
                            builder: (context, _, _) {
                              final spotlight = resolveSpotlight();
                              return _CatalogSpotlightBackground(
                                item: spotlight,
                                backdropController: rotation,
                                client: resolveClient(spotlight),
                                hideSpoilers: hideSpoilers ?? settings.read(SettingsService.hideSpoilers),
                                contentTop: spotlightTop,
                                contentBottom: spotlightBottom,
                                contentLeft: spotlightLeft + foregroundLeft,
                                targetWidthPx: (size.width * MediaQuery.devicePixelRatioOf(context)).ceil(),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    builder: (context, animatedBleed, child) =>
                        Positioned(top: 0, bottom: 0, left: -animatedBleed, width: fullBleedWidth, child: child!),
                  );
                },
              ),
              foreground,
            ],
          ),
        ),
      ),
    );
  }

  static TvBrowseRailState? _findDescendantBrowseRail(BuildContext context) {
    TvBrowseRailState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is TvBrowseRailState) {
        found = element.state as TvBrowseRailState;
        return;
      }
      element.visitChildren(visit);
    }

    context.visitAncestorElements((ancestor) {
      if (ancestor.widget is Stack) {
        ancestor.visitChildElements(visit);
        return false;
      }
      return true;
    });
    return found;
  }
}

class _CatalogSpotlightBackground extends StatefulWidget {
  const _CatalogSpotlightBackground({
    required this.item,
    required this.client,
    required this.hideSpoilers,
    required this.contentTop,
    required this.contentBottom,
    required this.contentLeft,
    required this.targetWidthPx,
    this.backdropController,
  });

  final MediaItem? item;
  final MediaServerClient? client;
  final bool hideSpoilers;
  final double contentTop;
  final double contentBottom;
  final double contentLeft;
  final int targetWidthPx;
  final BackdropRotationController? backdropController;

  @override
  State<_CatalogSpotlightBackground> createState() => _CatalogSpotlightBackgroundState();
}

class _CatalogSpotlightBackgroundState extends State<_CatalogSpotlightBackground> {
  CatalogItem? _catalogItem;
  MediaItem? _renderItem;
  Color? _accentColor;

  @override
  void initState() {
    super.initState();
    _rehydrateCatalogItem();
  }

  @override
  void didUpdateWidget(_CatalogSpotlightBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.item, oldWidget.item)) {
      _rehydrateCatalogItem();
    } else if (widget.targetWidthPx != oldWidget.targetWidthPx) {
      _projectArtwork();
    }
  }

  void _rehydrateCatalogItem() {
    _catalogItem = widget.item?.catalogItem;
    _projectArtwork();
  }

  void _projectArtwork() {
    final item = widget.item;
    final catalogItem = _catalogItem;
    if (item == null || catalogItem == null) {
      _renderItem = item;
      _accentColor = null;
      return;
    }

    final bannerUrl = catalogItem.bannerUrl;
    final sizedBackdrop = catalogItem.backdropFor(widget.targetWidthPx);
    // Plex banners are often short title strips, not scenic background art.
    // Prefer the full-size backdrop and its width variants for Explore.
    final backdrop = catalogItem.source == CatalogSourceId.plex
        ? sizedBackdrop ?? bannerUrl
        : (bannerUrl != null && bannerUrl.isNotEmpty ? bannerUrl : sizedBackdrop);
    final logoUrl = catalogItem.logoUrl;
    _renderItem = item.copyWith(
      artPath: backdrop ?? item.artPath,
      backdropPaths: backdrop == null ? item.backdropPaths : [backdrop],
      clearLogoPath: logoUrl != null && logoUrl.isNotEmpty ? logoUrl : null,
    );
    _accentColor = _parseAccentColor(catalogItem.accentColor);
  }

  Color? _parseAccentColor(String? value) {
    final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(value ?? '');
    final hex = match?.group(1);
    if (hex == null) return null;
    return Color(0xff000000 | int.parse(hex, radix: 16));
  }

  Widget? _buildNextEpisodeMetadata(BuildContext context) {
    final nextEpisode = _catalogItem?.nextEpisode;
    if (nextEpisode == null) return null;
    final duration = formatDurationTextual(nextEpisode.timeUntil(DateTime.now()).inMilliseconds);
    final episode = nextEpisode.episode;
    final label = episode == null
        ? t.explore.badge.nextAiringIn(duration: duration)
        : t.explore.badge.nextEpisodeIn(episode: episode, duration: duration);
    final scale = TvLayoutConstants.scaleOf(context);
    return Text(
      label,
      maxLines: 1,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontSize: 16 * scale,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = _accentColor;
    final background = TvSpotlightBackground(
      backdropController: widget.backdropController,
      item: _renderItem,
      client: widget.client,
      hideSpoilers: widget.hideSpoilers,
      contentTop: widget.contentTop,
      contentBottom: widget.contentBottom,
      contentLeft: widget.contentLeft,
      compact: true,
      metadataTrailing: _buildNextEpisodeMetadata(context),
    );
    if (accentColor == null) return background;
    return Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: Color.alphaBlend(accentColor.withValues(alpha: 0.18), theme.scaffoldBackgroundColor),
      ),
      child: background,
    );
  }
}

/// Keeps toolbar controls inside the foreground's hit-test bounds. Artwork
/// may bleed behind the dock, but interactive children must not paint outside
/// their page: Flutter cannot hit-test that overflow.
class TvToolbarOverlay extends StatelessWidget {
  const TvToolbarOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned(top: 0, left: 0, right: 0, child: ExcludeFocusTraversal(child: child));
  }
}
