import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:satra/focus/focusable_action_bar.dart';
import 'package:satra/focus/input_mode_tracker.dart';
import 'package:satra/i18n/strings.g.dart';
import 'package:satra/navigation/main_screen_scope.dart';
import 'package:satra/profiles/active_profile_provider.dart';
import 'package:satra/providers/companion_remote_provider.dart';
import 'package:satra/providers/libraries_provider.dart';
import 'package:satra/providers/multi_server_provider.dart';
import 'package:satra/services/settings_service.dart' hide ThemeMode;
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/utils/platform_detector.dart';
import 'package:satra/watch_together/watch_together.dart';
import 'package:satra/widgets/browse_toolbar_actions.dart';
import 'package:satra/widgets/glass_surface.dart';
import 'package:satra/widgets/ios_glass_control.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_stack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    TvDetectionService.debugReset();
    TvDetectionService.debugSetAppleTVOverride(false);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    PlatformDetector.debugSetIsIOSOverride(null);
    GlassSurface.debugEnableIOSNativeGlass = null;
  });

  tearDown(() {
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    PlatformDetector.debugSetIsIOSOverride(null);
    GlassSurface.debugEnableIOSNativeGlass = null;
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop top bar renders Downloads, Settings, and Fullscreen right before Profile avatar', (
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

    final multi = testMultiServer();
    final libraries = LibrariesProvider();
    final watchTogether = WatchTogetherProvider();
    final remote = CompanionRemoteProvider();
    addTearDown(libraries.dispose);
    addTearDown(watchTogether.dispose);
    addTearDown(remote.dispose);

    var downloadsOpened = 0;
    var settingsOpened = 0;
    final actionBarKey = GlobalKey<FocusableActionBarState>();

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: profileStack.active),
            ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
            ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: remote),
          ],
          child: InputModeTracker(
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark).copyWith(platform: TargetPlatform.linux),
              home: MainScreenFocusScope(
                openDownloads: () => downloadsOpened++,
                openSettings: () => settingsOpened++,
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topRight,
                    child: BrowseToolbarActions(
                      actionBarKey: actionBarKey,
                      onRefresh: () {},
                      onNavigateLeft: () {},
                      onNavigateDown: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final downloadsFinder = find.byTooltip(t.navigation.downloads);
    final settingsFinder = find.byTooltip(t.common.settings);
    final fullscreenFinder = find.byTooltip(t.common.fullscreen);
    final profileFinder = find.byTooltip(t.profiles.sectionTitle);

    expect(downloadsFinder, findsOneWidget);
    expect(settingsFinder, findsOneWidget);
    expect(fullscreenFinder, findsOneWidget);
    expect(profileFinder, findsOneWidget);

    // Verify left-to-right order in the top-right bar: Downloads -> Settings -> Fullscreen -> Profile
    final downloadsX = tester.getCenter(downloadsFinder).dx;
    final settingsX = tester.getCenter(settingsFinder).dx;
    final fullscreenX = tester.getCenter(fullscreenFinder).dx;
    final profileX = tester.getCenter(profileFinder).dx;

    expect(downloadsX, lessThan(settingsX));
    expect(settingsX, lessThan(fullscreenX));
    expect(fullscreenX, lessThan(profileX));

    await tester.tap(downloadsFinder);
    await tester.pump();
    expect(downloadsOpened, 1);

    await tester.tap(settingsFinder);
    await tester.pump();
    expect(settingsOpened, 1);
  });

  testWidgets('handheld iOS top-right pill embeds a chromeless 3-dot menu flush with the profile avatar', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    PlatformDetector.debugSetIsIOSOverride(true);
    TvDetectionService.debugSetAppleTVOverride(false);
    GlassSurface.debugEnableIOSNativeGlass = true;

    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.liquidGlass, true);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final profileStack = await ProfileStack.create();
    addTearDown(profileStack.dispose);

    final multi = testMultiServer();
    final libraries = LibrariesProvider();
    final watchTogether = WatchTogetherProvider();
    final remote = CompanionRemoteProvider();
    addTearDown(libraries.dispose);
    addTearDown(watchTogether.dispose);
    addTearDown(remote.dispose);

    final actionBarKey = GlobalKey<FocusableActionBarState>();
    var refreshed = 0;

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: profileStack.active),
            ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
            ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: remote),
          ],
          child: InputModeTracker(
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark).copyWith(platform: TargetPlatform.iOS),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topRight,
                  child: GlassSurface(
                    key: const ValueKey('top_right_pill'),
                    interactive: true,
                    borderRadius: const BorderRadius.all(Radius.circular(999)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                      child: BrowseToolbarActions(
                        actionBarKey: actionBarKey,
                        onRefresh: () => refreshed++,
                        onNavigateLeft: () {},
                        onNavigateDown: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final moreGlass = find.byWidgetPredicate(
      (widget) => widget is IOSGlassControl && widget.configuration['symbol'] == 'ellipsis',
    );
    expect(moreGlass, findsOneWidget);
    final config = tester.widget<IOSGlassControl>(moreGlass).configuration;
    expect(config['chromeless'], isTrue);

    final pillRect = tester.getRect(find.byKey(const ValueKey('top_right_pill')));
    final moreRect = tester.getRect(moreGlass);
    final profileRect = tester.getRect(find.byTooltip(t.profiles.sectionTitle));

    expect(moreRect.size, const Size(40, 40));
    expect(profileRect.size, const Size(40, 40));
    expect(pillRect.height, 46);
    expect(moreRect.top, greaterThanOrEqualTo(pillRect.top));
    expect(moreRect.bottom, lessThanOrEqualTo(pillRect.bottom));
    expect(moreRect.left, greaterThanOrEqualTo(pillRect.left));
    expect(moreRect.center.dy, closeTo(profileRect.center.dy, 0.01));

    tester.widget<IOSGlassControl>(moreGlass).onAction('menuSelected', 'refresh');
    expect(refreshed, 1);
    debugDefaultTargetPlatformOverride = null;
  });
}
