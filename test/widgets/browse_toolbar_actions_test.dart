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
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/utils/platform_detector.dart';
import 'package:satra/watch_together/watch_together.dart';
import 'package:satra/widgets/browse_toolbar_actions.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_stack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    TvDetectionService.debugReset();
    TvDetectionService.debugSetAppleTVOverride(false);
  });

  tearDown(() {
    TvDetectionService.debugReset();
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
}
