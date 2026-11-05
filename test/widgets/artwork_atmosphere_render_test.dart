import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/media/media_backend.dart';
import 'package:satra/media/media_item.dart';
import 'package:satra/media/media_kind.dart';
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/widgets/artwork_atmosphere.dart';

void main() {
  testWidgets('offline selected artwork colours the black canvas and high contrast removes it', (tester) async {
    late Directory directory;
    late File artwork;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('satra-atmosphere-');
      artwork = File('${directory.path}/art.png');
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = const Color(0xFF2255FF));
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 64);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await artwork.writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    });
    addTearDown(() => directory.deleteSync(recursive: true));

    const capture = Key('atmosphere');
    Widget host({bool highContrast = false}) => MaterialApp(
      theme: monoTheme(MonoPalette.dark),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(640, 360), highContrast: highContrast),
        child: Center(
          child: RepaintBoundary(
            key: capture,
            child: SizedBox(
              width: 640,
              height: 360,
              child: ArtworkAtmosphere(
                item: MediaItem(id: 'offline', backend: MediaBackend.plex, kind: MediaKind.movie, artPath: '/art'),
                allowNetwork: false,
                localArtworkPathResolver: (_) => artwork.path,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host());
    // File I/O, codec creation, and decoded-frame delivery each cross the
    // engine event loop. Pump between them until the actual image is ready.
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (tester.widgetList<RawImage>(find.byType(RawImage)).any((image) => image.image != null)) break;
    }
    expect(tester.widgetList<RawImage>(find.byType(RawImage)).any((image) => image.image != null), isTrue);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    Future<List<int>> pixel(int x, int y) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
      return (await tester.runAsync(() async {
        final rendered = await boundary.toImage();
        final bytes = (await rendered.toByteData())!;
        final offset = (y * rendered.width + x) * 4;
        final result = [for (var i = 0; i < 3; i++) bytes.getUint8(offset + i)];
        rendered.dispose();
        return result;
      }))!;
    }

    final colour = await pixel(600, 20);
    expect(colour[2], greaterThan(colour[0] * 2), reason: 'the selected blue artwork supplies the atmosphere');
    expect(colour[2], greaterThan(40));
    expect(await pixel(10, 350), everyElement(lessThan(6)), reason: 'the atmosphere dissolves into black');
    await tester.pumpWidget(host(highContrast: true));
    await tester.pumpAndSettle();
    expect(await pixel(600, 20), [0, 0, 0]);
  });
}
