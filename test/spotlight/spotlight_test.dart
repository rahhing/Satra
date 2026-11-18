import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:satra/i18n/strings.g.dart';
import 'package:satra/media/ids.dart';
import 'package:satra/media/media_backend.dart';
import 'package:satra/media/media_item.dart';
import 'package:satra/media/media_kind.dart';
import 'package:satra/media/media_library.dart';
import 'package:satra/media/media_person.dart';
import 'package:satra/media/media_server_client.dart';
import 'package:satra/media/server_capabilities.dart';
import 'package:satra/providers/hidden_libraries_provider.dart';
import 'package:satra/providers/libraries_provider.dart';
import 'package:satra/providers/multi_server_provider.dart';
import 'package:satra/spotlight/spotlight_dialog.dart';
import 'package:satra/spotlight/spotlight_models.dart';
import 'package:satra/spotlight/spotlight_settings_index.dart';
import 'package:satra/spotlight/spotlight_shortcut.dart';
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/utils/media_server_http_client.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_stack.dart';

class _FakeSearchClient extends Fake implements MediaServerClient {
  _FakeSearchClient({this.items = const [], this.people = const []});

  final List<MediaItem> items;
  final List<MediaPerson> people;

  @override
  ServerId get serverId => ServerId('srv-1');

  @override
  String? get serverName => 'Home Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities();

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => const [
    MediaLibrary(
      id: 'lib-anime',
      backend: MediaBackend.plex,
      title: 'Anime Movies',
      kind: MediaKind.movie,
      serverId: 'srv-1',
      serverName: 'Home Server',
    ),
    MediaLibrary(
      id: 'lib-shows',
      backend: MediaBackend.plex,
      title: 'Sci-Fi Shows',
      kind: MediaKind.show,
      serverId: 'srv-1',
      serverName: 'Home Server',
    ),
  ];

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final lower = query.toLowerCase();
    return [
      for (final item in items)
        if ((item.title ?? '').toLowerCase().contains(lower)) item,
    ];
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final lower = query.toLowerCase();
    return [
      for (final person in people)
        if (person.name.toLowerCase().contains(lower)) person,
    ];
  }

  @override
  void close() {}
}

KeyDownEvent _spaceDown() => const KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.space,
  logicalKey: LogicalKeyboardKey.space,
  timeStamp: Duration.zero,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  group('isSpotlightShortcut', () {
    test('matches Ctrl + Space across Linux, macOS, and Windows', () {
      for (final platform in [TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          isSpotlightShortcut(
            _spaceDown(),
            isControlPressed: true,
            isAltPressed: false,
            isMetaPressed: false,
            isShiftPressed: false,
          ),
          isTrue,
          reason: 'Ctrl + Space must trigger Universal Spotlight on $platform',
        );
      }
      debugDefaultTargetPlatformOverride = null;
    });

    test('rejects Cmd + Space, Alt + Space, Shift + Ctrl + Space, plain Space, and KeyUpEvent', () {
      expect(
        isSpotlightShortcut(
          _spaceDown(),
          isControlPressed: false,
          isMetaPressed: true,
          isAltPressed: false,
          isShiftPressed: false,
        ),
        isFalse,
      );
      expect(
        isSpotlightShortcut(
          _spaceDown(),
          isControlPressed: true,
          isAltPressed: true,
          isMetaPressed: false,
          isShiftPressed: false,
        ),
        isFalse,
      );
      expect(
        isSpotlightShortcut(
          _spaceDown(),
          isControlPressed: true,
          isAltPressed: false,
          isMetaPressed: false,
          isShiftPressed: true,
        ),
        isFalse,
      );
      expect(
        isSpotlightShortcut(
          _spaceDown(),
          isControlPressed: false,
          isAltPressed: false,
          isMetaPressed: false,
          isShiftPressed: false,
        ),
        isFalse,
      );
      expect(
        isSpotlightShortcut(
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.space,
            logicalKey: LogicalKeyboardKey.space,
            timeStamp: Duration.zero,
          ),
          isControlPressed: true,
          isAltPressed: false,
          isMetaPressed: false,
          isShiftPressed: false,
        ),
        isFalse,
      );
    });
  });

  group('scoreSpotlightQuery', () {
    final subtitleEntry = SpotlightEntry(
      id: 'setting:subtitles',
      title: 'Subtitle Styling',
      subtitle: 'Customize subtitle size and background',
      badge: 'Settings',
      icon: Symbols.subtitles_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      keywords: const ['captions', 'font', 'color'],
      onActivate: () {},
    );

    test('ranks exact and prefix matches above keyword matches and rejects missing tokens', () {
      final exact = scoreSpotlightQuery(subtitleEntry, 'subtitle styling');
      final prefix = scoreSpotlightQuery(subtitleEntry, 'sub');
      final keyword = scoreSpotlightQuery(subtitleEntry, 'captions');
      final multiToken = scoreSpotlightQuery(subtitleEntry, 'subtitle font');
      final miss = scoreSpotlightQuery(subtitleEntry, 'subtitle bluetooth');

      expect(exact, greaterThan(prefix));
      expect(prefix, greaterThan(keyword));
      expect(multiToken, greaterThan(0));
      expect(miss, -1);
    });
  });

  group('UniversalSpotlightBubble & Ctrl + Space shortcut', () {
    Future<void> sendCtrlSpace(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('landscape iOS Spotlight stays usable above the software keyboard', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(667, 375);
      tester.view.viewInsets = const FakeViewPadding(bottom: 225);
      addTearDown(() {
        tester.view.resetViewInsets();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigator,
            theme: monoTheme(MonoPalette.dark).copyWith(platform: TargetPlatform.iOS),
            home: const Scaffold(body: SizedBox(key: ValueKey('spotlight_host'))),
          ),
        ),
      );
      final route = buildSpotlightRoute(
        hostContext: tester.element(find.byKey(const ValueKey('spotlight_host'))),
        hostNavigator: navigator.currentState!,
        initialQuery: 'unmatched query',
      );
      navigator.currentState!.push(route);
      await tester.pumpAndSettle();

      final bubble = find.byType(UniversalSpotlightBubble);
      for (final label in [t.common.clear, t.common.close]) {
        final button = find.descendant(of: bubble, matching: find.byTooltip(label));
        expect(tester.getSize(button), const Size(44, 44));
        expect(tester.getBottomRight(button).dy, lessThanOrEqualTo(150));
      }
      expect(tester.takeException(), isNull);

      await tester.tap(find.descendant(of: bubble, matching: find.byTooltip(t.common.close)));
      await tester.pumpAndSettle();
      expect(bubble, findsNothing);
    });

    testWidgets('Ctrl + Space toggles Universal Spotlight open/closed and Escape dismisses it', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final profileStack = await ProfileStack.create();
      addTearDown(profileStack.dispose);

      final client = _FakeSearchClient();
      final multi = testMultiServer(clients: [client]);
      final libraries = LibrariesProvider()..initialize(multi.provider.aggregationService);
      await libraries.loadLibraries();
      final hidden = HiddenLibrariesProvider();
      addTearDown(libraries.dispose);
      addTearDown(hidden.dispose);

      final navigatorKey = GlobalKey<NavigatorState>();
      final routeTracker = SpotlightRouteTracker();
      final controller = SpotlightController();

      await tester.pumpWidget(
        TranslationProvider(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: profileStack.active),
              ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
              ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
              ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
            ],
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: SpotlightScope(
                controller: controller,
                child: SpotlightShortcut(
                  navigatorKey: navigatorKey,
                  routeTracker: routeTracker,
                  controller: controller,
                  child: Navigator(
                    key: navigatorKey,
                    observers: [routeTracker],
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Center(child: Text('Shell Body'))),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(UniversalSpotlightBubble), findsNothing);

      // Open with Ctrl + Space
      await sendCtrlSpace(tester);
      expect(find.byType(UniversalSpotlightBubble), findsOneWidget);
      expect(routeTracker.isSpotlightOpen, isTrue);

      // Toggle closed with Ctrl + Space
      await sendCtrlSpace(tester);
      expect(find.byType(UniversalSpotlightBubble), findsNothing);
      expect(routeTracker.isSpotlightOpen, isFalse);

      // Reopen with Ctrl + Space, then dismiss with Escape
      await sendCtrlSpace(tester);
      expect(find.byType(UniversalSpotlightBubble), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(UniversalSpotlightBubble), findsNothing);
    });

    testWidgets('searches libraries, quick actions, settings, and remote movies/shows, activating via Enter', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final profileStack = await ProfileStack.create();
      addTearDown(profileStack.dispose);

      final movieItem = testMediaItem(
        id: 'mov-1',
        backend: MediaBackend.plex,
        kind: MediaKind.movie,
        title: 'Your Name',
        year: 2016,
        serverId: 'srv-1',
        serverName: 'Home Server',
        libraryId: 'lib-anime',
        libraryTitle: 'Anime Movies',
      );
      final showItem = testMediaItem(
        id: 'show-1',
        backend: MediaBackend.plex,
        kind: MediaKind.show,
        title: 'Severance',
        year: 2022,
        serverId: 'srv-1',
        serverName: 'Home Server',
        libraryId: 'lib-shows',
        libraryTitle: 'Sci-Fi Shows',
      );

      final director = MediaPerson(
        id: 'person-1',
        name: 'Makoto Shinkai',
        credit: PersonCredit.director,
        backend: MediaBackend.plex,
        serverId: ServerId('srv-1'),
        serverName: 'Home Server',
      );

      final client = _FakeSearchClient(items: [movieItem, showItem], people: [director]);
      final multi = testMultiServer(clients: [client]);
      final libraries = LibrariesProvider()..initialize(multi.provider.aggregationService);
      await libraries.loadLibraries();
      final hidden = HiddenLibrariesProvider();
      addTearDown(libraries.dispose);
      addTearDown(hidden.dispose);

      String? selectedLibraryKey;
      var openedDownloads = false;

      final navigatorKey = GlobalKey<NavigatorState>();
      final routeTracker = SpotlightRouteTracker();
      final controller = SpotlightController()
        ..callbacksProvider = () => SpotlightShellCallbacks(
          onSelectHome: () {},
          onSelectLibrary: (key) => selectedLibraryKey = key,
          onOpenDownloads: () => openedDownloads = true,
          onOpenSettings: () {},
        );

      await tester.pumpWidget(
        TranslationProvider(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: profileStack.active),
              ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
              ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
              ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
            ],
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: SpotlightScope(
                controller: controller,
                child: SpotlightShortcut(
                  navigatorKey: navigatorKey,
                  routeTracker: routeTracker,
                  controller: controller,
                  child: Navigator(
                    key: navigatorKey,
                    observers: [routeTracker],
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Center(child: Text('Shell Body'))),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Open Spotlight and activate a library ("Anime Movies") via keyboard Enter
      await sendCtrlSpace(tester);
      await tester.enterText(find.byType(TextField), 'Anime Movies');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(find.text('Anime Movies'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selectedLibraryKey, 'srv-1:lib-anime');

      // 2. Open Spotlight and activate Downloads quick action
      await sendCtrlSpace(tester);
      await tester.enterText(find.byType(TextField), t.spotlight.actions.openDownloads);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(openedDownloads, isTrue);

      // 3. Open Spotlight and verify remote media ("Severance"), people ("Makoto Shinkai"), + Settings ("Subtitle") appear
      await sendCtrlSpace(tester);
      await tester.enterText(find.byType(TextField), 'Severance');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(ListView), matching: find.text('Severance')), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Makoto Shinkai');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(ListView), matching: find.text('Makoto Shinkai')), findsOneWidget);

      await tester.enterText(find.byType(TextField), t.settings.subtitleStyling);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(ListView), matching: find.text(t.settings.subtitleStyling)),
        findsOneWidget,
      );
    });

    testWidgets(
      'smooth wheel scrolling interpolates frames and arrow keys scroll past bottom cleanly without phantom overflow taps',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1440, 900);
        addTearDown(() {
          tester.view.resetDevicePixelRatio();
          tester.view.resetPhysicalSize();
        });

        final profileStack = await ProfileStack.create();
        addTearDown(profileStack.dispose);

        final client = _FakeSearchClient();
        final multi = testMultiServer(clients: [client]);
        final libraries = LibrariesProvider()..initialize(multi.provider.aggregationService);
        await libraries.loadLibraries();
        final hidden = HiddenLibrariesProvider();
        addTearDown(libraries.dispose);
        addTearDown(hidden.dispose);

        String? selectedLibraryKey;
        final navigatorKey = GlobalKey<NavigatorState>();
        final routeTracker = SpotlightRouteTracker();
        final controller = SpotlightController()
          ..callbacksProvider = () => SpotlightShellCallbacks(
            onSelectHome: () {},
            onSelectLibrary: (key) => selectedLibraryKey = key,
            onOpenDownloads: () {},
            onOpenSettings: () {},
          );

        await tester.pumpWidget(
          TranslationProvider(
            child: MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: profileStack.active),
                ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
                ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
                ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
              ],
              child: MaterialApp(
                theme: monoTheme(MonoPalette.dark),
                home: SpotlightScope(
                  controller: controller,
                  child: SpotlightShortcut(
                    navigatorKey: navigatorKey,
                    routeTracker: routeTracker,
                    controller: controller,
                    child: Navigator(
                      key: navigatorKey,
                      observers: [routeTracker],
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => const Scaffold(body: Center(child: Text('Shell Body'))),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await sendCtrlSpace(tester);
        final listFinder = find.byType(ListView);
        expect(listFinder, findsOneWidget);

        ScrollPosition listPosition() =>
            tester.state<ScrollableState>(find.descendant(of: listFinder, matching: find.byType(Scrollable))).position;

        expect(listPosition().pixels, 0.0);
        expect(listPosition().maxScrollExtent, greaterThan(400.0));

        // 1. Smooth mouse wheel scroll interpolates gradually across frames instead of jumping in 1 frame
        final listCenter = tester.getCenter(listFinder);
        final pointer = TestPointer(7, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(listCenter));
        await tester.pump();
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 220)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        final midWheelOffset = listPosition().pixels;
        expect(midWheelOffset, greaterThan(5.0));
        expect(midWheelOffset, lessThan(215.0));
        await tester.pumpAndSettle();
        expect(listPosition().pixels, closeTo(220.0, 0.5));

        // Reset back to top via Tab -> Shift+Tab or reopen
        await sendCtrlSpace(tester);
        await sendCtrlSpace(tester);
        expect(listPosition().pixels, 0.0);

        // Park mouse cursor over the second visible row; stationary cursor must NOT hijack ArrowDown!
        await tester.sendEventToBinding(pointer.hover(listCenter));
        await tester.pump();

        // 2. Press ArrowDown 100 times (well past total item count) — list scrolls all the way to maxScrollExtent
        for (var i = 0; i < 100; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump(const Duration(milliseconds: 8));
        }
        await tester.pumpAndSettle();
        expect(listPosition().pixels, closeTo(listPosition().maxScrollExtent, 1.0));

        // 3. Even after 30+ extra ArrowDown taps at the very bottom, ONE single ArrowUp immediately moves selection up!
        // Verify by checking which row currently shows the '↵' keycap badge before and after 1 ArrowUp press.
        Finder selectedKeycap() => find.descendant(of: listFinder, matching: find.text('↵'));
        expect(selectedKeycap(), findsOneWidget);
        final bottomKeycapY = tester.getCenter(selectedKeycap()).dy;

        // Tap ArrowDown 15 MORE times at the bottom
        for (var i = 0; i < 15; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump(const Duration(milliseconds: 8));
        }
        await tester.pumpAndSettle();
        expect(tester.getCenter(selectedKeycap()).dy, closeTo(bottomKeycapY, 0.5));

        // ONE single ArrowUp must immediately move the selected '↵' row upward by one row!
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(tester.getCenter(selectedKeycap()).dy, lessThan(bottomKeycapY - 30.0));

        // 4. Clicking a row with the mouse still activates cleanly through _SpotlightWheelRegion
        await tester.enterText(find.byType(TextField), 'Anime Movies');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(of: listFinder, matching: find.text('Anime Movies')));
        await tester.pumpAndSettle();
        expect(selectedLibraryKey, 'srv-1:lib-anime');
      },
    );
  });
}
