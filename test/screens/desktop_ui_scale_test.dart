import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/main.dart' as app;
import 'package:satra/services/settings_service.dart';
import 'package:satra/utils/desktop_ui_scale.dart';
import 'package:satra/utils/platform_detector.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(false);
    TvDetectionService.debugSetAutomotiveOverride(false);
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    await SettingsService.getInstance();
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
    TvDetectionService.debugSetAutomotiveOverride(null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    SettingsService.resetForTesting();
  });

  test('automatic scale corrects unscaled 4K without doubling native HiDPI', () {
    double scale(Size screen, double dpr) =>
        DesktopUiScale.resolve(displaySize: screen, devicePixelRatio: dpr, viewportSize: screen / dpr);
    expect(scale(const Size(1920, 1080), 1), 1);
    expect(scale(const Size(2560, 1440), 1), 1.25);
    expect(scale(const Size(3840, 2160), 1), 2);
    expect(scale(const Size(3840, 2160), 2), 1);
    expect(scale(const Size(5120, 2160), 2), 1);
  });

  test('manual scaling is bounded to a usable narrow viewport', () {
    expect(
      DesktopUiScale.resolve(
        displaySize: const Size(3840, 2160),
        devicePixelRatio: 1,
        viewportSize: const Size(480, 320),
        preference: 2.5,
      ),
      closeTo(320 / 360, 0.001),
    );
    expect(DesktopUiScale.normalize(double.nan), DesktopUiScale.automatic);
  });

  testWidgets('4K layout, media density and pointer hit tests use the same scale', (tester) async {
    tester.view.physicalSize = const Size(3840, 2160);
    tester.view.devicePixelRatio = 1;
    tester.view.display.size = const Size(3840, 2160);
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    var query = const MediaQueryData();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: app.FormFactorScale(
          child: Builder(
            builder: (context) {
              query = MediaQuery.of(context);
              return Scaffold(
                body: Center(
                  child: ElevatedButton(
                    key: const Key('target'),
                    onPressed: () => taps++,
                    child: const Text('Readable control'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    expect(query.size, const Size(1920, 1080));
    expect(query.devicePixelRatio, 2);
    await tester.tap(find.byKey(const Key('target')));
    expect(taps, 1);
    await SettingsService.instance.write(SettingsService.desktopUiScale, 1.25);
    await tester.pumpAndSettle();
    expect(query.size, const Size(3072, 1728));
    expect(query.devicePixelRatio, 1.25);
    await tester.tap(find.byKey(const Key('target')));
    expect(taps, 2);
  });
}
