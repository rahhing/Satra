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

  test('handheld iOS defaults enable native Liquid Glass, Desktop-matched 0.65 opacity, and 14dp squircle card corners', () async {
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
  });

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

  testWidgets('GlassSurface mounts UiKitView(com.satra/ios_glass_surface) with interactive flag and press progress on iOS', (
    tester,
  ) async {
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

  testWidgets('MobileGlassTabBar switches tabs, scrubs horizontally across tabs, triggers reselect scroll-to-top, and opens Search orb', (
    tester,
  ) async {
    TvDetectionService.debugSetAppleTVOverride(false);
    await SettingsService.getInstance();

    final tabs = NavigationTab.getVisibleTabs(isOffline: false, hasLiveTv: false, hasExplore: true)
        .where((tab) => tab.id != NavigationTabId.settings)
        .toList();

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
                  padding: const EdgeInsets.all(16),
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

    await tester.tap(find.byKey(const ValueKey('mobile_glass_search_orb')));
    await tester.pump();
    expect(searchOpened, 1);
  });

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

  testWidgets('AppBarBackButton and CircularControlButton render interactive Liquid Glass orbs over video on handheld iOS', (
    tester,
  ) async {
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
                  AppBarBackButton(
                    style: BackButtonStyle.video,
                    onPressed: () => backPressed++,
                  ),
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
  });
}
