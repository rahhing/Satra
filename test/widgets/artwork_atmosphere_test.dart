import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/media/media_backend.dart';
import 'package:satra/media/media_item.dart';
import 'package:satra/media/media_kind.dart';
import 'package:satra/widgets/artwork_atmosphere.dart';

MediaItem _movie(String id) =>
    MediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, artPath: '/art/$id', title: id);

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
}
