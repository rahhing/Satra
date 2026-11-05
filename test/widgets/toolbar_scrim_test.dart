import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/widgets/toolbar_scrim.dart';

void main() {
  testWidgets('light scrim only lightens the content beneath it', (tester) async {
    // A fade from white to Colors.transparent (transparent black) passes
    // through translucent gray and paints a shadow band below the toolbar.
    const key = Key('scrim');
    const backdrop = Color(0xFFF7F7F8);
    expect(MonoPalette.light.bg, backdrop);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Theme(
          data: monoTheme(MonoPalette.light),
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 64,
                  child: ColoredBox(
                    color: backdrop,
                    child: ToolbarScrim(child: SizedBox(height: 232)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    late ui.Image image;
    late ByteData bytes;
    await tester.runAsync(() async {
      image = await boundary.toImage();
      bytes = (await image.toByteData())!;
    });
    addTearDown(image.dispose);

    final floor = [(backdrop.r * 255).round(), (backdrop.g * 255).round(), (backdrop.b * 255).round()];
    final x = image.width ~/ 2;
    for (var y = 0; y < image.height; y++) {
      final offset = (y * image.width + x) * 4;
      for (var channel = 0; channel < 3; channel++) {
        final value = bytes.getUint8(offset + channel);
        // Slack for gradient and surface dithering.
        expect(
          value,
          greaterThanOrEqualTo(floor[channel] - 2),
          reason: 'row $y of ${image.height}, channel $channel: $value is darker than the backdrop',
        );
      }
    }
  });
  testWidgets('toolbar keeps background colours visible and blurs their boundary', (tester) async {
    const key = Key('glass-colours');
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 256,
              height: 128,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: ColoredBox(color: Color(0xFFFF0000))),
                        Expanded(child: ColoredBox(color: Color(0xFF0000FF))),
                      ],
                    ),
                  ),
                  const Positioned(top: 0, left: 0, right: 0, child: ToolbarScrim(child: SizedBox(height: 72))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    late ui.Image image;
    late ByteData pixels;
    await tester.runAsync(() async {
      image = await boundary.toImage();
      pixels = (await image.toByteData())!;
    });
    addTearDown(image.dispose);
    int channel(int x, int colour) => pixels.getUint8((40 * image.width + x) * 4 + colour);
    // The tint must preserve most of the background, not flatten it to gray.
    expect(channel(64, 0), greaterThan(150));
    expect(channel(192, 2), greaterThan(150));
    // Both colours must mix across the originally sharp red/blue boundary.
    expect(channel(124, 2), greaterThan(40));
    expect(channel(132, 0), greaterThan(40));
  }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux}));
}
