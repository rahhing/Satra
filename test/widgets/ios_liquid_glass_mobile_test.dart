import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:satra/focus/input_mode_tracker.dart';
import 'package:satra/i18n/strings.g.dart';
import 'package:satra/navigation/navigation_tabs.dart';
import 'package:satra/services/settings_service.dart' hide ThemeMode;
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/utils/platform_detector.dart';
import 'package:satra/utils/scroll_to_top.dart';
import 'package:satra/widgets/app_bar_back_button.dart';
import 'package:satra/widgets/glass_surface.dart';
import 'package:satra/widgets/ios_glass_control.dart';
import 'package:satra/widgets/mobile_glass_tab_bar.dart';
import 'package:satra/widgets/video_controls/widgets/circular_control_button.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsMacOSOverride(null);
    PlatformDetector.debugSetIsIOSOverride(null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    GlassSurface.debugEnableIOSNativeGlass = null;
  });

  tearDown(() {
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsMacOSOverride(null);
    PlatformDetector.debugSetIsIOSOverride(null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    GlassSurface.debugEnableIOSNativeGlass = null;
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'handheld iOS defaults enable native Liquid Glass, Desktop-matched 0.65 opacity, and 14dp squircle card corners',
    () async {
      PlatformDetector.debugSetIsDesktopOSOverride(false);
      PlatformDetector.debugSetIsMacOSOverride(false);
      PlatformDetector.debugSetIsIOSOverride(true);
      TvDetectionService.debugSetAppleTVOverride(false);

      final settings = await SettingsService.getInstance();
      expect(settings.read(SettingsService.forceTvMode), isFalse);
      expect(settings.read(SettingsService.liquidGlass), isTrue);
      expect(settings.read(SettingsService.liquidGlassOpacity), closeTo(0.65, 0.001));
      expect(settings.read(SettingsService.pillCornerRadius), 14);
      expect(settings.read(SettingsService.gridSpacing), GridSpacing.normal);
    },
  );

  test('Apple TV keeps TV mode and non-handheld defaults even on iOS kernel family', () async {
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    PlatformDetector.debugSetIsMacOSOverride(false);
    PlatformDetector.debugSetIsIOSOverride(true);
    TvDetectionService.debugSetAppleTVOverride(true);

    final settings = await SettingsService.getInstance();
    expect(PlatformDetector.isHandheldAppleMobile(), isFalse);
    expect(settings.read(SettingsService.liquidGlass), isFalse);
    expect(settings.read(SettingsService.pillCornerRadius), 32);
    expect(settings.read(SettingsService.gridSpacing), GridSpacing.spacious);
  });

  testWidgets('GlassSurface mounts the native UIKit material with the requested geometry on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    PlatformDetector.debugSetIsIOSOverride(true);
    TvDetectionService.debugSetAppleTVOverride(false);
    GlassSurface.debugEnableIOSNativeGlass = true;

    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.liquidGlass, true);

    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.oled, cornerRadius: 14),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              height: 60,
              child: GlassSurface(
                interactive: true,
                borderRadius: BorderRadius.all(Radius.circular(999)),
                child: Center(child: Text('Home')),
              ),
            ),
          ),
        ),
      ),
    );

    final uiKitViewFinder = find.byType(UiKitView);
    expect(uiKitViewFinder, findsOneWidget);
    final uiKitView = tester.widget<UiKitView>(uiKitViewFinder);
    expect(uiKitView.viewType, 'com.satra/ios_glass_surface');
    final params = uiKitView.creationParams! as Map<String, Object>;
    expect(params['liquidGlass'], isTrue);
    expect(params['interactive'], isTrue);
    expect(params['tl'], 999.0);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('native iOS tab and Search controls dispatch their own actions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TvDetectionService.debugSetAppleTVOverride(false);
    GlassSurface.debugEnableIOSNativeGlass = true;
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.liquidGlass, true);

    NavigationTabId? selected;
    var reselected = 0;
    var librariesHeld = 0;
    var searchOpened = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: monoTheme(MonoPalette.oled).copyWith(platform: TargetPlatform.iOS),
          home: Scaffold(
            bottomNavigationBar: MobileGlassTabBar(
              tabs: NavigationTab.getVisibleTabs(isOffline: false),
              selectedTab: NavigationTabId.discover,
              hideLabels: false,
              onDestinationSelected: (value) => selected = value,
              onActiveTabReselected: () => reselected++,
              onLibrariesLongPress: () => librariesHeld++,
              onSearchPressed: () => searchOpened++,
            ),
          ),
        ),
      ),
    );

    final controls = tester.widgetList<IOSGlassControl>(find.byType(IOSGlassControl)).toList();
    expect(controls.map((control) => control.configuration['kind']), ['tabBar', 'button']);
    final [tabBar, search] = controls;
    expect(search.configuration['symbol'], 'magnifyingglass');
    expect(search.configuration['symbolSize'], 21);
    expect(search.configuration['regularSymbolWeight'], isTrue);
    expect(tester.getSize(find.byWidget(tabBar)).height, greaterThanOrEqualTo(72));
    expect(tester.getRect(find.byWidget(tabBar)).right, lessThan(tester.getRect(find.byWidget(search)).left));
    tabBar.onAction('selected', NavigationTabId.discover.name);
    tabBar.onAction('selected', NavigationTabId.libraries.name);
    tabBar.onAction('librariesHeld', null);
    search.onAction('pressed', null);
    expect((selected, reselected, librariesHeld, searchOpened), (NavigationTabId.libraries, 1, 1, 1));

    await settings.write(SettingsService.liquidGlass, false);
    await tester.pumpAndSettle();
    expect(find.byType(IOSGlassControl), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'MobileGlassTabBar switches tabs, scrubs horizontally across tabs, triggers reselect scroll-to-top, and opens Search orb',
    (tester) async {
      TvDetectionService.debugSetAppleTVOverride(false);
      await SettingsService.getInstance();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(375, 812);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final tabs = NavigationTab.getVisibleTabs(
        isOffline: false,
        hasLiveTv: true,
        hasExplore: true,
      ).where((tab) => tab.id != NavigationTabId.settings).toList();

      NavigationTabId selected = NavigationTabId.discover;
      var librariesLongPressed = 0;
      var reselected = 0;
      var searchOpened = 0;

      await tester.pumpWidget(
        TranslationProvider(
          child: StatefulBuilder(
            builder: (context, setState) {
              return MaterialApp(
                theme: monoTheme(MonoPalette.oled, cornerRadius: 14).copyWith(platform: TargetPlatform.iOS),
                home: Scaffold(
                  bottomNavigationBar: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
                    child: MobileGlassTabBar(
                      tabs: tabs,
                      selectedTab: selected,
                      hideLabels: false,
                      onDestinationSelected: (next) => setState(() => selected = next),
                      onActiveTabReselected: () => reselected++,
                      onLibrariesLongPress: () => librariesLongPressed++,
                      onSearchPressed: () => searchOpened++,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final glass = tester.widgetList<GlassSurface>(find.byType(GlassSurface)).toList();
      expect(glass, hasLength(2));
      expect(glass.last.interactive, glass.first.interactive);
      expect(glass.last.tint, glass.first.tint);
      expect(glass.last.opacity, glass.first.opacity);
      expect(glass.last.sigma, glass.first.sigma);
      final searchOrb = find.byKey(const ValueKey('mobile_glass_search_orb'));
      final glassBounds = tester.getRect(find.byWidget(glass.first));
      expect(tester.getRect(searchOrb).left - glassBounds.right, greaterThan(0));
      expect(glassBounds.width / tabs.length, greaterThan(54));

      // Re-tapping active Home tab invokes scroll-to-top callback.
      await tester.tap(find.text(t.common.home));
      await tester.pumpAndSettle();
      expect(reselected, 1);

      // Tapping Libraries switches tabs.
      await tester.tap(find.text(t.navigation.libraries));
      await tester.pumpAndSettle();
      expect(selected, NavigationTabId.libraries);

      // Holding stationary on Libraries fires quick-picker long-press.
      await tester.longPress(find.text(t.navigation.libraries));
      await tester.pump();
      expect(librariesLongPressed, 1);

      // Dragging horizontally across the capsule scrubs the Liquid Glass loupe to Explore.
      final homeCenter = tester.getCenter(find.text(t.common.home));
      final exploreCenter = tester.getCenter(find.text(t.navigation.explore));
      final gesture = await tester.startGesture(homeCenter);
      await tester.pump(const Duration(milliseconds: 80));
      await gesture.moveTo(exploreCenter);
      await tester.pump(const Duration(milliseconds: 50));
      expect(selected, NavigationTabId.explore);
      await gesture.up();
      await tester.pumpAndSettle();

      // A vertical swipe over the bar should never select the tab beneath it.
      final verticalGesture = await tester.startGesture(homeCenter);
      await verticalGesture.moveBy(const Offset(0, -48));
      await verticalGesture.up();
      await tester.pumpAndSettle();
      expect(selected, NavigationTabId.explore);

      await tester.tap(searchOrb);
      await tester.pump();
      expect(searchOpened, 1);
    },
  );

  testWidgets('smoothScrollToTop dynamically animates deep scroll offsets back to 0', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: 300,
            itemExtent: 80,
            itemBuilder: (_, i) => Text('Row $i'),
          ),
        ),
      ),
    );

    controller.jumpTo(9600);
    await tester.pump();
    expect(controller.offset, 9600);

    final scrollFuture = smoothScrollToTop(controller);
    await tester.pump();
    await tester.pumpAndSettle();
    await scrollFuture;

    expect(controller.offset, closeTo(0.0, 0.5));
  });

  testWidgets(
    'AppBarBackButton and CircularControlButton render interactive Liquid Glass orbs over video on handheld iOS',
    (tester) async {
      TvDetectionService.debugSetAppleTVOverride(false);
      await SettingsService.getInstance();

      var backPressed = 0;
      var playPressed = 0;

      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(
              theme: monoTheme(MonoPalette.oled, cornerRadius: 14).copyWith(platform: TargetPlatform.iOS),
              home: Scaffold(
                body: Column(
                  children: [
                    AppBarBackButton(style: BackButtonStyle.video, onPressed: () => backPressed++),
                    CircularControlButton(
                      semanticLabel: 'Play',
                      icon: Symbols.play_arrow_rounded,
                      iconSize: 72,
                      onPressed: () => playPressed++,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final backGlass = find.descendant(of: find.byType(AppBarBackButton), matching: find.byType(GlassSurface));
      expect(backGlass, findsOneWidget);
      expect(tester.widget<GlassSurface>(backGlass).interactive, isTrue);
      expect(tester.widget<GlassSurface>(backGlass).blurNativeVideo, isTrue);

      final playGlass = find.descendant(of: find.byType(CircularControlButton), matching: find.byType(GlassSurface));
      expect(playGlass, findsOneWidget);
      expect(tester.widget<GlassSurface>(playGlass).interactive, isTrue);
      expect(tester.widget<GlassSurface>(playGlass).blurNativeVideo, isTrue);

      await tester.tap(find.byType(AppBarBackButton));
      await tester.tap(find.byType(CircularControlButton));
      await tester.pump();
      expect(backPressed, 1);
      expect(playPressed, 1);
    },
  );
}
