import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/input_mode_tracker.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../media/media_person.dart';
import '../media/search_hit.dart';
import '../providers/download_provider.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/libraries_provider.dart';
import '../providers/multi_server_provider.dart';
import '../theme/app_motion.dart';
import '../theme/mono_tokens.dart';
import '../utils/desktop_window_padding.dart';
import '../utils/media_image_helper.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/media_server_http_client.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../widgets/app_icon.dart';
import '../widgets/glass_surface.dart';
import '../widgets/optimized_media_image.dart';
import 'spotlight_models.dart';
import 'spotlight_settings_index.dart';

const spotlightRouteName = '/spotlight';

/// Builds the floating glassmorphic Universal Spotlight route (`Ctrl + Space`).
Route<void> buildSpotlightRoute({
  required BuildContext hostContext,
  required NavigatorState hostNavigator,
  SpotlightShellCallbacks callbacks = const SpotlightShellCallbacks(),
  String? initialQuery,
}) {
  final isMobileHost = PlatformDetector.isMobile(hostContext);
  return PageRouteBuilder<void>(
    settings: const RouteSettings(name: spotlightRouteName),
    opaque: false,
    barrierDismissible: true,
    barrierLabel: t.common.close,
    barrierColor: Colors.black.withValues(alpha: isMobileHost ? 0.68 : 0.38),
    transitionDuration: AppMotion.systemDuration(const Duration(milliseconds: 200)),
    reverseTransitionDuration: AppMotion.systemDuration(const Duration(milliseconds: 150)),
    pageBuilder: (routeContext, animation, secondaryAnimation) {
      final keyboardBottom = MediaQuery.viewInsetsOf(routeContext).bottom;
      final isCompact = MediaQuery.sizeOf(routeContext).width < 600;
      return AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: keyboardBottom),
        child: SafeArea(
          child: Align(
            alignment: (isCompact || keyboardBottom > 0) ? Alignment.topCenter : const Alignment(0, -0.38),
            child: Padding(
              padding: isCompact
                  ? const EdgeInsets.fromLTRB(14, 8, 14, 14)
                  : const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: SideNavigationScope(
                child: UniversalSpotlightBubble(
                  hostContext: hostContext,
                  hostNavigator: hostNavigator,
                  callbacks: callbacks,
                  initialQuery: initialQuery,
                  onDismiss: () {
                    if (routeContext.mounted) {
                      Navigator.of(routeContext).pop();
                    }
                  },
                  onActivateDismiss: () {
                    if (!routeContext.mounted) return;
                    final route = ModalRoute.of(routeContext);
                    final nav = Navigator.of(routeContext);
                    if (route != null && route.isActive) {
                      nav.removeRoute(route);
                    } else {
                      nav.pop();
                    }
                  },
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionsBuilder: (context, animation, _, child) {
      if (AppMotion.duration(context) == Duration.zero) return child;
      final curved = CurvedAnimation(parent: animation, curve: AppMotion.curve, reverseCurve: Curves.easeInCubic);
      return GlassTransitionScope(
        animation: curved,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -0.02), end: Offset.zero).animate(curved),
          child: ScaleTransition(scale: Tween(begin: 0.965, end: 1.0).animate(curved), child: child),
        ),
      );
    },
  );
}

sealed class _SpotlightListRow {
  const _SpotlightListRow();
}

final class _SpotlightHeaderRow extends _SpotlightListRow {
  const _SpotlightHeaderRow(this.title, {required this.isFirst});
  final String title;
  final bool isFirst;
}

final class _SpotlightEntryRow extends _SpotlightListRow {
  const _SpotlightEntryRow({required this.entry, required this.selectableIndex, required this.sectioned});
  final SpotlightEntry entry;
  final int selectableIndex;
  final bool sectioned;
}

typedef _SpotlightDisplayData = ({
  List<_SpotlightListRow> rows,
  List<SpotlightEntry> selectable,
  List<SpotlightCategory> categories,
});

/// Precomputed exact vertical extents and scroll bounds for every row so both
/// `ListView.builder` virtualization and off-screen keyboard navigation run in O(1).
final class _SpotlightLayoutMetrics {
  _SpotlightLayoutMetrics({
    required this.rowExtents,
    required this.selectableTop,
    required this.selectableBottom,
    required this.totalContentHeight,
  });

  static const double listTopPadding = 8.0;
  static const double listBottomPadding = 10.0;

  final Float64List rowExtents;
  final Float64List selectableTop;
  final Float64List selectableBottom;
  final double totalContentHeight;

  factory _SpotlightLayoutMetrics.compute(List<_SpotlightListRow> rows, int selectableCount, double textScale) {
    final clampedScale = textScale.clamp(1.0, 1.45);
    final extents = Float64List(rows.length);
    final selTop = Float64List(selectableCount);
    final selBottom = Float64List(selectableCount);

    var cursor = listTopPadding;
    double? pendingHeaderTop;

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final double ext;
      switch (row) {
        case _SpotlightHeaderRow(:final isFirst):
          ext = (isFirst ? 30.0 : 40.0) * clampedScale;
          pendingHeaderTop ??= cursor;
        case _SpotlightEntryRow(:final entry, :final selectableIndex):
          final isTallPoster = _usesTallPoster(entry);
          ext = (isTallPoster ? 76.0 : 62.0) * clampedScale;
          final rowTop = cursor;
          final rowBottom = cursor + ext;
          if (selectableIndex == 0) {
            selTop[selectableIndex] = 0.0;
          } else if (pendingHeaderTop != null) {
            selTop[selectableIndex] = pendingHeaderTop;
          } else {
            selTop[selectableIndex] = math.max(0.0, rowTop - 6.0);
          }
          selBottom[selectableIndex] = rowBottom + listBottomPadding;
          pendingHeaderTop = null;
      }
      extents[i] = ext;
      cursor += ext;
    }

    final totalHeight = cursor + listBottomPadding;
    if (selectableCount > 0) {
      selBottom[selectableCount - 1] = totalHeight;
    }

    return _SpotlightLayoutMetrics(
      rowExtents: extents,
      selectableTop: selTop,
      selectableBottom: selBottom,
      totalContentHeight: totalHeight,
    );
  }

  static bool _usesTallPoster(SpotlightEntry entry) {
    final item = entry.mediaItem;
    if (item == null) return false;
    final kind = item.kind;
    return kind != MediaKind.episode &&
        kind != MediaKind.artist &&
        kind != MediaKind.album &&
        kind != MediaKind.track;
  }
}

/// Floating glassmorphic Spotlight bubble for searching settings, shows, movies,
/// episodes, music, libraries, people, and quick actions.
class UniversalSpotlightBubble extends StatefulWidget {
  const UniversalSpotlightBubble({
    super.key,
    required this.hostContext,
    required this.hostNavigator,
    required this.onDismiss,
    this.onActivateDismiss,
    this.callbacks = const SpotlightShellCallbacks(),
    this.initialQuery,
  });

  final BuildContext hostContext;
  final NavigatorState hostNavigator;
  final VoidCallback onDismiss;
  final VoidCallback? onActivateDismiss;
  final SpotlightShellCallbacks callbacks;
  final String? initialQuery;

  @override
  State<UniversalSpotlightBubble> createState() => _UniversalSpotlightBubbleState();
}

class _UniversalSpotlightBubbleState extends State<UniversalSpotlightBubble> with SingleTickerProviderStateMixin {
  static const _debounceDuration = Duration(milliseconds: 180);
  static const _bubbleRadius = BorderRadius.all(Radius.circular(26));

  late final TextEditingController _controller;
  late final FocusNode _inputFocusNode;
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<int> _selectedIndexNotifier = ValueNotifier<int>(0);

  late final Ticker _smoothScrollTicker;
  double _smoothTargetOffset = 0.0;
  double _smoothSpeed = 20.0;
  Duration? _lastSmoothTick;
  double _lastListViewportHeight = 360.0;

  Offset? _lastPointerPosition;
  bool _hoverSuppressed = false;

  SpotlightCategory _selectedCategory = SpotlightCategory.all;
  bool _isLoadingRemote = false;

  Timer? _debounceTimer;
  AbortController? _abortController;
  int _searchGeneration = 0;

  List<SpotlightEntry> _localEntries = const [];
  List<SpotlightEntry> _downloadedMediaEntries = const [];
  List<SpotlightEntry> _remoteEntries = const [];

  _SpotlightDisplayData? _cachedDisplay;
  _SpotlightLayoutMetrics? _cachedMetrics;
  double? _cachedMetricsTextScale;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery?.trim() ?? '';
    _controller = TextEditingController(text: initial);
    if (initial.isNotEmpty) {
      _controller.selection = TextSelection.collapsed(offset: initial.length);
    }
    _inputFocusNode = FocusNode(
      debugLabel: 'SpotlightInput',
      onKeyEvent: (_, event) => _handleKeyEvent(event),
    );
    _smoothScrollTicker = createTicker(_onSmoothScrollTick);
    _rebuildLocalEntries();
    _invalidateDisplayCache();
    if (initial.isNotEmpty) {
      _scheduleRemoteSearch(initial, immediate: true);
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _abortController?.abort();
    _smoothScrollTicker.dispose();
    _selectedIndexNotifier.dispose();
    _controller.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _invalidateDisplayCache() {
    _cachedDisplay = null;
    _cachedMetrics = null;
  }

  _SpotlightDisplayData _ensureDisplay() => _cachedDisplay ??= _computeDisplay();

  _SpotlightLayoutMetrics _ensureMetrics(_SpotlightDisplayData display, double textScale) {
    if (_cachedMetrics != null && _cachedMetricsTextScale == textScale) {
      return _cachedMetrics!;
    }
    _cachedMetricsTextScale = textScale;
    return _cachedMetrics = _SpotlightLayoutMetrics.compute(display.rows, display.selectable.length, textScale);
  }

  void _onSmoothScrollTick(Duration elapsed) {
    if (!_scrollController.hasClients || !_scrollController.position.hasContentDimensions) {
      _stopSmoothScroll();
      return;
    }
    final pos = _scrollController.position;
    final target = _smoothTargetOffset.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _smoothTargetOffset = target;
    final current = pos.pixels;
    final diff = target - current;

    if (diff.abs() < 0.35) {
      if (current != target) {
        pos.jumpTo(target);
      }
      _stopSmoothScroll();
      return;
    }

    final prev = _lastSmoothTick;
    _lastSmoothTick = elapsed;
    final dt = prev == null
        ? (1.0 / 120.0)
        : ((elapsed - prev).inMicroseconds / 1000000.0).clamp(0.001, 0.05);
    final factor = 1.0 - math.exp(-dt * _smoothSpeed);
    final next = current + diff * factor;
    pos.jumpTo(next.clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  void _stopSmoothScroll() {
    if (_smoothScrollTicker.isActive) {
      _smoothScrollTicker.stop();
    }
    _lastSmoothTick = null;
  }

  void _jumpScrollTo(double offset) {
    _stopSmoothScroll();
    _smoothTargetOffset = math.max(0.0, offset);
    if (_scrollController.hasClients && _scrollController.position.hasContentDimensions) {
      final pos = _scrollController.position;
      final clamped = offset.clamp(pos.minScrollExtent, pos.maxScrollExtent);
      _smoothTargetOffset = clamped;
      if (pos.pixels != clamped) {
        pos.jumpTo(clamped);
      }
    }
  }

  void _animateScrollTo(double target, {double speed = 22.0}) {
    if (!_scrollController.hasClients || !_scrollController.position.hasContentDimensions) {
      _smoothTargetOffset = math.max(0.0, target);
      return;
    }
    final pos = _scrollController.position;
    final clamped = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);

    if (!mounted || AppMotion.duration(context) == Duration.zero) {
      _jumpScrollTo(clamped);
      return;
    }

    _smoothTargetOffset = clamped;
    _smoothSpeed = speed;
    if ((clamped - pos.pixels).abs() < 0.35) {
      if (pos.pixels != clamped) {
        pos.jumpTo(clamped);
      }
      _stopSmoothScroll();
      return;
    }

    if (!_smoothScrollTicker.isActive) {
      _lastSmoothTick = null;
      unawaited(_smoothScrollTicker.start());
    }
  }

  void _handlePointerScroll(PointerScrollEvent signal) {
    if (signal.scrollDelta.dy == 0 || !_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (!pos.hasContentDimensions || pos.maxScrollExtent <= 0) return;

    GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
      if (!mounted || event is! PointerScrollEvent || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions) return;

      _hoverSuppressed = true;
      final delta = event.scrollDelta.dy;
      final current = position.pixels;
      final remaining = _smoothScrollTicker.isActive ? (_smoothTargetOffset - current) : 0.0;
      // Reverse immediately if wheel direction flips mid-glide
      final origin = (remaining * delta < 0)
          ? current
          : (_smoothScrollTicker.isActive ? _smoothTargetOffset : current);
      final target = (origin + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
      _animateScrollTo(target, speed: 20.0);
    });
  }

  void _rebuildLocalEntries() {
    final hostContext = widget.hostContext;
    if (!hostContext.mounted) return;

    final librariesProvider = Provider.of<LibrariesProvider?>(hostContext, listen: false);
    final hiddenProvider = Provider.of<HiddenLibrariesProvider?>(hostContext, listen: false);
    final multiServer = Provider.of<MultiServerProvider?>(hostContext, listen: false);
    final downloadProvider = Provider.of<DownloadProvider?>(hostContext, listen: false);

    final hiddenKeys = hiddenProvider?.hiddenLibraryKeys ?? const <String>{};
    final visibleLibraries = <MediaLibrary>[
      for (final lib in librariesProvider?.libraries ?? const <MediaLibrary>[])
        if (!lib.isShared && !hiddenKeys.contains(lib.globalKey)) lib,
    ];
    final hasMultipleServers = (multiServer?.onlineServerIds.length ?? 0) > 1;

    _localEntries = buildLocalSpotlightEntries(
      hostContext: hostContext,
      hostNavigator: widget.hostNavigator,
      visibleLibraries: visibleLibraries,
      hasMultipleServers: hasMultipleServers,
      callbacks: widget.callbacks,
    );

    if (downloadProvider != null) {
      final downloadedItems = <MediaItem>[
        ...downloadProvider.downloadedMovies,
        ...downloadProvider.downloadedShows,
        ...downloadProvider.downloadedEpisodes,
        ...downloadProvider.downloadedTracks,
      ];
      _downloadedMediaEntries = [
        for (final item in downloadedItems)
          _entryFromMediaItem(item, isOffline: widget.callbacks.isOffline, hasMultipleServers: hasMultipleServers),
      ];
    }
  }

  SpotlightEntry _entryFromMediaItem(
    MediaItem item, {
    required bool isOffline,
    required bool hasMultipleServers,
    int basePriority = 80,
  }) {
    final isEpisode = item.kind == MediaKind.episode;
    final subtitleParts = <String>[
      if (isEpisode && item.grandparentTitle != null && item.grandparentTitle!.isNotEmpty) item.grandparentTitle!,
      if (isEpisode && item.parentIndex != null && item.index != null) 'S${item.parentIndex}E${item.index}',
      if ((item.kind == MediaKind.album || item.kind == MediaKind.track) &&
          item.parentTitle != null &&
          item.parentTitle!.isNotEmpty)
        item.parentTitle!,
      if (item.year != null) '${item.year}',
      if (item.libraryTitle != null && item.libraryTitle!.isNotEmpty) item.libraryTitle!,
      if (hasMultipleServers && item.serverName != null && item.serverName!.isNotEmpty) item.serverName!,
    ];

    return SpotlightEntry(
      id: 'media:${item.globalKey}',
      title: item.title ?? t.common.unknown,
      subtitle: subtitleParts.isEmpty ? null : subtitleParts.join(' · '),
      badge: SpotlightEntry.badgeForMediaKind(item.kind),
      icon: SpotlightEntry.iconForMediaKind(item.kind),
      category: SpotlightEntry.categoryForMediaKind(item.kind),
      type: SpotlightEntry.entryTypeForMediaKind(item.kind),
      mediaItem: item,
      basePriority: basePriority,
      keywords: [
        if (item.originalTitle != null) item.originalTitle!,
        if (item.grandparentTitle != null) item.grandparentTitle!,
        if (item.parentTitle != null) item.parentTitle!,
        if (item.libraryTitle != null) item.libraryTitle!,
        if (item.year != null) '${item.year}',
      ],
      onActivate: () {
        final ctx = widget.hostNavigator.context;
        if (!ctx.mounted) return;
        unawaited(navigateToMediaItemDetails(ctx, item, isOffline: isOffline));
      },
    );
  }

  SpotlightEntry _entryFromPerson(MediaPerson person, {required bool hasMultipleServers, int basePriority = 75}) {
    final roleLabel = switch (person.credit) {
      PersonCredit.actor => t.explore.creditRole.actor,
      PersonCredit.director => t.explore.creditRole.director,
      null => t.spotlight.categories.people,
    };
    final subtitleParts = <String>[
      roleLabel,
      if (hasMultipleServers && person.serverName != null && person.serverName!.isNotEmpty) person.serverName!,
    ];

    return SpotlightEntry(
      id: 'person:${person.serverId}:${person.id}',
      title: person.name,
      subtitle: subtitleParts.join(' · '),
      badge: t.spotlight.categories.people,
      icon: Symbols.person_rounded,
      category: SpotlightCategory.people,
      type: SpotlightEntryType.person,
      person: person,
      basePriority: basePriority,
      onActivate: () {
        final ctx = widget.hostNavigator.context;
        if (!ctx.mounted) return;
        unawaited(
          navigateToPersonMedia(
            ctx,
            personId: person.id,
            name: person.name,
            thumbPath: person.thumbPath,
            serverId: person.serverId,
            serverName: person.serverName,
            backend: person.backend,
          ),
        );
      },
    );
  }

  void _onQueryChanged(String value) {
    final trimmed = value.trim();
    _selectedIndexNotifier.value = 0;
    setState(() {
      if (trimmed.isEmpty) {
        _remoteEntries = const [];
        _isLoadingRemote = false;
      }
      _invalidateDisplayCache();
    });
    _jumpScrollTo(0.0);
    _scheduleRemoteSearch(trimmed);
  }

  void _scheduleRemoteSearch(String trimmedQuery, {bool immediate = false}) {
    _debounceTimer?.cancel();
    _abortController?.abort();
    _abortController = null;

    if (trimmedQuery.isEmpty || widget.callbacks.isOffline) {
      if (_isLoadingRemote) {
        setState(() => _isLoadingRemote = false);
      }
      return;
    }

    final generation = ++_searchGeneration;
    setState(() => _isLoadingRemote = true);

    if (immediate) {
      unawaited(_runRemoteSearch(trimmedQuery, generation));
    } else {
      _debounceTimer = Timer(_debounceDuration, () {
        unawaited(_runRemoteSearch(trimmedQuery, generation));
      });
    }
  }

  Future<void> _runRemoteSearch(String query, int generation) async {
    final hostContext = widget.hostContext;
    if (!mounted || !hostContext.mounted) return;

    final multiServer = Provider.of<MultiServerProvider?>(hostContext, listen: false);
    if (multiServer == null || !multiServer.hasConnectedServers) {
      if (mounted && generation == _searchGeneration) {
        setState(() => _isLoadingRemote = false);
      }
      return;
    }

    final hiddenProvider = Provider.of<HiddenLibrariesProvider?>(hostContext, listen: false);
    final hiddenKeys = hiddenProvider?.hiddenLibraryKeys;
    final hasMultipleServers = multiServer.onlineServerIds.length > 1;
    final abort = AbortController();
    _abortController = abort;

    try {
      final result = await multiServer.aggregationService.searchAcrossServers(
        query,
        limit: 30,
        hiddenLibraryKeys: hiddenKeys,
        abort: abort,
      );
      if (!mounted || generation != _searchGeneration) return;

      final entries = <SpotlightEntry>[];
      var rankBoost = 240;
      for (final hit in result.hits) {
        final priority = math.max(60, rankBoost);
        rankBoost -= 6;
        switch (hit) {
          case MediaSearchHit(:final item):
            entries.add(
              _entryFromMediaItem(
                item,
                isOffline: false,
                hasMultipleServers: hasMultipleServers,
                basePriority: priority,
              ),
            );
          case PersonSearchHit(:final person):
            entries.add(_entryFromPerson(person, hasMultipleServers: hasMultipleServers, basePriority: priority));
        }
      }

      _selectedIndexNotifier.value = 0;
      setState(() {
        _remoteEntries = entries;
        _isLoadingRemote = false;
        _invalidateDisplayCache();
      });
      _jumpScrollTo(0.0);
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _isLoadingRemote = false);
    }
  }

  List<SpotlightCategory> _availableCategories(String query, List<SpotlightEntry> allMatches) {
    if (query.isEmpty) {
      return [
        SpotlightCategory.all,
        if (_localEntries.any((e) => e.category == SpotlightCategory.libraries)) SpotlightCategory.libraries,
        SpotlightCategory.actions,
        SpotlightCategory.settings,
        if (_downloadedMediaEntries.any((e) => e.category == SpotlightCategory.movies)) SpotlightCategory.movies,
        if (_downloadedMediaEntries.any((e) => e.category == SpotlightCategory.shows)) SpotlightCategory.shows,
      ];
    }

    final present = {for (final entry in allMatches) entry.category};
    return [
      SpotlightCategory.all,
      for (final category in SpotlightCategory.values)
        if (category != SpotlightCategory.all && (present.contains(category) || category == _selectedCategory))
          category,
    ];
  }

  _SpotlightDisplayData _computeDisplay() {
    final query = _controller.text.trim();

    if (query.isEmpty) {
      final categories = _availableCategories('', const []);
      final effectiveCategory = categories.contains(_selectedCategory) ? _selectedCategory : SpotlightCategory.all;

      final rows = <_SpotlightListRow>[];
      final selectable = <SpotlightEntry>[];

      void addSection(String title, Iterable<SpotlightEntry> items) {
        final filtered = [
          for (final item in items)
            if (effectiveCategory == SpotlightCategory.all || item.category == effectiveCategory) item,
        ];
        if (filtered.isEmpty) return;
        if (effectiveCategory == SpotlightCategory.all) {
          rows.add(_SpotlightHeaderRow(title, isFirst: rows.isEmpty));
        }
        for (final entry in filtered) {
          rows.add(_SpotlightEntryRow(entry: entry, selectableIndex: selectable.length, sectioned: true));
          selectable.add(entry);
        }
      }

      if (widget.callbacks.isOffline && _downloadedMediaEntries.isNotEmpty) {
        addSection(t.spotlight.sections.downloads, _downloadedMediaEntries.take(8));
      }
      addSection(t.spotlight.sections.libraries, _localEntries.where((e) => e.category == SpotlightCategory.libraries));
      addSection(
        t.spotlight.sections.quickActions,
        _localEntries.where((e) => e.category == SpotlightCategory.actions),
      );
      addSection(t.spotlight.sections.settings, _localEntries.where((e) => e.category == SpotlightCategory.settings));

      return (rows: rows, selectable: selectable, categories: categories);
    }

    // Non-empty query: score local entries + offline downloaded entries, and merge with remote entries.
    final scoredMap = <String, ({SpotlightEntry entry, int score})>{};

    for (final entry in _localEntries) {
      final score = scoreSpotlightQuery(entry, query);
      if (score >= 0) {
        scoredMap[entry.id] = (entry: entry, score: score);
      }
    }

    for (final entry in _downloadedMediaEntries) {
      final score = scoreSpotlightQuery(entry, query);
      if (score >= 0) {
        scoredMap[entry.id] = (entry: entry, score: score);
      }
    }

    for (final remote in _remoteEntries) {
      final localScore = scoreSpotlightQuery(remote, query);
      final effectiveScore = localScore >= 0
          ? math.max(localScore, remote.basePriority + 150)
          : remote.basePriority + 120;
      scoredMap[remote.id] = (entry: remote, score: effectiveScore);
    }

    final sortedAll = scoredMap.values.toList()..sort((a, b) => b.score.compareTo(a.score));
    final allMatchedEntries = [for (final item in sortedAll) item.entry];
    final categories = _availableCategories(query, allMatchedEntries);
    final effectiveCategory = categories.contains(_selectedCategory) ? _selectedCategory : SpotlightCategory.all;

    final filtered = [
      for (final entry in allMatchedEntries)
        if (effectiveCategory == SpotlightCategory.all || entry.category == effectiveCategory) entry,
    ];

    final rows = <_SpotlightListRow>[
      for (var i = 0; i < filtered.length; i++)
        _SpotlightEntryRow(entry: filtered[i], selectableIndex: i, sectioned: false),
    ];

    return (rows: rows, selectable: filtered, categories: categories);
  }

  void _activateEntry(SpotlightEntry entry) {
    (widget.onActivateDismiss ?? widget.onDismiss)();
    // Run on next microtask after the Spotlight route is removed so target
    // routes push and animate without overlapping 4K BackdropFilters.
    scheduleMicrotask(entry.onActivate);
  }

  void _scrollToSelected(int index) {
    final display = _ensureDisplay();
    if (index < 0 || index >= display.selectable.length) return;

    final textScale = mounted ? MediaQuery.textScalerOf(context).scale(1.0) : 1.0;
    final metrics = _ensureMetrics(display, textScale);
    final viewportHeight = _scrollController.hasClients && _scrollController.position.hasContentDimensions
        ? _scrollController.position.viewportDimension
        : _lastListViewportHeight;
    if (viewportHeight <= 0) return;

    final desiredTop = metrics.selectableTop[index];
    final desiredBottom = metrics.selectableBottom[index];
    final currentRef = _smoothScrollTicker.isActive
        ? _smoothTargetOffset
        : (_scrollController.hasClients ? _scrollController.offset : 0.0);

    double nextTarget = currentRef;
    if (desiredBottom > currentRef + viewportHeight) {
      nextTarget = desiredBottom - viewportHeight;
    } else if (desiredTop < currentRef) {
      nextTarget = desiredTop;
    }

    final maxExtent = math.max(0.0, metrics.totalContentHeight - viewportHeight);
    nextTarget = nextTarget.clamp(0.0, maxExtent);
    if ((nextTarget - currentRef).abs() > 0.5) {
      _animateScrollTo(nextTarget, speed: 24.0);
    }
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final display = _ensureDisplay();
    final selectable = display.selectable;
    final categories = display.categories;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) {
        widget.onDismiss();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      if (selectable.isNotEmpty) {
        final current = _selectedIndexNotifier.value.clamp(0, selectable.length - 1);
        final next = math.min(current + 1, selectable.length - 1);
        _hoverSuppressed = true;
        if (_selectedIndexNotifier.value != next) {
          _selectedIndexNotifier.value = next;
        }
        _scrollToSelected(next);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      if (selectable.isNotEmpty) {
        final current = _selectedIndexNotifier.value.clamp(0, selectable.length - 1);
        final prev = math.max(current - 1, 0);
        _hoverSuppressed = true;
        if (_selectedIndexNotifier.value != prev) {
          _selectedIndexNotifier.value = prev;
        }
        _scrollToSelected(prev);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.pageDown) {
      if (selectable.isNotEmpty) {
        final step = math.max(1, (_lastListViewportHeight / 62.0).floor() - 1);
        final current = _selectedIndexNotifier.value.clamp(0, selectable.length - 1);
        final next = math.min(current + step, selectable.length - 1);
        _hoverSuppressed = true;
        _selectedIndexNotifier.value = next;
        _scrollToSelected(next);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.pageUp) {
      if (selectable.isNotEmpty) {
        final step = math.max(1, (_lastListViewportHeight / 62.0).floor() - 1);
        final current = _selectedIndexNotifier.value.clamp(0, selectable.length - 1);
        final prev = math.max(current - step, 0);
        _hoverSuppressed = true;
        _selectedIndexNotifier.value = prev;
        _scrollToSelected(prev);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent && selectable.isNotEmpty) {
        final clamped = _selectedIndexNotifier.value.clamp(0, selectable.length - 1);
        _activateEntry(selectable[clamped]);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.tab && categories.length > 1) {
      if (event is KeyDownEvent) {
        final currentIdx = categories.indexOf(_selectedCategory);
        final reverse = HardwareKeyboard.instance.isShiftPressed;
        final nextIdx = reverse
            ? (currentIdx <= 0 ? categories.length - 1 : currentIdx - 1)
            : (currentIdx + 1) % categories.length;
        _selectedIndexNotifier.value = 0;
        _hoverSuppressed = true;
        setState(() {
          _selectedCategory = categories[nextIdx];
          _invalidateDisplayCache();
        });
        _jumpScrollTo(0.0);
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final tk = tokens(context);
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final keyboardBottom = MediaQuery.viewInsetsOf(context).bottom;
    final safeVertical = MediaQuery.paddingOf(context).vertical;
    final isMobile = PlatformDetector.isMobile(context);
    final usableHeight = (viewportHeight - keyboardBottom - safeVertical - (isMobile ? 28.0 : 48.0)).clamp(
      220.0,
      660.0,
    );
    final maxBubbleHeight = keyboardBottom > 0
        ? usableHeight
        : math.min(usableHeight, viewportHeight * (isMobile ? 0.68 : 0.76));
    final hairlineColor = colorScheme.onSurface.withValues(alpha: isDark ? 0.09 : 0.08);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);

    final display = _ensureDisplay();
    final selectable = display.selectable;
    final categories = display.categories;
    final metrics = _ensureMetrics(display, textScale);

    if (selectable.isNotEmpty && _selectedIndexNotifier.value >= selectable.length) {
      _selectedIndexNotifier.value = selectable.length - 1;
    }

    final bubbleRadius = isMobile ? const BorderRadius.all(Radius.circular(28)) : _bubbleRadius;

    return Semantics(
      label: t.spotlight.title,
      container: true,
      child: Listener(
        onPointerHover: (event) {
          final prev = _lastPointerPosition;
          if (prev != null && (event.position - prev).distanceSquared > 2.25) {
            _hoverSuppressed = false;
          }
          _lastPointerPosition = event.position;
        },
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) => _handleKeyEvent(event),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 820, maxHeight: maxBubbleHeight),
            child: GlassSurface(
              tint: isDark ? const Color(0xFF06070B) : colorScheme.surface,
              opacity: isMobile ? (isDark ? 0.90 : 0.93) : (isDark ? 0.80 : 0.85),
              sigma: isMobile ? 34 : 28,
              borderRadius: bubbleRadius,
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSearchHeader(context, colorScheme, tk, isMobile: isMobile, isDark: isDark),
                    if (categories.length > 1) _buildCategoryStrip(context, categories, colorScheme, tk),
                    Container(height: 1, color: hairlineColor),
                    Flexible(
                      child: selectable.isEmpty
                          ? _buildEmptyState(context, tk)
                          : LayoutBuilder(
                              builder: (context, constraints) {
                                final maxListHeight = constraints.maxHeight.isFinite
                                    ? constraints.maxHeight
                                    : maxBubbleHeight * 0.65;
                                final listHeight = math.min(metrics.totalContentHeight, maxListHeight);
                                _lastListViewportHeight = listHeight;

                                return SizedBox(
                                  height: listHeight,
                                  child: ScrollConfiguration(
                                    behavior: const _SpotlightScrollBehavior(),
                                    child: NotificationListener<ScrollUpdateNotification>(
                                      onNotification: (notification) {
                                        if (!_smoothScrollTicker.isActive && notification.dragDetails != null) {
                                          _smoothTargetOffset = notification.metrics.pixels;
                                        }
                                        return false;
                                      },
                                      child: Listener(
                                        onPointerDown: (_) => _stopSmoothScroll(),
                                        child: _SpotlightWheelRegion(
                                          onPointerScroll: _handlePointerScroll,
                                          child: ListView.builder(
                                            controller: _scrollController,
                                            shrinkWrap: false,
                                            addAutomaticKeepAlives: false,
                                            addSemanticIndexes: false,
                                            scrollCacheExtent: const ScrollCacheExtent.pixels(320),
                                            padding: EdgeInsets.fromLTRB(
                                              isMobile ? 10 : 14,
                                              _SpotlightLayoutMetrics.listTopPadding,
                                              isMobile ? 10 : 14,
                                              _SpotlightLayoutMetrics.listBottomPadding,
                                            ),
                                            itemCount: display.rows.length,
                                            itemExtentBuilder: (rowIndex, _) =>
                                                rowIndex >= 0 && rowIndex < metrics.rowExtents.length
                                                ? metrics.rowExtents[rowIndex]
                                                : null,
                                            itemBuilder: (context, rowIndex) {
                                              final row = display.rows[rowIndex];
                                              return switch (row) {
                                                _SpotlightHeaderRow(:final title, :final isFirst) =>
                                                  _buildSectionHeader(context, title, tk, isFirst: isFirst),
                                                _SpotlightEntryRow(
                                                  :final entry,
                                                  :final selectableIndex,
                                                  :final sectioned,
                                                ) =>
                                                  _buildEntryTile(
                                                    context,
                                                    entry: entry,
                                                    index: selectableIndex,
                                                    sectioned: sectioned,
                                                    isDark: isDark,
                                                    isMobile: isMobile,
                                                    colorScheme: colorScheme,
                                                    tk: tk,
                                                  ),
                                              };
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    if (!isMobile) ...[
                      Container(height: 1, color: hairlineColor),
                      _buildFooterHints(context, tk, colorScheme, isDark: isDark),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchHeader(
    BuildContext context,
    ColorScheme colorScheme,
    MonoTokens tk, {
    required bool isMobile,
    required bool isDark,
  }) {
    final hasQuery = _controller.text.isNotEmpty;
    final inputFontSize = isMobile ? 17.0 : 21.0;

    return Padding(
      padding: isMobile ? const EdgeInsets.fromLTRB(16, 14, 12, 12) : const EdgeInsets.fromLTRB(24, 20, 20, 15),
      child: Row(
        children: [
          SizedBox(
            width: isMobile ? 22 : 26,
            height: isMobile ? 22 : 26,
            child: Center(
              child: _isLoadingRemote
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.0, color: colorScheme.primary),
                    )
                  : AppIcon(
                      Symbols.search_rounded,
                      size: isMobile ? 21 : 25,
                      color: tk.textMuted.withValues(alpha: 0.88),
                    ),
            ),
          ),
          SizedBox(width: isMobile ? 10 : 14),
          Expanded(
            child: TextField(
              key: const ValueKey('spotlight_search_input'),
              controller: _controller,
              focusNode: _inputFocusNode,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              cursorColor: colorScheme.primary,
              cursorWidth: 2.0,
              cursorRadius: const Radius.circular(1),
              style: TextStyle(
                fontSize: inputFontSize,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.25,
                color: colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                fillColor: Colors.transparent,
                hoverColor: Colors.transparent,
                focusColor: Colors.transparent,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: t.spotlight.placeholder,
                hintStyle: TextStyle(
                  fontSize: inputFontSize,
                  fontWeight: FontWeight.w400,
                  letterSpacing: -0.2,
                  color: tk.textMuted.withValues(alpha: 0.56),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 5),
              ),
            ),
          ),
          if (hasQuery)
            IconButton(
              visualDensity: VisualDensity.compact,
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll(EdgeInsets.all(6)),
                minimumSize: WidgetStatePropertyAll(Size(32, 32)),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              tooltip: t.common.clear,
              icon: AppIcon(Symbols.cancel_rounded, fill: 1, size: 19, color: tk.textMuted),
              onPressed: () {
                _controller.clear();
                _onQueryChanged('');
                _inputFocusNode.requestFocus();
              },
            ),
          if (isMobile) ...[
            const SizedBox(width: 4),
            Semantics(
              button: true,
              label: t.common.close,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onDismiss,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colorScheme.onSurface.withValues(alpha: isDark ? 0.11 : 0.08),
                  ),
                  child: Center(
                    child: AppIcon(Symbols.close_rounded, size: 18, color: colorScheme.onSurface.withValues(alpha: 0.78)),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCategoryStrip(
    BuildContext context,
    List<SpotlightCategory> categories,
    ColorScheme colorScheme,
    MonoTokens tk,
  ) {
    final isMobile = PlatformDetector.isMobile(context);
    final effectiveCategory = categories.contains(_selectedCategory) ? _selectedCategory : SpotlightCategory.all;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(isMobile ? 14 : 20, 0, isMobile ? 14 : 20, isMobile ? 12 : 15),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < categories.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            _SpotlightFilterChip(
              label: categories[i].label,
              active: categories[i] == effectiveCategory,
              colorScheme: colorScheme,
              tk: tk,
              onTap: () {
                _selectedIndexNotifier.value = 0;
                _hoverSuppressed = true;
                setState(() {
                  _selectedCategory = categories[i];
                  _invalidateDisplayCache();
                });
                _jumpScrollTo(0.0);
                _inputFocusNode.requestFocus();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, MonoTokens tk, {required bool isFirst}) {
    return Align(
      alignment: AlignmentDirectional.bottomStart,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, isFirst ? 2 : 8, 12, 6),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: tk.textMuted.withValues(alpha: 0.68),
          ),
        ),
      ),
    );
  }

  Widget _buildEntryTile(
    BuildContext context, {
    required SpotlightEntry entry,
    required int index,
    required bool sectioned,
    required bool isDark,
    required bool isMobile,
    required ColorScheme colorScheme,
    required MonoTokens tk,
  }) {
    final showBadge = !sectioned && entry.badge != null && entry.badge!.isNotEmpty;
    final isCompactPhone = isMobile && MediaQuery.sizeOf(context).width < 600;
    final showKeyboardSelection = !isCompactPhone || InputModeTracker.isKeyboardMode(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onHover: (_) {
        if (!_hoverSuppressed && _selectedIndexNotifier.value != index) {
          _selectedIndexNotifier.value = index;
        }
      },
      child: ValueListenableBuilder<int>(
        valueListenable: _selectedIndexNotifier,
        builder: (context, selectedIndex, _) {
          final isSelected = showKeyboardSelection && selectedIndex == index;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: const BorderRadius.all(Radius.circular(14)),
                highlightColor: colorScheme.onSurface.withValues(alpha: isDark ? 0.11 : 0.08),
                splashColor: Colors.transparent,
                onTap: () => _activateEntry(entry),
                child: Ink(
                  padding: EdgeInsets.symmetric(horizontal: isCompactPhone ? 12 : 14),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? colorScheme.onSurface.withValues(alpha: isDark ? 0.10 : 0.07)
                        : Colors.transparent,
                    borderRadius: const BorderRadius.all(Radius.circular(14)),
                  ),
                  child: Row(
                    children: [
                      _buildLeadingVisual(context, entry, isSelected, colorScheme, tk),
                      SizedBox(width: isCompactPhone ? 13 : 15),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: isCompactPhone ? 15.5 : 16,
                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                                letterSpacing: -0.15,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            if (entry.subtitle != null && entry.subtitle!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                entry.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: isCompactPhone ? 13.0 : 13.5,
                                  color: tk.textMuted.withValues(alpha: 0.74),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (showBadge) ...[
                        const SizedBox(width: 10),
                        Text(
                          entry.badge!,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: tk.textMuted.withValues(alpha: isSelected ? 0.80 : 0.58),
                          ),
                        ),
                      ],
                      if (isSelected) ...[
                        const SizedBox(width: 10),
                        _KeycapBadge(label: '↵', colorScheme: colorScheme, tk: tk, isDark: isDark),
                      ] else if (isCompactPhone) ...[
                        const SizedBox(width: 6),
                        AppIcon(
                          Symbols.chevron_right_rounded,
                          size: 18,
                          color: tk.textMuted.withValues(alpha: 0.42),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLeadingVisual(
    BuildContext context,
    SpotlightEntry entry,
    bool isSelected,
    ColorScheme colorScheme,
    MonoTokens tk,
  ) {
    final mediaItem = entry.mediaItem;
    if (mediaItem != null) {
      final client = widget.hostContext.mounted
          ? widget.hostContext.tryGetMediaClientForServer(serverIdOrNull(mediaItem.serverId))
          : null;
      final isEpisode = mediaItem.kind == MediaKind.episode;
      final isSquareMusic =
          mediaItem.kind == MediaKind.artist || mediaItem.kind == MediaKind.album || mediaItem.kind == MediaKind.track;
      final thumbWidth = isEpisode ? 64.0 : (isSquareMusic ? 44.0 : 41.0);
      final thumbHeight = isEpisode ? 38.0 : (isSquareMusic ? 44.0 : 58.0);
      final imagePath = isEpisode ? (mediaItem.thumbPath ?? mediaItem.grandparentThumbPath) : mediaItem.thumbPath;

      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          border: Border.fromBorderSide(BorderSide(color: colorScheme.onSurface.withValues(alpha: 0.08))),
        ),
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(7)),
            child: SizedBox(
              width: thumbWidth,
              height: thumbHeight,
              child: OptimizedMediaImage(
                client: client,
                imagePath: imagePath,
                width: thumbWidth,
                height: thumbHeight,
                fit: BoxFit.cover,
                fallbackIcon: entry.icon,
                imageType: isEpisode ? ImageType.thumb : (isSquareMusic ? ImageType.square : ImageType.poster),
              ),
            ),
          ),
        ),
      );
    }

    final person = entry.person;
    if (person != null) {
      final client = widget.hostContext.mounted ? widget.hostContext.tryGetMediaClientForServer(person.serverId) : null;
      return DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.fromBorderSide(BorderSide(color: colorScheme.onSurface.withValues(alpha: 0.08))),
        ),
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: ClipOval(
            child: SizedBox(
              width: 42,
              height: 42,
              child: OptimizedMediaImage(
                client: client,
                imagePath: person.thumbPath,
                width: 42,
                height: 42,
                fit: BoxFit.cover,
                fallbackIcon: Symbols.person_rounded,
                imageType: ImageType.avatar,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: colorScheme.onSurface.withValues(alpha: isSelected ? 0.12 : 0.055),
        borderRadius: const BorderRadius.all(Radius.circular(11)),
      ),
      child: Center(
        child: AppIcon(
          entry.icon,
          size: 22,
          fill: isSelected ? 1 : 0,
          color: isSelected ? colorScheme.onSurface : tk.textMuted.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, MonoTokens tk) {
    final query = _controller.text.trim();
    if (_isLoadingRemote) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 52, horizontal: 28),
        child: Center(
          child: Text(t.common.loading, style: TextStyle(fontSize: 15, color: tk.textMuted)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(Symbols.search_off_rounded, size: 36, color: tk.textMuted.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            query.isEmpty ? t.spotlight.emptyPromptTitle : t.spotlight.noResultsTitle(query: query),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, letterSpacing: -0.15),
          ),
          const SizedBox(height: 5),
          Text(
            query.isEmpty ? t.spotlight.emptyPromptSubtitle : t.spotlight.noResultsSubtitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: tk.textMuted.withValues(alpha: 0.78)),
          ),
        ],
      ),
    );
  }

  Widget _buildFooterHints(BuildContext context, MonoTokens tk, ColorScheme colorScheme, {required bool isDark}) {
    final hintStyle = TextStyle(fontSize: 12.5, color: tk.textMuted.withValues(alpha: 0.70));
    return ColoredBox(
      color: colorScheme.onSurface.withValues(alpha: isDark ? 0.025 : 0.03),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _KeycapBadge(label: '↑↓', colorScheme: colorScheme, tk: tk, isDark: isDark),
                const SizedBox(width: 6),
                Text(t.spotlight.hints.navigate, style: hintStyle),
                const SizedBox(width: 16),
                _KeycapBadge(label: '↵', colorScheme: colorScheme, tk: tk, isDark: isDark),
                const SizedBox(width: 6),
                Text(t.spotlight.hints.open, style: hintStyle),
                const SizedBox(width: 16),
                _KeycapBadge(label: 'Tab', colorScheme: colorScheme, tk: tk, isDark: isDark),
                const SizedBox(width: 6),
                Text(t.spotlight.hints.filter, style: hintStyle),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _KeycapBadge(label: t.spotlight.shortcutHint, colorScheme: colorScheme, tk: tk, isDark: isDark),
                const SizedBox(width: 5),
                _KeycapBadge(label: 'Esc', colorScheme: colorScheme, tk: tk, isDark: isDark),
                const SizedBox(width: 6),
                Text(t.spotlight.hints.close, style: hintStyle),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Clean scroll behavior for Spotlight so the VSync smooth-scroll ticker owns
/// wheel interpolation without outer overscroll wrappers competing.
class _SpotlightScrollBehavior extends MaterialScrollBehavior {
  const _SpotlightScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
  };

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

/// Registers Spotlight's VSync smooth wheel handler ahead of [Scrollable]'s raw
/// discrete jump listener while preserving normal hit-testing for taps & drags.
class _SpotlightWheelRegion extends SingleChildRenderObjectWidget {
  const _SpotlightWheelRegion({required this.onPointerScroll, required super.child});

  final ValueChanged<PointerScrollEvent> onPointerScroll;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSpotlightWheelRegion(onPointerScroll);

  @override
  void updateRenderObject(BuildContext context, _RenderSpotlightWheelRegion renderObject) {
    renderObject.onPointerScroll = onPointerScroll;
  }
}

class _RenderSpotlightWheelRegion extends RenderProxyBox {
  _RenderSpotlightWheelRegion(this.onPointerScroll);

  ValueChanged<PointerScrollEvent> onPointerScroll;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return child?.hitTest(result, position: position) ?? false;
  }

  @override
  void handleEvent(PointerEvent event, covariant HitTestEntry entry) {
    if (event is PointerScrollEvent) {
      onPointerScroll(event);
    }
  }
}

class _SpotlightFilterChip extends StatefulWidget {
  const _SpotlightFilterChip({
    required this.label,
    required this.active,
    required this.colorScheme,
    required this.tk,
    required this.onTap,
  });

  final String label;
  final bool active;
  final ColorScheme colorScheme;
  final MonoTokens tk;
  final VoidCallback onTap;

  @override
  State<_SpotlightFilterChip> createState() => _SpotlightFilterChipState();
}

class _SpotlightFilterChipState extends State<_SpotlightFilterChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final colorScheme = widget.colorScheme;
    final bg = active
        ? colorScheme.primary
        : (_hovered ? colorScheme.onSurface.withValues(alpha: 0.07) : Colors.transparent);
    final fg = active
        ? colorScheme.onPrimary
        : (_hovered ? colorScheme.onSurface : widget.tk.textMuted.withValues(alpha: 0.85));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7.5),
          decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.all(Radius.circular(999))),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              letterSpacing: -0.1,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _KeycapBadge extends StatelessWidget {
  const _KeycapBadge({required this.label, required this.colorScheme, required this.tk, required this.isDark});

  final String label;
  final ColorScheme colorScheme;
  final MonoTokens tk;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.onSurface.withValues(alpha: isDark ? 0.085 : 0.07),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
          color: tk.text.withValues(alpha: 0.78),
        ),
      ),
    );
  }
}
