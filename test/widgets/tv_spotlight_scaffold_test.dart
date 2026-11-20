import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/media/media_backend.dart';
import 'package:satra/media/media_hub.dart';
import 'package:satra/media/media_item.dart';
import 'package:satra/media/media_kind.dart';
import 'package:satra/services/settings_service.dart';
import 'package:satra/utils/platform_detector.dart';
import 'package:satra/widgets/spotlight_artwork.dart';
import 'package:satra/widgets/tv_spotlight_background.dart';
import 'package:satra/widgets/tv_spotlight_scaffold.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

MediaItem _item(String id) => testMediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, title: id);

MediaHub _hub(String id, List<MediaItem> items) =>
    MediaHub(id: id, title: id, type: 'movie', size: items.length, items: items);

void main() {
  testWidgets('desktop TV layout applies backdrop darkness and can restore classic artwork', (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    await TvDetectionService.getInstance(forceTv: true);
    addTearDown(TvDetectionService.debugReset);
    await settings.write(SettingsService.tvCornerSpotlightBackdrop, false);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(platform: TargetPlatform.macOS),
        home: const Scaffold(body: TvSpotlightBackground(item: null, client: null)),
      ),
    );

    final blur = find.byKey(const ValueKey('spotlight_blurred_fill'));
    Color? shade() => tester.widget<SpotlightArtwork>(find.byType(SpotlightArtwork)).blurShade;
    expect(blur, findsOneWidget);
    expect(shade()?.a, 0.5);
    await settings.write(SettingsService.mobileBackdropDarkness, 0.8);
    await tester.pump();
    expect(shade()?.a, 0.8);
    await settings.write(SettingsService.darkenMobileBackdrop, false);
    await tester.pump();
    expect(shade()?.a, 0);
    expect(blur, findsOneWidget);
    await settings.write(SettingsService.useClassicMobileBackdrop, true);
    await tester.pump();
    expect(shade(), isNull);
    expect(blur, findsNothing);
  });

  test('spotlight controller cancels an intermediate debounced selection', () async {
    final first = _item('first');
    final second = _item('second');
    final controller = TvSpotlightController(settleDelay: const Duration(milliseconds: 10));
    addTearDown(controller.dispose);
    controller.value = first;

    controller.select(second);
    controller.select(first);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.value, same(first));
  });

  test('spotlight controller resolves valid selection or first hub item', () {
    final first = _item('first');
    final second = _item('second');
    final controller = TvSpotlightController(settleDelay: Duration.zero);
    addTearDown(controller.dispose);
    final hubs = [
      _hub('one', [first]),
      _hub('two', [second]),
    ];

    expect(controller.resolve(hubs), same(first));
    controller.select(second);
    expect(controller.resolve(hubs), same(second));

    controller.value = _item('removed');
    expect(controller.resolve(hubs), same(first));
  });

  test('spotlight controller resolves the latest item instance for a retained selection', () {
    final stale = _item('same');
    final refreshed = testMediaItem(id: 'same', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Updated');
    final controller = TvSpotlightController(settleDelay: Duration.zero);
    addTearDown(controller.dispose);
    controller.value = stale;

    expect(
      controller.resolve([
        _hub('one', [refreshed]),
      ]),
      same(refreshed),
    );
  });
}
