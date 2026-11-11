import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/i18n/strings.g.dart';
import 'package:satra/services/settings_service.dart' hide ThemeMode;
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/widgets/glass_surface.dart';
import 'package:satra/widgets/overlay_sheet.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    await SettingsService.instance.write(SettingsService.liquidGlass, false);
    await SettingsService.instance.write(SettingsService.liquidGlassOpacity, 0.20);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('GlassSurface live-toggles between frosted blur and Liquid Glass optical distortion', (tester) async {
    final settings = SettingsService.instance;
    await settings.write(SettingsService.liquidGlass, false);

    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 120,
              child: GlassSurface(child: Center(child: Text('Test'))),
            ),
          ),
        ),
      ),
    );

    final glassClipPaths = find.descendant(of: find.byType(GlassSurface), matching: find.byType(ClipPath));
    expect(find.byType(BackdropFilter), findsOneWidget);
    final baseClipCount = tester.widgetList(glassClipPaths).length;

    await settings.write(SettingsService.liquidGlass, true);
    await tester.pump();

    final filters = tester.widgetList<BackdropFilter>(find.byType(BackdropFilter)).toList();
    expect(filters, hasLength(3));
    expect(filters.map((f) => f.filterConfig).toSet(), hasLength(3));
    expect(glassClipPaths, findsNWidgets(baseClipCount + 3));

    await settings.write(SettingsService.liquidGlass, false);
    await tester.pump();

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(glassClipPaths, findsNWidgets(baseClipCount));
  });

  testWidgets('Bottom-docked GlassSurface keeps top corners rounded, defaults translucent, and scales with opacity slider', (
    tester,
  ) async {
    await SettingsService.instance.write(SettingsService.liquidGlass, true);
    await SettingsService.instance.write(SettingsService.liquidGlassOpacity, 0.20);
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: Scaffold(
          backgroundColor: const Color(0xFF00AAFF),
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: const ColoredBox(
                color: Color(0xFF00AAFF),
                child: SizedBox(
                  width: 240,
                  height: 160,
                  child: GlassSurface(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                    opacity: 0.86,
                    child: SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();

    final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final defaultImage = await tester.runAsync(() => boundary.toImage(pixelRatio: 1.0));
    final defaultBytes = await tester.runAsync(() => defaultImage!.toByteData(format: ui.ImageByteFormat.rawRgba));
    expect(defaultBytes, isNotNull);

    int channelIn(ByteData data, int x, int y, int c) => data.getUint8((y * 240 + x) * 4 + c);

    // Default Liquid Glass opacity (20%) stays crystal-translucent over #00AAFF.
    expect(channelIn(defaultBytes!, 120, 80, 2), greaterThan(170));
    expect((channelIn(defaultBytes, 2, 157, 2) - channelIn(defaultBytes, 2, 105, 2)).abs(), lessThanOrEqualTo(6));
    expect((channelIn(defaultBytes, 237, 157, 2) - channelIn(defaultBytes, 237, 105, 2)).abs(), lessThanOrEqualTo(6));

    // Raising Liquid Glass Opacity to 90% deepens the smoked tint while keeping
    // top-left rounded and bottom corners sharp and uniformly filled.
    await SettingsService.instance.write(SettingsService.liquidGlassOpacity, 0.90);
    await tester.pump();

    final denseImage = await tester.runAsync(() => boundary.toImage(pixelRatio: 1.0));
    final bytes = await tester.runAsync(() => denseImage!.toByteData(format: ui.ImageByteFormat.rawRgba));
    expect(bytes, isNotNull);

    int channelAt(int x, int y, int c) => bytes!.getUint8((y * 240 + x) * 4 + c);

    // Top-left (2, 2) lies outside the 28px top-left rounded corner, so the
    // bright cyan backdrop (#00AAFF) remains completely untouched.
    expect(channelAt(2, 2, 2), greaterThan(230));
    expect(channelAt(2, 2, 0), lessThan(20));

    // Bottom-left (2, 157) and bottom-right (237, 157) must be completely filled
    // by the dark smoked glass with no curved cutoff or semi-opaque wedge,
    // matching the vertical edge 50px higher up.
    expect(channelAt(2, 157, 2), lessThan(80));
    expect(channelAt(237, 157, 2), lessThan(80));
    expect((channelAt(2, 157, 0) - channelAt(2, 105, 0)).abs(), lessThanOrEqualTo(6));
    expect((channelAt(237, 157, 0) - channelAt(237, 105, 0)).abs(), lessThanOrEqualTo(6));
  });

  testWidgets('OverlaySheetHost(blurNativeVideo: true) blurs native video for all hosted sheets', (tester) async {
    late BuildContext innerContext;

    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: OverlaySheetHost(
          blurNativeVideo: true,
          child: Builder(
            builder: (context) {
              innerContext = context;
              return const Scaffold(body: SizedBox.expand());
            },
          ),
        ),
      ),
    );

    unawaited(OverlaySheetController.of(innerContext).show<void>(builder: (_) => const SizedBox(height: 120)));
    await tester.pumpAndSettle();

    final glass = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(glass.blurNativeVideo, isTrue);
  });
}
