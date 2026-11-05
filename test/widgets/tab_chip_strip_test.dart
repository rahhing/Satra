import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/theme/app_motion.dart';
import 'package:satra/widgets/focusable_tab_chip.dart';

void main() {
  testWidgets('only the selected tab paints a pill, including when another tab has focus', (tester) async {
    final homeFocus = FocusNode();
    addTearDown(homeFocus.dispose);
    const backdrop = Color(0xFF234567);
    const boundaryKey = Key('tabs-image');
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: ColoredBox(
              color: backdrop,
              child: TabChipStrip(
                children: [
                  FocusableTabChip(label: 'Home', isSelected: false, focusNode: homeFocus, onSelect: () {}),
                  FocusableTabChip(label: 'Movies', isSelected: true, onSelect: () {}),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    homeFocus.requestFocus();
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
    late ui.Image image;
    late ByteData pixels;
    await tester.runAsync(() async {
      image = await boundary.toImage();
      pixels = (await image.toByteData())!;
    });
    addTearDown(image.dispose);
    final origin = tester.getTopLeft(find.byKey(boundaryKey));
    List<int> sample(String label) {
      final rect = tester.getRect(find.widgetWithText(FocusableTabChip, label));
      final x = (rect.center.dx - origin.dx).round();
      final y = (rect.top - origin.dy + 5).round();
      return List.generate(3, (channel) => pixels.getUint8((y * image.width + x) * 4 + channel));
    }

    expect(sample('Home'), [0x23, 0x45, 0x67]);
    for (final channel in sample('Movies')) {
      expect(channel, greaterThan(220));
    }
  });

  testWidgets('section changes ease the strip size and fade its foreground', (tester) async {
    final showTabs = ValueNotifier(true);
    addTearDown(showTabs.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ValueListenableBuilder<bool>(
            valueListenable: showTabs,
            builder: (context, expanded, _) => TabChipStrip(
              children: [
                FocusableTabChip(label: 'Home', isSelected: true, onSelect: () {}),
                if (expanded) FocusableTabChip(label: 'Recommended', isSelected: false, onSelect: () {}),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final sizeFinder = find.descendant(of: find.byType(TabChipStrip), matching: find.byType(AnimatedSize));
    final expandedWidth = tester.getSize(sizeFinder).width;
    showTabs.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final movingWidth = tester.getSize(sizeFinder).width;
    final fade = tester.widget<FadeTransition>(
      find.descendant(of: find.byType(TabChipStrip), matching: find.byType(FadeTransition)),
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    final collapsedWidth = tester.getSize(sizeFinder).width;
    expect(movingWidth, inExclusiveRange(collapsedWidth, expandedWidth));
    expect(fade.opacity.value, 1);
  });
  testWidgets('library pill glides and reverses while the subsection pill stays selected', (tester) async {
    final selected = ValueNotifier(0);
    addTearDown(selected.dispose);
    const key = Key('sliding-pills');
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: const Color(0xFF234567),
              child: ValueListenableBuilder<int>(
                valueListenable: selected,
                builder: (context, index, _) => TabChipStrip(
                  children: [
                    FocusableTabChip(label: 'Movies', isSelected: index == 0, onSelect: () {}),
                    const SizedBox(width: 80),
                    FocusableTabChip(label: 'Anime Movies', isSelected: index == 1, onSelect: () {}),
                    const SizedBox(width: 30),
                    FocusableTabChip(label: 'Recommended', indicatorGroup: 1, isSelected: true, onSelect: () {}),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = tester.getRect(find.widgetWithText(FocusableTabChip, 'Movies'));
    final second = tester.getRect(find.widgetWithText(FocusableTabChip, 'Anime Movies'));
    final subsection = tester.getRect(find.widgetWithText(FocusableTabChip, 'Recommended'));
    Future<int> redAt(double globalX) async {
      final origin = tester.getTopLeft(find.byKey(key));
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      late ui.Image image;
      late ByteData pixels;
      await tester.runAsync(() async {
        image = await boundary.toImage();
        pixels = (await image.toByteData())!;
      });
      final x = (globalX - origin.dx).round();
      final y = (first.top - origin.dy + 6).round();
      final red = pixels.getUint8((y * image.width + x) * 4);
      image.dispose();
      return red;
    }

    selected.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final progress = AppMotion.curve.transform(60 / AppMotion.standard.inMilliseconds);
    final movingCenter = first.center.dx + (second.center.dx - first.center.dx) * progress;
    expect(await redAt(movingCenter), greaterThan(200), reason: 'one pill must paint between its old and new tabs');
    expect(await redAt(subsection.center.dx), greaterThan(200));
    selected.value = 0;
    await tester.pump();
    expect(await redAt(movingCenter), greaterThan(200), reason: 'retargeting must start from the current position');
    await tester.pumpAndSettle();
    expect(await redAt(first.center.dx), greaterThan(200));
    expect(await redAt(second.center.dx), lessThan(100));
    expect(await redAt(subsection.center.dx), greaterThan(200));
  });
}
