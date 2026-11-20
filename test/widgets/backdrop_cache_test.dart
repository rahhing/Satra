import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:satra/services/backdrop_cache.dart';
import 'package:satra/services/image_cache_service.dart';
import 'package:satra/widgets/cycling_media_backdrop.dart';

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

class _CountingImage extends MemoryImage {
  _CountingImage(this.onLoad) : super(Uint8List.fromList(base64Decode(_png)));
  final VoidCallback onLoad;

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    onLoad();
    return super.loadImage(key, decode);
  }
}

void main() {
  Future<void> show(WidgetTester tester, BackdropCache cache, ImageProvider? provider) async {
    await tester.pumpWidget(
      Provider<BackdropCache>.value(
        value: cache,
        child: MaterialApp(
          home: provider == null
              ? const SizedBox()
              : CyclingMediaBackdrop(
                  mediaKey: provider,
                  imagePaths: const ['backdrop'],
                  client: null,
                  width: 32,
                  height: 32,
                  active: false,
                  imageProviderResolver: (_) => provider,
                  fallbackColor: Colors.black,
                ),
        ),
      ),
    );
    if (provider != null) {
      await tester.runAsync(() async {
        final ready = Completer<void>();
        final stream = provider.resolve(const ImageConfiguration());
        late final ImageStreamListener listener;
        listener = ImageStreamListener((info, _) {
          info.dispose();
          stream.removeListener(listener);
          ready.complete();
        });
        stream.addListener(listener);
        await ready.future;
      });
      await tester.pumpAndSettle();
    }
  }

  setUp(() {
    // Remove Flutter's ordinary keep-alive budget so only the backdrop pin can
    // prevent decoding again after its section leaves the widget tree.
    final oldBytes = imageCache.maximumSizeBytes;
    imageCache.maximumSizeBytes = 0;
    addTearDown(() => imageCache.maximumSizeBytes = oldBytes);
  });

  testWidgets('visited backdrops reuse their decode after leaving the section', (tester) async {
    final cache = BackdropCache();
    addTearDown(cache.dispose);
    var loads = 0;
    final image = _CountingImage(() => loads++);
    expect(loads, 0);
    await show(tester, cache, image);
    await show(tester, cache, null);
    await show(tester, cache, image);
    expect(loads, 1);
  });

  testWidgets('entry limit evicts the least recently displayed backdrop', (tester) async {
    final cache = BackdropCache(maximumEntries: 1);
    addTearDown(cache.dispose);
    var firstLoads = 0;
    final first = _CountingImage(() => firstLoads++);
    final second = _CountingImage(() {});
    await show(tester, cache, first);
    await show(tester, cache, null);
    await show(tester, cache, second);
    await show(tester, cache, null);
    await show(tester, cache, first);
    expect(firstLoads, 2);
  });

  testWidgets('clearing artwork reloads a mounted backdrop and releases retained images', (tester) async {
    final cache = BackdropCache();
    addTearDown(cache.dispose);
    var mountedLoads = 0;
    var retainedLoads = 0;
    final mountedImage = _CountingImage(() => mountedLoads++);
    final retainedImage = _CountingImage(() => retainedLoads++);
    await show(tester, cache, retainedImage);
    await show(tester, cache, mountedImage);

    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('satra_clear_backdrops_');
      final manager = PlexImageCacheManager.forTesting(
        httpClientFactory: () => MockClient((_) => throw StateError('Unexpected download')),
        cacheDirectoryProvider: () async => directory,
      );
      addTearDown(() async {
        await manager.dispose();
        await directory.delete(recursive: true);
      });
      final file = await manager.putFile('https://example.invalid/continue-watching.jpg', base64Decode(_png));
      await manager.clearArtworkCache();
      expect(await file.exists(), isFalse);
    });

    await tester.pump();
    expect(mountedLoads, 2);
    await show(tester, cache, retainedImage);
    expect(retainedLoads, 2);
  });

  testWidgets('byte budget and memory pressure release decoded backdrops', (tester) async {
    for (final maximumBytes in [0, 1024]) {
      final cache = BackdropCache(maximumBytes: maximumBytes);
      var loads = 0;
      final image = _CountingImage(() => loads++);
      await show(tester, cache, image);
      await show(tester, cache, null);
      if (maximumBytes > 0) cache.didHaveMemoryPressure();
      await show(tester, cache, image);
      expect(loads, 2);
      cache.dispose();
      await show(tester, cache, null);
    }
  });
}
