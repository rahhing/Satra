import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/media/media_backend.dart';
import 'package:satra/media/media_item.dart';
import 'package:satra/media/media_kind.dart';
import 'package:satra/services/settings_service.dart';
import 'package:satra/widgets/artwork_atmosphere.dart';

import '../test_helpers/prefs.dart';

MediaItem _movie(String id, {String? artPath, String? thumbPath}) => MediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  artPath: artPath ?? '/art/$id',
  thumbPath: thumbPath,
  title: id,
);

void main() {
  test('fast shelf navigation selects only the title the viewer settles on', () {
    fakeAsync((time) {
      final controller = ArtworkAtmosphereController();
      var changes = 0;
      controller.addListener(() => changes++);
      controller.select(_movie('first'));
      time.elapse(const Duration(milliseconds: 100));
      controller.select(_movie('second'));
      time.elapse(const Duration(milliseconds: 100));
      expect(controller.value, isNull);
      time.elapse(const Duration(milliseconds: 60));
      expect(controller.value?.id, 'second');
      expect(changes, 1);
      controller.select(_movie('second'));
      time.elapse(const Duration(seconds: 1));
      expect(changes, 1);
      controller.dispose();
    });
  });

  test('refreshed metadata with updated artwork paths replaces the same title', () {
    fakeAsync((time) {
      final controller = ArtworkAtmosphereController();
      var changes = 0;
      controller.addListener(() => changes++);
      controller.select(_movie('first', artPath: '/art/v1', thumbPath: '/thumb/v1'));
      time.elapse(const Duration(milliseconds: 200));
      expect(controller.value?.artPath, '/art/v1');
      expect(changes, 1);

      controller.select(_movie('first', artPath: '/art/v2', thumbPath: '/thumb/v2'));
      time.elapse(const Duration(milliseconds: 200));
      expect(controller.value?.artPath, '/art/v2');
      expect(controller.value?.thumbPath, '/thumb/v2');
      expect(changes, 2);
      controller.dispose();
    });
  });

  test('clearing a selection cancels pending artwork and disposal cancels work', () {
    fakeAsync((time) {
      final controller = ArtworkAtmosphereController();
      controller.select(_movie('first'));
      controller.select(null);
      time.elapse(const Duration(seconds: 1));
      expect(controller.value, isNull);
      controller.select(_movie('second'));
      controller.dispose();
      time.elapse(const Duration(seconds: 1));
      expect(time.nonPeriodicTimerCount, 0);
    });
  });

  testWidgets('host suppresses opaque backdrop while native video playback is active', (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    final suppressed = ValueNotifier<bool>(false);
    addTearDown(suppressed.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(platform: TargetPlatform.macOS),
        home: ArtworkAtmosphereHost(
          allowNetwork: false,
          suppressed: suppressed,
          child: const SizedBox.expand(),
        ),
      ),
    );
    expect(find.byType(ArtworkAtmosphere), findsOneWidget);

    suppressed.value = true;
    await tester.pump();
    expect(find.byType(ArtworkAtmosphere), findsNothing);

    suppressed.value = false;
    await tester.pump();
    expect(find.byType(ArtworkAtmosphere), findsOneWidget);
  });
}
