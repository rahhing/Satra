import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/focus/locked_hub_controller.dart';
import 'package:satra/media/media_hub.dart';
import 'package:satra/media/media_item.dart';
import 'package:satra/media/media_kind.dart';
import 'package:satra/services/settings_service.dart';
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/utils/platform_detector.dart';
import 'package:satra/widgets/hub_section.dart';
import 'package:satra/widgets/media_grid_delegate.dart';
import 'package:satra/widgets/media_card.dart';
import 'package:satra/widgets/tv_browse_rail.dart';
import 'package:satra/widgets/tv_spotlight_background.dart';
import 'package:satra/widgets/tv_spotlight_scaffold.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });
  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  Widget app(Widget child) => MaterialApp(
    theme: monoTheme(MonoPalette.dark),
    home: Scaffold(body: child),
  );

  for (final rail in [false, true]) {
    testWidgets('server names update in ${rail ? 'TV rails' : 'recommendation hubs'}', (tester) async {
      final hub = MediaHub(id: 'movies', title: 'Movies', type: 'movie', size: 0, items: const [], serverName: 'Atlas');
      final focus = HubFocusMemory();
      final child = rail
          ? Align(
              alignment: Alignment.bottomCenter,
              child: TvBrowseRail(hubs: [hub], focusMemory: focus, iconForHub: (_, _) => Icons.movie),
            )
          : ListView(
              children: [HubSection(hub: hub, focusMemory: focus, icon: Icons.movie)],
            );
      await tester.pumpWidget(app(child));
      await tester.pumpAndSettle();
      expect(find.text('Atlas'), findsNothing);
      await SettingsService.instance.write(SettingsService.showServerNameOnHubs, true);
      await tester.pumpAndSettle();
      expect(find.text('Atlas'), findsOneWidget);
      await SettingsService.instance.write(SettingsService.showServerNameOnHubs, false);
      await tester.pumpAndSettle();
      expect(find.text('Atlas'), findsNothing);
    });
  }

  testWidgets('spotlight reserves the current rail height after appearance changes', (tester) async {
    tester.view.physicalSize = const Size(1600, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final item = testMediaItem(kind: MediaKind.movie, title: 'Movie');
    final hub = MediaHub(id: 'movies', title: 'Movies', type: 'movie', size: 1, items: [item]);
    final spotlight = ValueNotifier<MediaItem?>(item);
    addTearDown(spotlight.dispose);
    await SettingsService.instance.write(SettingsService.libraryDensity, LibraryDensity.min);
    await tester.pumpWidget(
      app(
        TvSpotlightScaffold(
          hubs: [hub],
          spotlightListenable: spotlight,
          resolveSpotlight: () => spotlight.value,
          resolveClient: (_) => null,
          foreground: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double bottom() => tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground)).contentBottom;
    final compact = bottom();
    await SettingsService.instance.write(SettingsService.libraryDensity, LibraryDensity.max);
    await tester.pumpAndSettle();
    final comfortable = bottom();
    expect(comfortable, greaterThan(compact));
    await SettingsService.instance.write(SettingsService.tvFullCardLayout, false);
    await tester.pumpAndSettle();
    expect(bottom(), isNot(comfortable));
  });

  testWidgets('all grid spacing choices affect square and full TV grids', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    for (final full in [false, true]) {
      final gaps = <double>[];
      for (final spacing in GridSpacing.values) {
        await SettingsService.instance.write(SettingsService.gridSpacing, spacing);
        gaps.add(MediaGridDelegate.spacingFor(context: context, fullBleedImage: full, shape: CardShape.square));
      }
      expect(gaps[1], greaterThan(gaps[0]));
      expect(gaps[2], greaterThan(gaps[1]));
    }
  });

  test('density steps remain distinct at wide and narrow viewport limits', () {
    for (final width in [480.0, 1920.0, 3840.0]) {
      for (final wide in [false, true]) {
        final widths = [
          for (var density = 1; density <= 5; density++)
            TvBrowseRailLayout.cardWidthFor(
              availableWidth: width,
              density: density,
              useWideLayout: wide,
              scale: 1,
              horizontalPadding: 24,
              itemGap: 6,
            ),
        ];
        for (var i = 1; i < widths.length; i++) {
          expect(widths[i], greaterThan(widths[i - 1]), reason: '$width px, wide=$wide, widths=$widths');
        }
      }
    }
  });

  for (final mode in ViewMode.values) {
    for (final implied in [false, true]) {
      testWidgets('episode number setting hides season and episode labels in $mode, implied=$implied', (tester) async {
        final item = testMediaItem(
          kind: MediaKind.episode,
          title: 'Episode title',
          grandparentTitle: 'Show',
          parentId: 'season',
          parentIndex: 2,
          index: 3,
        );
        await tester.pumpWidget(
          app(
            Center(
              child: SizedBox(
                width: 500,
                height: 350,
                child: MediaCard(item: item, viewModeOverride: mode, showTitleImplied: implied, isOffline: true),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('S2'), findsWidgets);
        await SettingsService.instance.write(SettingsService.showEpisodeNumberOnCards, false);
        await tester.pumpAndSettle();
        expect(find.textContaining('S2'), findsNothing);
        expect(find.textContaining('E3'), findsNothing);
        expect(find.text('Episode title'), findsWidgets);
        await SettingsService.instance.write(SettingsService.showEpisodeNumberOnCards, true);
        await tester.pumpAndSettle();
        expect(find.textContaining('S2'), findsWidgets);
      });
    }
  }
}
