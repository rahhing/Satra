import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/main.dart' as app;
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/screens/auth_screen.dart';
import 'package:plezy/theme/mono_theme.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final loader = FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await loader.load();
  });

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  for (final size in [const Size(1440, 900), const Size(390, 844), const Size(3840, 2160)]) {
    testWidgets('onboarding keeps every sign-in method accessible at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.display.size = size;
      PlatformDetector.debugSetIsDesktopOSOverride(size.width > 700);
      addTearDown(() => PlatformDetector.debugSetIsDesktopOSOverride(null));
      addTearDown(tester.view.display.reset);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const capture = Key('auth-preview');
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: monoTheme(
              MonoPalette.dark,
            ).copyWith(platform: size.width > 700 ? TargetPlatform.linux : TargetPlatform.android),
            home: const app.FormFactorScale(
              child: RepaintBoundary(key: capture, child: AuthScreen(initializeServices: false)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => precacheImage(const AssetImage('assets/plezy.png'), tester.element(find.byType(AuthScreen))),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(t.auth.signInWithPlex), findsOneWidget);
      expect(find.text(t.auth.showQRCode), findsOneWidget);
      expect(find.text(t.auth.connectToMediaBrowser(product: 'Jellyfin')), findsOneWidget);
      expect(find.text(t.auth.connectToMediaBrowser(product: 'Emby')), findsOneWidget);
      if (const bool.fromEnvironment('CAPTURE_REDESIGN')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: size.width / boundary.size.width);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('build/visual-review');
          await directory.create(recursive: true);
          await File('${directory.path}/auth-${size.width.toInt()}.png').writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
