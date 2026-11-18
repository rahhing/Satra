import 'dart:async';
import 'package:drift/native.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:satra/media/ids.dart';
import 'package:satra/media/library_filter_result.dart';
import 'package:satra/media/library_genre.dart';
import 'package:satra/media/library_query.dart';
import 'package:satra/media/media_sort.dart' as media_sort;
import 'package:satra/media/media_playlist.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/connection/connection.dart';
import 'package:satra/focus/covered_route_focus_boundary.dart';
import 'package:satra/focus/input_mode_tracker.dart';
import 'package:satra/connection/connection_registry.dart';
import 'package:satra/database/app_database.dart';
import 'package:satra/focus/focusable_action_bar.dart';
import 'package:satra/i18n/strings.g.dart';
import 'package:satra/media/media_backend.dart';
import 'package:satra/media/media_hub.dart';
import 'package:satra/media/media_item.dart';
import 'package:satra/media/media_kind.dart';
import 'package:satra/media/media_library.dart';
import 'package:satra/media/media_server_client.dart';
import 'package:satra/media/server_capabilities.dart';
import 'package:satra/mixins/refreshable.dart';
import 'package:satra/mixins/tab_visibility_aware.dart';
import 'package:satra/profiles/active_profile_provider.dart';
import 'package:satra/profiles/plex_home_service.dart';
import 'package:satra/profiles/profile.dart';
import 'package:satra/profiles/profile_connection.dart';
import 'package:satra/profiles/profile_connection_registry.dart';
import 'package:satra/profiles/profile_registry.dart';
import 'package:satra/providers/companion_remote_provider.dart';
import 'package:satra/providers/discover_provider.dart';
import 'package:satra/providers/hidden_libraries_provider.dart';
import 'package:satra/providers/libraries_provider.dart';
import 'package:satra/providers/multi_server_provider.dart';
import 'package:satra/screens/discover_screen.dart';
import 'package:satra/screens/main_screen.dart';
import 'package:satra/screens/libraries/libraries_screen.dart';
import 'package:satra/widgets/focusable_tab_chip.dart';
import 'package:satra/widgets/glass_surface.dart';
import 'package:satra/widgets/hub_section.dart';
import 'package:satra/widgets/ios_glass_control.dart';
import 'package:satra/utils/media_server_http_client.dart';
import 'package:satra/services/data_aggregation_service.dart';
import 'package:satra/services/multi_server_manager.dart';
import 'package:satra/services/settings_service.dart';
import 'package:satra/services/storage_service.dart';
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/utils/layout_constants.dart';
import 'package:satra/utils/platform_detector.dart';
import 'package:satra/watch_together/watch_together.dart';
import 'package:satra/widgets/tv_browse_rail.dart';
import 'package:satra/widgets/system_clock.dart';
import 'package:satra/widgets/toolbar_scrim.dart';
import 'package:satra/widgets/tv_spotlight_background.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';

const double _testExpandedBleed = 220.0;
const double _testCollapsedBleed = 64.0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => initializeDateFormatting('en'));

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(true);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
  });

  testWidgets('TV tab focus returns to discover browse rail instead of reload action', (tester) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.libraryDensity, LibraryDensity.max);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final item = testMediaItem(
      id: 'movie_1',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Movie 1',
      serverId: 'server_1',
      serverName: 'Server',
    );
    final hub = MediaHub(id: 'hub_1', title: 'Recommended', type: 'movie', items: [item], size: 1);
    final client = _FakeMediaServerClient(hubs: [hub]);
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    final multiServerProvider = testMultiServerProvider(manager);
    final hiddenLibrariesProvider = HiddenLibrariesProvider();
    final librariesProvider = LibrariesProvider();
    final watchTogetherProvider = WatchTogetherProvider();
    final companionRemoteProvider = CompanionRemoteProvider();

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileRegistry = _FakeProfileRegistry(db);
    final connectionRegistry = _FakeConnectionRegistry(db);
    final profileConnectionRegistry = _FakeProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
    final plexHome = PlexHomeService(
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    final activeProfileProvider = ActiveProfileProvider(
      registry: profileRegistry,
      plexHome: plexHome,
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
    );
    final discoverProvider = DiscoverProvider(
      multiServerProvider,
      hiddenLibrariesProvider,
      librariesProvider,
      profileId: null,
      isProfileBinding: () => activeProfileProvider.isBinding,
    );
    final discoverKey = GlobalKey<State<DiscoverScreen>>();
    const targetSidebarOffset = _testExpandedBleed;
    const currentForegroundLeft = 120.0;
    const foregroundWidth = 1280 - _testCollapsedBleed;

    addTearDown(() async {
      discoverProvider.dispose();
      activeProfileProvider.dispose();
      companionRemoteProvider.dispose();
      watchTogetherProvider.dispose();
      librariesProvider.dispose();
      hiddenLibrariesProvider.dispose();
      multiServerProvider.dispose();
      await plexHome.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
            ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogetherProvider),
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemoteProvider),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfileProvider),
            ChangeNotifierProvider<DiscoverProvider>.value(value: discoverProvider),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: MainScreenFocusScope(
              sideNavigationWidth: targetSidebarOffset,
              reservedSideNavigationWidth: _testCollapsedBleed,
              foregroundLeft: currentForegroundLeft,
              foregroundWidth: foregroundWidth,
              viewportWidth: 1280,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: foregroundWidth,
                  height: 720,
                  child: DiscoverScreen(key: discoverKey),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byType(TvBrowseRail), findsOneWidget);

    final scale = TvLayoutConstants.scaleForSize(const Size(1280, 720));
    final spotlightLeft = (24 * scale).clamp(18.0, 40.0).toDouble();
    final spotlightBackground = tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground));
    expect(spotlightBackground.contentLeft, closeTo(spotlightLeft + currentForegroundLeft, 0.001));

    final railHeight = TvBrowseRailLayout.estimateHeight(
      size: const Size(foregroundWidth, 720),
      hubs: [hub],
      density: LibraryDensity.max,
      episodePosterMode: settings.read(SettingsService.episodePosterMode),
      fullCardLayout: settings.read(SettingsService.tvFullCardLayout),
      gridSpacing: settings.read(SettingsService.gridSpacing),
      tallPosterScale: TvBrowseRailLayout.compactTallPosterScale,
      widePosterScale: TvBrowseRailLayout.compactEpisodeThumbnailScale,
    );
    final minimumSpotlightBottom = railHeight + (8 * scale);
    final baseSpotlightBottom = (720 * 0.48).clamp(160.0, 820.0).toDouble();
    final desiredSpotlightBottom = minimumSpotlightBottom > baseSpotlightBottom
        ? minimumSpotlightBottom
        : baseSpotlightBottom;
    final maxSpotlightBottom = (720 - ((720 * 0.075).clamp(64.0 * scale, 120.0 * scale)) - (96 * scale))
        .clamp(0.0, double.infinity)
        .toDouble();
    final expectedSpotlightBottom = desiredSpotlightBottom > maxSpotlightBottom
        ? maxSpotlightBottom
        : desiredSpotlightBottom;
    expect(spotlightBackground.contentBottom, closeTo(expectedSpotlightBottom, 0.001));

    // The rail no longer receives the bleed via constructor (a per-flip param
    // would rebuild the whole rail); its bleed layer reads the scope's
    // sideNavigationWidth itself. Assert the rendered bleed position instead.
    final browseRail = tester.widget<TvBrowseRail>(find.byType(TvBrowseRail));
    expect(browseRail.backgroundBleedLeft, isNull);
    final railBleedPositions = tester
        .widgetList<Positioned>(find.descendant(of: find.byType(TvBrowseRail), matching: find.byType(Positioned)))
        .where((p) => p.left == -targetSidebarOffset);
    expect(railBleedPositions, isNotEmpty, reason: 'rail bleed layer positions at -sideNavigationWidth');

    final backgroundPosition = tester.widget<Positioned>(
      find.ancestor(of: find.byType(TvSpotlightBackground), matching: find.byType(Positioned)).first,
    );
    expect(backgroundPosition.left, -currentForegroundLeft);
    expect(backgroundPosition.width, 1280);

    tester.state<FocusableActionBarState>(find.byType(FocusableActionBar)).requestFocusOnFirst();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'refresh');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv_browse_rail');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    tester.state<FocusableActionBarState>(find.byType(FocusableActionBar)).requestFocusOnFirst();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'refresh');

    (discoverKey.currentState! as FocusableTab).focusActiveTabIfReady();
    (discoverKey.currentState! as TabVisibilityAware).onTabHidden();
    await tester.pump();
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'refresh');

    (discoverKey.currentState! as TabVisibilityAware).onTabShown();
    (discoverKey.currentState! as FocusableTab).focusActiveTabIfReady();
    await tester.pump();
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv_browse_rail');
  });
  testWidgets('startup prime does not duplicate the load DiscoverScreen started in initState', (tester) async {
    // DiscoverScreen.initState fires load(); main_screen._primeOnlineServices
    // then primes the content tabs once libraries land. Asking for a full
    // refresh there queued a trailing pass through CoalescedLoadCoordinator and
    // ran the whole home fan-out twice on every cold start (#1784).
    await SettingsService.getInstance();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final hub = MediaHub(id: 'hub_1', title: 'Recommended', type: 'movie', items: const [], size: 0);
    final client = _GatedHubsFakeClient(hubs: [hub]);
    // Disposes both the provider and the manager it wraps; MultiServerProvider
    // does not own the manager, and manager.dispose() is what closes its
    // status/progress controllers and the registered clients.
    final multiServerProvider = testMultiServer(clients: [client]).provider;
    final hiddenLibrariesProvider = HiddenLibrariesProvider();
    final librariesProvider = LibrariesProvider();
    final watchTogetherProvider = WatchTogetherProvider();
    final companionRemoteProvider = CompanionRemoteProvider();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final connectionRegistry = _FakeConnectionRegistry(db);
    final profileConnectionRegistry = _FakeProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
    final plexHome = PlexHomeService(
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    final activeProfileProvider = ActiveProfileProvider(
      registry: _FakeProfileRegistry(db),
      plexHome: plexHome,
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
    );
    final discoverProvider = DiscoverProvider(
      multiServerProvider,
      hiddenLibrariesProvider,
      librariesProvider,
      profileId: null,
      isProfileBinding: () => false,
    );
    addTearDown(() async {
      discoverProvider.dispose();
      activeProfileProvider.dispose();
      companionRemoteProvider.dispose();
      watchTogetherProvider.dispose();
      librariesProvider.dispose();
      hiddenLibrariesProvider.dispose();
      // multiServerProvider + its manager are torn down by testMultiServer.
      await plexHome.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
            ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
            ChangeNotifierProvider<DiscoverProvider>.value(value: discoverProvider),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogetherProvider),
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemoteProvider),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfileProvider),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: MainScreenFocusScope(
              sideNavigationWidth: _testExpandedBleed,
              reservedSideNavigationWidth: _testCollapsedBleed,
              foregroundLeft: 0,
              foregroundWidth: 1280,
              viewportWidth: 1280,
              child: const SizedBox(width: 1280, height: 720, child: DiscoverScreen()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The initState pass is in flight, waiting on the server.
    expect(discoverProvider.isLoadInFlight, isTrue);
    expect(client.hubCalls, 1);

    final screen = tester.state(find.byType(DiscoverScreen)) as FullRefreshable;
    screen.primeRefresh();

    client.release();
    // Bounded pumps, not pumpAndSettle: the hero carousel runs a repeating
    // auto-scroll timer, so the frame loop never goes quiet.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(client.hubCalls, 1, reason: 'the prime rode along with the load already running');
    expect(discoverProvider.isLoadInFlight, isFalse);

    // A prime with nothing in flight (reconnect-from-offline) must still refetch.
    screen.primeRefresh();
    await tester.pump();
    client.release();
    await tester.pump();
    await tester.pump();

    expect(client.hubCalls, 2);
  });

  testWidgets('Refreshable.refresh refetches hubs only once they are stale (#1646)', (tester) async {
    // The stale-resume gate goes through Refreshable.refresh(). A fresh
    // refresh must stay Continue Watching-only (zero hub calls), but once the
    // hub list is older than DiscoverProvider.staleAfter it must run a full
    // pass — otherwise media added server-side never appears until a restart.
    await SettingsService.getInstance();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    var currentTime = DateTime(2026, 1, 1, 12);
    final hub = MediaHub(id: 'hub_1', title: 'Recommended', type: 'movie', items: const [], size: 0);
    final client = _GatedHubsFakeClient(hubs: [hub]);
    final multiServerProvider = testMultiServer(clients: [client]).provider;
    final hiddenLibrariesProvider = HiddenLibrariesProvider();
    final librariesProvider = LibrariesProvider();
    final watchTogetherProvider = WatchTogetherProvider();
    final companionRemoteProvider = CompanionRemoteProvider();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final connectionRegistry = _FakeConnectionRegistry(db);
    final profileConnectionRegistry = _FakeProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
    final plexHome = PlexHomeService(
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    final activeProfileProvider = ActiveProfileProvider(
      registry: _FakeProfileRegistry(db),
      plexHome: plexHome,
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
    );
    final discoverProvider = DiscoverProvider(
      multiServerProvider,
      hiddenLibrariesProvider,
      librariesProvider,
      profileId: null,
      isProfileBinding: () => false,
      now: () => currentTime,
    );
    addTearDown(() async {
      discoverProvider.dispose();
      activeProfileProvider.dispose();
      companionRemoteProvider.dispose();
      watchTogetherProvider.dispose();
      librariesProvider.dispose();
      hiddenLibrariesProvider.dispose();
      // multiServerProvider + its manager are torn down by testMultiServer.
      await plexHome.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
            ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
            ChangeNotifierProvider<DiscoverProvider>.value(value: discoverProvider),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogetherProvider),
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemoteProvider),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfileProvider),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: MainScreenFocusScope(
              sideNavigationWidth: _testExpandedBleed,
              reservedSideNavigationWidth: _testCollapsedBleed,
              foregroundLeft: 0,
              foregroundWidth: 1280,
              viewportWidth: 1280,
              child: const SizedBox(width: 1280, height: 720, child: DiscoverScreen()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Let the initState load pass commit, stamping hub freshness at T0.
    client.release();
    await tester.pump();
    await tester.pump();
    expect(client.hubCalls, 1);
    expect(discoverProvider.isLoadInFlight, isFalse);

    final screen = tester.state(find.byType(DiscoverScreen)) as Refreshable;

    // Fresh: the resume refresh stays Continue Watching-only.
    screen.refresh();
    await tester.pump();
    await tester.pump();
    expect(client.hubCalls, 1, reason: 'a fresh refresh must not refetch hubs');

    // Stale: the same refresh entry point now runs the full pass.
    currentTime = currentTime.add(DiscoverProvider.staleAfter + const Duration(seconds: 1));
    screen.refresh();
    await tester.pump();
    client.release();
    await tester.pump();
    await tester.pump();
    expect(client.hubCalls, 2, reason: 'a stale refresh must refetch the home hubs');
  });

  testWidgets('TV selects Continue Watching when it arrives after recommendation hubs', (tester) async {
    await SettingsService.getInstance();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final recommendedItem = testMediaItem(
      id: 'recommended',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Recommended',
      serverId: 'server_1',
      serverName: 'Server',
    );
    final continueItem = testMediaItem(
      id: 'continue',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Continue Watching',
      serverId: 'server_1',
      serverName: 'Server',
    );
    final recommendedHub = MediaHub(
      id: 'recommended_hub',
      title: 'Recommended',
      type: 'movie',
      items: [recommendedItem],
      size: 1,
    );
    final client = _FakeMediaServerClient(hubs: [recommendedHub]);
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    final multiServerProvider = MultiServerProvider(manager, DataAggregationService(manager));
    final hiddenLibrariesProvider = HiddenLibrariesProvider();
    final librariesProvider = LibrariesProvider();
    final watchTogetherProvider = WatchTogetherProvider();
    final companionRemoteProvider = CompanionRemoteProvider();

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileRegistry = _FakeProfileRegistry(db);
    final connectionRegistry = _FakeConnectionRegistry(db);
    final profileConnectionRegistry = _FakeProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
    final plexHome = PlexHomeService(
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    final activeProfileProvider = ActiveProfileProvider(
      registry: profileRegistry,
      plexHome: plexHome,
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
    );
    final discoverProvider = DiscoverProvider(
      multiServerProvider,
      hiddenLibrariesProvider,
      librariesProvider,
      profileId: null,
      isProfileBinding: () => activeProfileProvider.isBinding,
    );
    const foregroundWidth = 1280 - _testCollapsedBleed;

    addTearDown(() async {
      discoverProvider.dispose();
      activeProfileProvider.dispose();
      companionRemoteProvider.dispose();
      watchTogetherProvider.dispose();
      librariesProvider.dispose();
      hiddenLibrariesProvider.dispose();
      multiServerProvider.dispose();
      await plexHome.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
            ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogetherProvider),
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemoteProvider),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfileProvider),
            ChangeNotifierProvider<DiscoverProvider>.value(value: discoverProvider),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: MainScreenFocusScope(
              sideNavigationWidth: _testExpandedBleed,
              reservedSideNavigationWidth: _testCollapsedBleed,
              foregroundLeft: 0,
              foregroundWidth: foregroundWidth,
              viewportWidth: 1280,
              child: const SizedBox(width: foregroundWidth, height: 720, child: DiscoverScreen()),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv_browse_rail');
    expect(tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground)).item?.id, recommendedItem.id);

    client.continueWatching = [continueItem];
    await discoverProvider.load();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv_browse_rail');
    expect(tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground)).item?.id, continueItem.id);
  });

  testWidgets('desktop hero keeps indicators visible in keyboard mode and fades to solid bg', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(false);
    await SettingsService.getInstance();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final onDeck = [
      for (var i = 0; i < 3; i++)
        testMediaItem(
          id: 'movie_$i',
          backend: MediaBackend.plex,
          kind: MediaKind.movie,
          title: 'Movie $i',
          serverId: 'server_1',
          serverName: 'Server',
        ),
    ];
    final client = _FakeMediaServerClient(hubs: const [], continueWatching: onDeck);
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    final multiServerProvider = testMultiServerProvider(manager);
    final hiddenLibrariesProvider = HiddenLibrariesProvider();
    final librariesProvider = LibrariesProvider();
    final watchTogetherProvider = WatchTogetherProvider();
    final companionRemoteProvider = CompanionRemoteProvider();

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileRegistry = _FakeProfileRegistry(db);
    final connectionRegistry = _FakeConnectionRegistry(db);
    final profileConnectionRegistry = _FakeProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
    final plexHome = PlexHomeService(
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    final activeProfileProvider = ActiveProfileProvider(
      registry: profileRegistry,
      plexHome: plexHome,
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
    );
    final discoverProvider = DiscoverProvider(
      multiServerProvider,
      hiddenLibrariesProvider,
      librariesProvider,
      profileId: null,
      isProfileBinding: () => activeProfileProvider.isBinding,
    );

    addTearDown(() async {
      discoverProvider.dispose();
      activeProfileProvider.dispose();
      companionRemoteProvider.dispose();
      watchTogetherProvider.dispose();
      librariesProvider.dispose();
      hiddenLibrariesProvider.dispose();
      multiServerProvider.dispose();
      await plexHome.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
            ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogetherProvider),
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemoteProvider),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfileProvider),
            ChangeNotifierProvider<DiscoverProvider>.value(value: discoverProvider),
          ],
          child: InputModeTracker(
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark).copyWith(platform: TargetPlatform.linux),
              home: MainScreenFocusScope(
                sideNavigationWidth: _testExpandedBleed,
                reservedSideNavigationWidth: _testCollapsedBleed,
                foregroundLeft: 0,
                foregroundWidth: 1280,
                viewportWidth: 1280,
                child: const DiscoverScreen(),
              ),
            ),
          ),
        ),
      ),
    );

    // Bounded pumps only: the hero runs periodic auto-scroll/indicator timers,
    // so pumpAndSettle would never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PageView), findsOneWidget);
    final firstMarker = find.byKey(const ValueKey('hero_page_0'));
    expect(firstMarker, findsOneWidget, reason: 'hero indicators render in pointer mode');

    // Entering keyboard mode must not hide the indicators on non-TV devices
    // (regression: back-key/BT-keyboard events left them permanently hidden).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(firstMarker, findsOneWidget, reason: 'hero indicators stay visible in keyboard mode on non-TV');

    // The bottom fade must end in solid scaffold background before the hero
    // edge so the artwork cannot ghost through at the hero/content boundary.
    final scaffoldBg = Theme.of(tester.element(find.byType(DiscoverScreen))).scaffoldBackgroundColor;
    final heroFades = tester
        .widgetList<Container>(
          find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).gradient is LinearGradient,
          ),
        )
        .map((c) => (c.decoration! as BoxDecoration).gradient! as LinearGradient)
        .where((g) => g.begin == Alignment.topCenter && g.end == Alignment.bottomCenter && g.colors.length == 4)
        .toList();
    expect(heroFades, isNotEmpty, reason: 'hero bottom fade overlay renders');
    for (final fade in heroFades) {
      expect(fade.stops, const [0.5, 0.85, 0.94, 1.0]);
      expect(fade.colors[2], scaffoldBg, reason: 'fade reaches full bg at 94%');
      expect(fade.colors[3], scaffoldBg);
    }

    // Dispose the screen so the hero's periodic timers are cancelled before
    // the binding's pending-timer check.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('iPhone landscape Discover keeps part of the first shelf visible below the hero', (tester) async {
    final movie = testMediaItem(id: 'featured', title: 'Featured', artPath: '/art', serverId: 'server_1');
    final client = _FakeMediaServerClient(continueWatching: [movie], hubs: const []);
    await _pumpDiscoverShell(tester, isTv: false, platform: TargetPlatform.iOS, mediaClient: client);
    tester.view.physicalSize = const Size(844, 390);
    tester.view.padding = const FakeViewPadding(left: 47, right: 47, bottom: 21);
    addTearDown(tester.view.resetPadding);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final play = find.text(t.common.play);
    final shelf = find.byType(HubSection).first;
    expect(tester.getTopLeft(play).dx, inInclusiveRange(47, 140));
    expect(tester.getTopLeft(shelf).dx, 47);
    expect(tester.getBottomLeft(play).dy, lessThan(tester.getTopLeft(shelf).dy));
    expect(tester.getTopLeft(shelf).dy, lessThan(325));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('iOS Discover caps the scroll shade and uses mobile hero controls', (tester) async {
    final movie = testMediaItem(id: 'featured', title: 'Featured', artPath: '/art', serverId: 'server_1');
    final client = _FakeMediaServerClient(
      continueWatching: [
        movie,
        testMediaItem(id: 'next', title: 'Next', artPath: '/next-art', serverId: 'server_1'),
      ],
      hubs: [
        for (var i = 0; i < 12; i++) MediaHub(id: 'hub_$i', title: 'Shelf $i', type: 'movie', items: [movie], size: 1),
      ],
    );
    await _pumpDiscoverShell(tester, isTv: false, platform: TargetPlatform.iOS, mediaClient: client);

    final scroll = tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!;
    final screen = scroll.position.viewportDimension;
    final shade = find.byKey(const ValueKey('discover_hero_background_shade'));
    final sharp = find.byKey(const ValueKey('discover_backdrop_sharp'));
    final blur = find.byKey(const ValueKey('discover_backdrop_blur'));
    double alpha() {
      final gradient = (tester.widget<DecoratedBox>(shade).decoration as BoxDecoration).gradient!;
      return gradient.colors.first.a;
    }

    expect(find.byKey(const ValueKey('hero_page_0')), findsOneWidget);
    expect(find.byIcon(Symbols.pause_rounded), findsNothing);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(alpha(), closeTo(.04, .001));
    final blurBounds = tester.getRect(blur);
    final blurSource = find.byKey(const ValueKey('discover_backdrop_blur_source'));
    expect(tester.getRect(blurSource), tester.getRect(sharp));
    final gradient = (tester.widget<DecoratedBox>(shade).decoration as BoxDecoration).gradient as LinearGradient;
    expect(gradient.stops![2], closeTo(tester.getSize(sharp).height / blurBounds.height, .001));
    expect(gradient.colors[2].a, closeTo(.56, .001));
    // From the beginning of Continue Watching downward, shade progressively darkens.
    final cwTop = tester.getTopLeft(find.text('Continue Watching')).dy;
    final cwStopIndex = gradient.stops!.indexWhere((s) => (s - cwTop / blurBounds.height).abs() < .05);
    expect(cwStopIndex, greaterThanOrEqualTo(3));
    for (var i = cwStopIndex; i < gradient.colors.length - 1; i++) {
      expect(gradient.colors[i + 1].a, greaterThan(gradient.colors[i].a));
    }
    expect(gradient.colors.last.a, greaterThan(.80));
    scroll.jumpTo(100);
    await tester.pump();
    expect(tester.widget<Transform>(sharp).transform.getTranslation().y, -100);
    expect(tester.getRect(blur), blurBounds);
    scroll.jumpTo(screen / 2);
    await tester.pump();
    final midScrollTopAlpha = alpha();
    expect(midScrollTopAlpha, greaterThan(.35));
    scroll.jumpTo(screen);
    await tester.pump();
    expect(alpha(), greaterThan(midScrollTopAlpha));
    expect(sharp, findsNothing);
    expect(tester.getRect(blur), blurBounds);
    expect(scroll.position.maxScrollExtent, greaterThan(screen * 2));
    scroll.jumpTo(screen * 2);
    await tester.pump();
    final maximum = alpha();
    expect(maximum, closeTo(.93, .001));
    scroll.jumpTo(screen * 2.5);
    await tester.pump();
    expect(alpha(), closeTo(maximum, .001));
    scroll.jumpTo(0);
    await tester.pump();
    expect(alpha(), closeTo(.04, .001));
    expect(sharp, findsOneWidget);

    // Disabling Darken Backdrop in Appearance settings restores the lighter shade curve.
    final settings = SettingsService.instance;
    await settings.write(SettingsService.darkenMobileBackdrop, false);
    await tester.pump();
    expect(alpha(), 0);
    scroll.jumpTo(screen / 2);
    await tester.pump();
    expect(alpha(), closeTo(.14, .001));
    scroll.jumpTo(screen);
    await tester.pump();
    expect(alpha(), closeTo(.28, .001));
    scroll.jumpTo(0);
    await tester.pump();
    await settings.write(SettingsService.darkenMobileBackdrop, true);
    await tester.pump();

    await settings.write(SettingsService.useClassicMobileBackdrop, true);
    await tester.pump();
    expect(sharp, findsNothing);
    expect(blur, findsNothing);
    expect(alpha(), closeTo(.04, .001));
    await settings.write(SettingsService.useClassicMobileBackdrop, false);
    await tester.pump();
    expect(sharp, findsOneWidget);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    GlassSurface.debugEnableIOSNativeGlass = true;
    try {
      final beforeRefresh = client.globalHubCalls;
      final gesture = await tester.startGesture(const Offset(190, 300));
      await gesture.moveBy(const Offset(0, 180));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      expect(
        find.byWidgetPredicate((widget) => widget is IOSGlassControl && widget.configuration['kind'] == 'refresh'),
        findsOneWidget,
      );
      await gesture.up();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(client.globalHubCalls, greaterThan(beforeRefresh));
    } finally {
      debugDefaultTargetPlatformOverride = null;
      GlassSurface.debugEnableIOSNativeGlass = null;
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the home clock is TV-only chrome', (tester) async {
    await _pumpDiscoverShell(tester, isTv: false);
    expect(find.text(t.discover.title), findsOneWidget);
    expect(
      find.byType(SystemClock),
      findsNothing,
      reason: 'a phone status bar and a desktop menu bar already show the time',
    );
    await tester.pumpWidget(const SizedBox());

    await _pumpDiscoverShell(tester, isTv: true);
    expect(find.byType(SystemClock), findsOneWidget, reason: 'a fullscreen leanback app hides the system clock');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('top bar displays Home and the main server libraries, selecting a library on tap', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.mainServerId, null);

    const mainMovies = MediaLibrary(
      id: '1',
      backend: MediaBackend.plex,
      title: 'Movies',
      kind: MediaKind.movie,
      serverId: 'server_1',
      serverName: 'home',
    );
    const mainShows = MediaLibrary(
      id: '2',
      backend: MediaBackend.plex,
      title: 'TV Shows',
      kind: MediaKind.show,
      serverId: 'server_1',
      serverName: 'home',
    );
    const secondServerLib = MediaLibrary(
      id: '3',
      backend: MediaBackend.plex,
      title: 'Secondary Movies',
      kind: MediaKind.movie,
      serverId: 'server_secondary',
      serverName: 'homeserver',
    );

    final librariesProvider = LibrariesProvider();
    final hiddenLibrariesProvider = HiddenLibrariesProvider();
    await hiddenLibrariesProvider.ensureInitialized();

    final client = _FakeMediaServerClient(hubs: const []);
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    final multiServerProvider = testMultiServerProvider(manager);
    final watchTogetherProvider = WatchTogetherProvider();
    final companionRemoteProvider = CompanionRemoteProvider();

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileRegistry = _FakeProfileRegistry(db);
    final connectionRegistry = _FakeConnectionRegistry(db);
    final profileConnectionRegistry = _FakeProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
    final plexHome = PlexHomeService(
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    final activeProfileProvider = ActiveProfileProvider(
      registry: profileRegistry,
      plexHome: plexHome,
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
    );
    final discoverProvider = DiscoverProvider(
      multiServerProvider,
      hiddenLibrariesProvider,
      librariesProvider,
      profileId: 'p1',
      isProfileBinding: () => false,
      syncSystemShelf: (_, _) async {},
    );

    String? selectedLibraryKey;
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
            ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogetherProvider),
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemoteProvider),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfileProvider),
            ChangeNotifierProvider<DiscoverProvider>.value(value: discoverProvider),
          ],
          child: InputModeTracker(
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: MainScreenFocusScope(
                sideNavigationWidth: _testCollapsedBleed,
                selectLibrary: (key) => selectedLibraryKey = key,
                child: const DiscoverScreen(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byTooltip(t.libraries.manageLibraries), findsNothing);
    final toolbarBounds = tester.getRect(find.byType(ToolbarScrim));
    tester.state<FocusableActionBarState>(find.byType(FocusableActionBar)).requestFocusOnFirst();
    await tester.pump();
    final refreshFocus = FocusManager.instance.primaryFocus;
    expect(refreshFocus?.debugLabel, 'refresh');
    // At launch Home mounts before the server's libraries arrive. A cached
    // toolbar must still update its controls when that first load completes.
    await librariesProvider.updateLibraryOrder(const [mainMovies, mainShows, secondServerLib]);
    await tester.pumpAndSettle();
    expect(find.byTooltip(t.libraries.manageLibraries), findsOneWidget);
    expect(tester.getRect(find.byType(ToolbarScrim)), toolbarBounds);
    expect(FocusManager.instance.primaryFocus, same(refreshFocus));
    expect(find.text(t.common.home), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('TV Shows'), findsOneWidget);
    expect(find.text('Secondary Movies'), findsNothing, reason: 'only main server libraries appear in top bar');
    for (final section in LibraryTabType.values) {
      expect(find.text(section.label), findsOneWidget);
    }
    expect(find.byTooltip(t.common.shuffle), findsOneWidget);
    expect(client.sectionCalls, isEmpty, reason: 'Recommended must not eagerly load the other sections');

    for (final section in [
      LibraryTabType.collections,
      LibraryTabType.playlists,
      LibraryTabType.genres,
      LibraryTabType.browse,
    ]) {
      await tester.tap(find.text(section.label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: section.name);
      final selected = tester
          .widgetList<FocusableTabChip>(find.byType(FocusableTabChip))
          .where((chip) => chip.isSelected);
      expect(selected.map((chip) => chip.label), [t.common.home, section.label]);
      expect(tester.getRect(find.byType(ToolbarScrim)), toolbarBounds);
      expect(client.sectionCalls.where((call) => call == section.name), hasLength(1));
    }
    await tester.tap(find.text(t.libraries.tabs.recommended));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.libraries.tabs.collections));
    await tester.pumpAndSettle();
    expect(client.sectionCalls.where((call) => call == 'collections'), hasLength(1), reason: 'retain loaded sections');
    await tester.tap(find.text(t.common.home));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(t.libraries.manageLibraries));
    await tester.pumpAndSettle();
    expect(
      find.text('Secondary Movies'),
      findsOneWidget,
      reason: 'Home can manage all libraries, including other servers',
    );
    Navigator.of(tester.element(find.text('Secondary Movies'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('TV Shows'));
    await tester.pump();
    expect(selectedLibraryKey, mainShows.globalKey);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clicking the Watch Together participant count opens Watch Together (#2846)', (tester) async {
    await _pumpDiscoverShell(tester, isTv: false, watchTogether: _InSessionWatchTogether(participantCount: 3));
    final badge = find.descendant(of: find.byType(FocusableActionBar), matching: find.text('3'));
    expect(badge, findsOneWidget);

    // Click where the badge is drawn; the button underneath must take it.
    await tester.tapAt(tester.getCenter(badge));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(WatchTogetherScreen), findsOneWidget, reason: 'the badge sits on the button it labels');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a pending TV rail focus is dropped once the user has moved to the sidebar', (tester) async {
    // The first load arms "focus the rail when it has hubs"; an empty-items
    // hub keeps it armed because the rail has nothing to render yet. Items
    // landing on a later pass must not pull focus off a sidebar item the
    // user has since navigated to.
    final gated = await _pumpGatedDiscover(tester);
    gated.sidebarItem.requestFocus();
    await tester.pump();

    await gated.landItems(tester);

    expect(find.byType(TvBrowseRail), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus,
      same(gated.sidebarItem),
      reason: 'items landing must not steal the sidebar',
    );
  });

  testWidgets('a pending TV rail focus still claims the rail while focus sits on a bare scope', (tester) async {
    // Startup shape: MainScreen has focused its content scope but nothing
    // below it yet. That is "nowhere", not a destination the user chose, so
    // the rail keeps its initial-focus claim when hubs finally arrive.
    final gated = await _pumpGatedDiscover(tester);
    expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>());

    await gated.landItems(tester);

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv_browse_rail');
  });

  testWidgets('an explicit tab handoff claims the rail while focus still sits on the sidebar', (tester) async {
    // Sidebar → Home: MainScreen calls focusActiveTabIfReady() without moving
    // focus off the sidebar item that selected the tab. Focus resting there
    // is the handoff in flight, not the user navigating away.
    final gated = await _pumpGatedDiscover(tester);
    await gated.landItems(tester);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv_browse_rail');

    gated.sidebarItem.requestFocus();
    await tester.pump();
    (tester.state(find.byType(DiscoverScreen)) as FocusableTab).focusActiveTabIfReady();
    await tester.pump();
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv_browse_rail');
  });

  testWidgets('a handoff made while hubs are still loading claims the rail when they land', (tester) async {
    // Same handoff on a slow server: the rail has nothing to focus yet, so the
    // claim stays armed with focus on the sidebar item. Items landing later
    // must honor it — focus has not moved since the user selected Home.
    final gated = await _pumpGatedDiscover(tester);
    gated.sidebarItem.requestFocus();
    await tester.pump();
    (tester.state(find.byType(DiscoverScreen)) as FocusableTab).focusActiveTabIfReady();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(gated.sidebarItem));

    await gated.landItems(tester);

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv_browse_rail');
  });

  testWidgets('a handoff claim lapses once the user moves to another sidebar item', (tester) async {
    final gated = await _pumpGatedDiscover(tester);
    gated.sidebarItem.requestFocus();
    await tester.pump();
    (tester.state(find.byType(DiscoverScreen)) as FocusableTab).focusActiveTabIfReady();
    await tester.pump();

    gated.otherSidebarItem.requestFocus();
    await tester.pump();

    await gated.landItems(tester);

    expect(find.byType(TvBrowseRail), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus,
      same(gated.otherSidebarItem),
      reason: 'the user navigated on; do not yank focus',
    );
  });

  testWidgets('the first-load rail claim made under a root route lands when it pops (#2817)', (tester) async {
    final gated = await _pumpGatedDiscover(tester, underRootCover: true);
    await gated.landItems(tester);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'root_cover',
      reason: 'the claim must not steal the covering route',
    );

    gated.rootNavigator!.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv_browse_rail');
  });
}

class _GatedDiscover {
  _GatedDiscover({required this.client, required this.sidebarItem, required this.otherSidebarItem, this.rootNavigator});

  final _GatedHubsFakeClient client;
  final FocusNode sidebarItem;
  final FocusNode otherSidebarItem;

  /// Set with `underRootCover`; popping it uncovers the screen.
  final GlobalKey<NavigatorState>? rootNavigator;

  /// Replace the empty-items hub with a populated one and run a full pass.
  Future<void> landItems(WidgetTester tester) async {
    client.hubs
      ..clear()
      ..add(
        MediaHub(
          id: 'hub_1',
          title: 'Recommended',
          type: 'movie',
          items: [testMediaItem(id: 'movie_1', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Movie 1')],
          size: 1,
        ),
      );
    // skipOffstage: a covering root route leaves the screen offstage.
    (tester.state(find.byType(DiscoverScreen, skipOffstage: false)) as FullRefreshable).fullRefresh();
    await tester.pump();
    client.release();
    await tester.pump();
    await tester.pump();
  }
}

/// Mounts a TV [DiscoverScreen] beside a sidebar stand-in and completes its
/// first load with a hub that has no items, so the rail has nothing to render
/// and the screen's "focus the rail when ready" request stays armed.
///
/// [underRootCover] mounts it the way the profile session does — behind a
/// [CoveredRouteFocusBoundary] and a nested navigator — and pushes a route on
/// the root navigator before that first load lands, as when a profile chosen
/// in the root picker remounts the session beneath it.
Future<_GatedDiscover> _pumpGatedDiscover(WidgetTester tester, {bool underRootCover = false}) async {
  await SettingsService.getInstance();
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  final client = _GatedHubsFakeClient(
    hubs: [MediaHub(id: 'hub_1', title: 'Recommended', type: 'movie', items: const [], size: 0)],
  );
  final multiServerProvider = testMultiServer(clients: [client]).provider;
  final hiddenLibrariesProvider = HiddenLibrariesProvider();
  final librariesProvider = LibrariesProvider();
  final watchTogetherProvider = WatchTogetherProvider();
  final companionRemoteProvider = CompanionRemoteProvider();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final connectionRegistry = _FakeConnectionRegistry(db);
  final profileConnectionRegistry = _FakeProfileConnectionRegistry(db);
  final storage = await StorageService.getInstance();
  final plexHome = PlexHomeService(
    connections: connectionRegistry,
    profileConnections: profileConnectionRegistry,
    storage: storage,
    plexHomeUserFetcher: (_) async => const [],
  );
  final activeProfileProvider = ActiveProfileProvider(
    registry: _FakeProfileRegistry(db),
    plexHome: plexHome,
    connections: connectionRegistry,
    profileConnections: profileConnectionRegistry,
    storage: storage,
  );
  final discoverProvider = DiscoverProvider(
    multiServerProvider,
    hiddenLibrariesProvider,
    librariesProvider,
    profileId: null,
    isProfileBinding: () => false,
  );
  final sidebarItem = FocusNode(debugLabel: 'sidebar_item');
  final otherSidebarItem = FocusNode(debugLabel: 'other_sidebar_item');
  final cover = FocusNode(debugLabel: 'root_cover');
  final rootNavigator = underRootCover ? GlobalKey<NavigatorState>() : null;
  addTearDown(() async {
    sidebarItem.dispose();
    otherSidebarItem.dispose();
    cover.dispose();
    discoverProvider.dispose();
    activeProfileProvider.dispose();
    companionRemoteProvider.dispose();
    watchTogetherProvider.dispose();
    librariesProvider.dispose();
    hiddenLibrariesProvider.dispose();
    // multiServerProvider + its manager are torn down by testMultiServer.
    await plexHome.dispose();
    await db.close();
  });

  final shell = Row(
    children: [
      Column(
        children: [
          Focus(focusNode: sidebarItem, child: const SizedBox(width: 80, height: 360)),
          Focus(focusNode: otherSidebarItem, child: const SizedBox(width: 80, height: 360)),
        ],
      ),
      MainScreenFocusScope(
        sideNavigationWidth: _testExpandedBleed,
        reservedSideNavigationWidth: _testCollapsedBleed,
        foregroundLeft: 80,
        foregroundWidth: 1200,
        viewportWidth: 1280,
        child: const SizedBox(width: 1200, height: 720, child: DiscoverScreen()),
      ),
    ],
  );
  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
          ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
          ChangeNotifierProvider<DiscoverProvider>.value(value: discoverProvider),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogetherProvider),
          ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemoteProvider),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfileProvider),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            navigatorKey: rootNavigator,
            theme: monoTheme(MonoPalette.dark),
            home: rootNavigator == null
                ? shell
                : CoveredRouteFocusBoundary(
                    child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => shell)),
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (rootNavigator != null) {
    rootNavigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Focus(focusNode: cover, autofocus: true, child: const SizedBox.expand()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }
  client.release();
  await tester.pump();
  await tester.pump();
  expect(
    find.byType(TvBrowseRail, skipOffstage: false),
    findsNothing,
    reason: 'an empty-items hub gives the rail nothing to show',
  );
  return _GatedDiscover(
    client: client,
    sidebarItem: sidebarItem,
    otherSidebarItem: otherSidebarItem,
    rootNavigator: rootNavigator,
  );
}

/// Mounts [DiscoverScreen] in the smallest graph both layout branches need, so
/// one test can compare the TV and non-TV chrome without rebuilding it twice.
/// Takes ownership of [watchTogether].
Future<void> _pumpDiscoverShell(
  WidgetTester tester, {
  required bool isTv,
  WatchTogetherProvider? watchTogether,
  TargetPlatform? platform,
  _FakeMediaServerClient? mediaClient,
}) async {
  TvDetectionService.debugSetAppleTVOverride(isTv);
  await SettingsService.getInstance();
  tester.view.devicePixelRatio = 1.0;
  final size = platform == TargetPlatform.iOS ? const Size(390, 844) : const Size(1280, 720);
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  final client = mediaClient ?? _FakeMediaServerClient(hubs: const []);
  final manager = MultiServerManager()..debugRegisterClientForTesting(client);
  final multiServerProvider = testMultiServerProvider(manager);
  final hiddenLibrariesProvider = HiddenLibrariesProvider();
  final librariesProvider = LibrariesProvider();
  final watchTogetherProvider = watchTogether ?? WatchTogetherProvider();
  final companionRemoteProvider = CompanionRemoteProvider();

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final storage = await StorageService.getInstance();
  final connectionRegistry = _FakeConnectionRegistry(db);
  final profileConnectionRegistry = _FakeProfileConnectionRegistry(db);
  final plexHome = PlexHomeService(
    connections: connectionRegistry,
    profileConnections: profileConnectionRegistry,
    storage: storage,
    plexHomeUserFetcher: (_) async => const [],
  );
  final activeProfileProvider = ActiveProfileProvider(
    registry: _FakeProfileRegistry(db),
    plexHome: plexHome,
    connections: connectionRegistry,
    profileConnections: profileConnectionRegistry,
    storage: storage,
  );
  final discoverProvider = DiscoverProvider(
    multiServerProvider,
    hiddenLibrariesProvider,
    librariesProvider,
    profileId: null,
    isProfileBinding: () => activeProfileProvider.isBinding,
  );

  addTearDown(() async {
    discoverProvider.dispose();
    activeProfileProvider.dispose();
    companionRemoteProvider.dispose();
    watchTogetherProvider.dispose();
    librariesProvider.dispose();
    hiddenLibrariesProvider.dispose();
    multiServerProvider.dispose();
    await plexHome.dispose();
    await db.close();
  });

  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibrariesProvider),
          ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogetherProvider),
          ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemoteProvider),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfileProvider),
          ChangeNotifierProvider<DiscoverProvider>.value(value: discoverProvider),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark).copyWith(platform: platform),
            home: MainScreenFocusScope(
              sideNavigationWidth: _testExpandedBleed,
              reservedSideNavigationWidth: _testCollapsedBleed,
              foregroundLeft: 0,
              foregroundWidth: size.width,
              viewportWidth: size.width,
              child: const DiscoverScreen(),
            ),
          ),
        ),
      ),
    ),
  );

  // Bounded pumps only: the hero runs periodic auto-scroll timers, so
  // pumpAndSettle would never settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

class _FakeMediaServerClient implements MediaServerClient {
  final List<MediaHub> hubs;
  List<MediaItem> continueWatching;
  final sectionCalls = <String>[];
  int globalHubCalls = 0;

  _FakeMediaServerClient({required this.hubs, this.continueWatching = const []});

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) => '';

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    sectionCalls.add('collections');
    return const LibraryPage(items: [], totalCount: 0);
  }

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    sectionCalls.add('playlists');
    return const LibraryPage(items: [], totalCount: 0);
  }

  @override
  Future<List<LibraryGenre>> fetchLibraryGenres(String libraryId, {required MediaKind libraryKind}) async {
    sectionCalls.add('genres');
    return const [];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    sectionCalls.add('browse');
    return const LibraryPage(items: [], totalCount: 0);
  }

  @override
  Future<List<media_sort.MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => const [];

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async =>
      LibraryFilterResult.empty;

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async =>
      continueWatching;

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async {
    globalHubCalls++;
    return hubs;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Hub client that holds each fetch open until [release], so a test can act
/// while a Discover load pass is genuinely in flight.
class _GatedHubsFakeClient implements MediaServerClient {
  _GatedHubsFakeClient({required this.hubs});

  final List<MediaHub> hubs;
  int hubCalls = 0;
  final _gates = <Completer<List<MediaHub>>>[];

  void release() {
    for (final gate in _gates.where((g) => !g.isCompleted)) {
      gate.complete(hubs);
    }
  }

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async =>
      const [];

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => const [];

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) {
    hubCalls++;
    final gate = Completer<List<MediaHub>>();
    _gates.add(gate);
    return gate.future;
  }

  /// Reached by `MultiServerManager.dispose()` via `_closeClientGracefully`.
  /// Releases any gate still open so teardown cannot leave a fetch hanging.
  @override
  void close() => release();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileRegistry extends ProfileRegistry {
  _FakeProfileRegistry(super.db);

  @override
  Stream<List<Profile>> watchProfiles() => Stream.value(const []);

  @override
  Future<List<Profile>> list() async => const [];
}

class _FakeConnectionRegistry extends ConnectionRegistry {
  _FakeConnectionRegistry(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value(const []);

  @override
  Future<List<Connection>> list() async => const [];
}

class _FakeProfileConnectionRegistry extends ProfileConnectionRegistry {
  _FakeProfileConnectionRegistry(super.db);

  @override
  Stream<List<ProfileConnection>> watchAll() => Stream.value(const []);
}

/// A joined room with [participantCount] people, for chrome that only reads
/// the session summary.
class _InSessionWatchTogether extends WatchTogetherProvider {
  _InSessionWatchTogether({required this.participantCount});

  @override
  final int participantCount;

  @override
  bool get isInSession => true;
}
