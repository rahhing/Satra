import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/i18n/strings.g.dart';
import 'package:satra/providers/theme_provider.dart';
import 'package:satra/providers/catalog_sources_provider.dart';
import 'package:satra/screens/settings/appearance_settings_screen.dart';
import 'package:satra/screens/settings/theme_settings_screen.dart';
import 'package:satra/services/settings_service.dart' hide ThemeMode;
import 'package:satra/services/settings_service.dart' as settings show ThemeMode;
import 'package:satra/services/supporter/supporter_mode.dart';
import 'package:satra/services/supporter/supporter_service.dart';
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/utils/platform_detector.dart';
import 'package:satra/utils/desktop_ui_scale.dart';
import 'package:satra/widgets/setting_tile.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  for (final (tv, platform) in [
    (false, TargetPlatform.linux),
    (true, TargetPlatform.linux),
    (false, TargetPlatform.android),
  ]) {
    testWidgets('Appearance controls save and reflect every choice: TV=$tv, $platform', (tester) async {
      TvDetectionService.debugSetAppleTVOverride(tv);
      addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 8000);
      addTearDown(tester.view.reset);
      final supporter = SupporterService.forTesting(availability: SupporterAvailability.hidden);
      final theme = ThemeProvider(supporter: supporter);
      final sources = _AppearanceCatalogSources();
      addTearDown(supporter.dispose);
      addTearDown(theme.dispose);
      addTearDown(sources.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>.value(value: theme),
            ChangeNotifierProvider<CatalogSourcesProvider>.value(value: sources),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark).copyWith(platform: platform),
            home: const AppearanceSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final switches = tester
          .widgetList<SettingSwitchTile>(find.byWidgetPredicate((widget) => widget is SettingSwitchTile))
          .toList();
      expect(switches.length, greaterThanOrEqualTo(10));
      for (final tile in switches) {
        final row = find.byWidgetPredicate((widget) => widget is SettingSwitchTile && widget.pref == tile.pref);
        final toggle = find.descendant(of: row, matching: find.byType(Switch));
        final original = SettingsService.instance.read(tile.pref);
        for (final next in [!original, original]) {
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(SettingsService.instance.prefs.getBool(tile.pref.key), next, reason: tile.title);
          expect(tester.widget<Switch>(toggle).value, next, reason: tile.title);
        }
      }

      Future<void> choose<T>(Pref<T> pref, List<T> values) async {
        final row = find.byWidgetPredicate((widget) => widget is SettingSegmentedTile<T> && widget.pref == pref);
        for (final value in values) {
          final tile = tester.widget<SettingSegmentedTile<T>>(row);
          final segment = tile.segments.singleWhere((segment) => segment.value == value);
          final label = (segment.label! as Text).data!;
          final changed = SettingsService.instance.read(pref) != value;
          await tester.tap(find.descendant(of: row, matching: find.text(label)));
          await tester.pumpAndSettle();
          expect(SettingsService.instance.read(pref), value, reason: '${pref.key} = $value');
          if (changed && value is Enum) expect(SettingsService.instance.prefs.getString(pref.key), value.name);
        }
      }

      await choose(SettingsService.viewMode, ViewMode.values);
      await choose(SettingsService.gridSpacing, GridSpacing.values);
      await choose(SettingsService.episodePosterMode, EpisodePosterMode.values);
      await choose(SettingsService.continueWatchingAction, ContinueWatchingAction.values);
      await choose(SettingsService.episodeAction, EpisodeAction.values);
      final densitySlider = find.descendant(
        of: find.byKey(const ValueKey('library_density')),
        matching: find.byType(Slider),
      );
      for (var density = LibraryDensity.min; density <= LibraryDensity.max; density++) {
        tester.widget<Slider>(densitySlider).onChanged!(density.toDouble());
        await tester.pumpAndSettle();
        expect(SettingsService.instance.prefs.getInt(SettingsService.libraryDensity.key), density);
        expect(tester.widget<Slider>(densitySlider).value, density.toDouble());
      }
      final opacityPref = tv ? SettingsService.spotlightArtworkOpacity : SettingsService.shelfHeadingHoverOpacity;
      final opacitySlider = find.descendant(of: find.byKey(ValueKey(opacityPref.key)), matching: find.byType(Slider));
      tester.widget<Slider>(opacitySlider).onChanged!(0.8);
      await tester.pumpAndSettle();
      expect(SettingsService.instance.prefs.getDouble(opacityPref.key), 0.8);
      expect(tester.widget<Slider>(opacitySlider).value, 0.8);

      if (!tv && platform == TargetPlatform.linux) {
        final scaleRow = find.byWidgetPredicate(
          (widget) => widget is SettingSelectionTile<double> && widget.pref == SettingsService.desktopUiScale,
        );
        for (final value in DesktopUiScale.options.reversed) {
          await tester.tap(scaleRow);
          await tester.pumpAndSettle();
          final label = value == DesktopUiScale.automatic
              ? t.settings.desktopScaleAutomatic
              : '${(value * 100).round()}%';
          final option = find.text(label).last;
          await tester.ensureVisible(option);
          await tester.pumpAndSettle();
          await tester.tap(option);
          await tester.pumpAndSettle();
          expect(SettingsService.instance.read(SettingsService.desktopUiScale), value);
        }
      }
    });
  }

  testWidgets('appearance screen renders every reorganized group', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 3000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final supporter = SupporterService.forTesting(availability: SupporterAvailability.hidden);
    addTearDown(supporter.dispose);
    final theme = ThemeProvider(supporter: supporter);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>.value(
        value: theme,
        child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const AppearanceSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    for (final group in [
      t.settings.display,
      t.settings.libraryAndCards,
      t.settings.homeScreen,
      t.settings.navigation,
    ]) {
      expect(find.text(group), findsOneWidget, reason: 'group $group missing');
    }
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text(t.settings.liveTv), 500, scrollable: scrollable);
    expect(find.text(t.settings.liveTvDefaultFavorites), findsOneWidget);
    // Moved away: profile prompt and performance overlay no longer live here.
    expect(find.text(t.settings.requireProfileSelectionOnOpen), findsNothing);
    expect(find.text(t.settings.autoHidePerformanceOverlay), findsNothing);
  });

  testWidgets('the Theme entry opens the theme picker and a pick applies live', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 3000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final supporter = SupporterService.forTesting(availability: SupporterAvailability.free);
    addTearDown(supporter.dispose);
    final theme = ThemeProvider(supporter: supporter);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SupporterService>.value(value: supporter),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
        ],
        child: Consumer<ThemeProvider>(
          builder: (_, provider, _) => MaterialApp(
            theme: provider.lightTheme,
            darkTheme: provider.darkTheme,
            themeMode: provider.materialThemeMode,
            home: const AppearanceSettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.settings.theme));
    await tester.pumpAndSettle();
    expect(find.byType(ThemeSettingsScreen), findsOneWidget);

    await tester.tap(find.text(t.settings.plumTheme));
    await tester.pumpAndSettle();

    expect(SettingsService.instance.read(SettingsService.themeMode), settings.ThemeMode.plum);
    expect(theme.themeMode, settings.ThemeMode.plum);
    final screenTheme = Theme.of(tester.element(find.byType(ThemeSettingsScreen)));
    expect(screenTheme.scaffoldBackgroundColor, MonoPalette.plum.bg);
    expect(screenTheme.colorScheme.primary, MonoPalette.plum.accent);

    await tester.pageBack();
    await tester.pumpAndSettle();
    // Back on Appearance, the entry's subtitle names the active preset.
    expect(
      find.descendant(of: find.byType(AppearanceSettingsScreen), matching: find.text(t.settings.plumTheme)),
      findsOneWidget,
    );
  });

  testWidgets('Display group swaps Blur Amount & Background Brightness with Liquid Glass Opacity (non-macOS default)', (
    tester,
  ) async {
    PlatformDetector.debugSetIsMacOSOverride(false);
    addTearDown(() => PlatformDetector.debugSetIsMacOSOverride(null));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 3000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final supporter = SupporterService.forTesting(availability: SupporterAvailability.free);
    addTearDown(supporter.dispose);
    final theme = ThemeProvider(supporter: supporter);
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SupporterService>.value(value: supporter),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
        ],
        child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const AppearanceSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Liquid Glass defaults OFF on non-macOS -> Blur Amount (100%) & Background Brightness (100%) are shown.
    expect(find.byKey(const ValueKey('glass_blur_amount')), findsOneWidget);
    expect(find.byKey(const ValueKey('glass_background_brightness')), findsOneWidget);
    expect(find.byKey(const ValueKey('liquid_glass_opacity')), findsNothing);
    expect(SettingsService.instance.read(SettingsService.glassBlurAmount), 1.0);
    expect(SettingsService.instance.read(SettingsService.glassBackgroundBrightness), 1.0);

    final blurSlider = find.descendant(
      of: find.byKey(const ValueKey('glass_blur_amount')),
      matching: find.byType(Slider),
    );
    tester.widget<Slider>(blurSlider).onChanged!(1.5);
    await tester.pumpAndSettle();
    expect(SettingsService.instance.read(SettingsService.glassBlurAmount), 1.5);
    expect(find.text('150%'), findsOneWidget);

    final brightnessSlider = find.descendant(
      of: find.byKey(const ValueKey('glass_background_brightness')),
      matching: find.byType(Slider),
    );
    tester.widget<Slider>(brightnessSlider).onChanged!(0.75);
    await tester.pumpAndSettle();
    expect(SettingsService.instance.read(SettingsService.glassBackgroundBrightness), 0.75);
    expect(find.text('75%'), findsOneWidget);

    // Toggle Liquid Glass ON -> Liquid Glass Opacity (20% default on non-macOS) replaces them.
    await tester.tap(find.text(t.settings.liquidGlass));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('liquid_glass_opacity')), findsOneWidget);
    expect(find.byKey(const ValueKey('glass_blur_amount')), findsNothing);
    expect(find.byKey(const ValueKey('glass_background_brightness')), findsNothing);
    expect(SettingsService.instance.read(SettingsService.liquidGlassOpacity), 0.20);
    expect(find.text('20%'), findsOneWidget);

    final opacitySlider = find.descendant(
      of: find.byKey(const ValueKey('liquid_glass_opacity')),
      matching: find.byType(Slider),
    );
    tester.widget<Slider>(opacitySlider).onChanged!(0.45);
    await tester.pumpAndSettle();
    expect(SettingsService.instance.read(SettingsService.liquidGlassOpacity), 0.45);
    expect(find.text('45%'), findsOneWidget);
  });

  testWidgets('macOS defaults Liquid Glass ON at 65% opacity in Display group', (tester) async {
    PlatformDetector.debugSetIsMacOSOverride(true);
    addTearDown(() => PlatformDetector.debugSetIsMacOSOverride(null));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 3000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final supporter = SupporterService.forTesting(availability: SupporterAvailability.free);
    addTearDown(supporter.dispose);
    final theme = ThemeProvider(supporter: supporter);
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SupporterService>.value(value: supporter),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
        ],
        child: MaterialApp(theme: monoTheme(MonoPalette.oled), home: const AppearanceSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(SettingsService.instance.read(SettingsService.liquidGlass), isTrue);
    expect(SettingsService.instance.read(SettingsService.liquidGlassOpacity), 0.65);
    expect(SettingsService.instance.read(SettingsService.themeMode), settings.ThemeMode.oled);
    expect(find.byKey(const ValueKey('liquid_glass_opacity')), findsOneWidget);
    expect(find.text('65%'), findsOneWidget);
    expect(find.byKey(const ValueKey('glass_blur_amount')), findsNothing);
    expect(find.byKey(const ValueKey('glass_background_brightness')), findsNothing);
  });
}

class _AppearanceCatalogSources extends CatalogSourcesProvider {
  @override
  bool get hasAnySource => true;
}
