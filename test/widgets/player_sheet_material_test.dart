import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/i18n/strings.g.dart';
import 'package:satra/services/settings_service.dart' hide ThemeMode;
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/widgets/glass_surface.dart';
import 'package:satra/widgets/overlay_sheet.dart';
import 'package:satra/widgets/toolbar_scrim.dart';

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

  tearDown(() {
    GlassSurface.debugEnableMacOSNativeGlass = null;
  });

  testWidgets('native video material follows sheet pages and releases on close', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null),
    );
    late OverlaySheetController controller;
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.oled),
        home: OverlaySheetHost(
          child: Builder(
            builder: (context) {
              controller = OverlaySheetController.of(context);
              return const Scaffold();
            },
          ),
        ),
      ),
    );
    unawaited(controller.show<void>(blurNativeVideo: true, builder: (_) => const SizedBox(height: 200)));
    await tester.pumpAndSettle();
    expect(find.byType(AppKitView), findsOneWidget);
    final create = calls.singleWhere((call) => call.method == 'create');
    final args = create.arguments as Map;
    expect(args['viewType'], 'com.satra/macos_glass_surface');
    final decoded =
        (const StandardMessageCodec().decodeMessage(ByteData.sublistView(args['params'])) as Map).cast<String, Object?>();
    expect(decoded['dark'], isTrue);
    expect(decoded['liquidGlass'], isFalse);
    expect(decoded['tl'], isA<double>());
    expect(decoded['tintArgb'], isA<int>());
    expect(decoded['tintStrength'], isA<double>());

    // AppKitView must never sit inside a ClipRRect or ClipPath (which causes
    // FlutterMutatorView to insert FlutterPathClipView and isolate CABackdropLayer).
    expect(find.ancestor(of: find.byType(AppKitView), matching: find.byType(ClipRRect)), findsNothing);
    expect(find.ancestor(of: find.byType(AppKitView), matching: find.byType(ClipPath)), findsNothing);

    unawaited(controller.push<void>(builder: (_) => const SizedBox(height: 300)));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'create'), hasLength(1));
    expect(tester.getSize(find.byType(AppKitView)).height, 300);
    controller.close();
    await tester.pumpAndSettle();
    expect(find.byType(AppKitView), findsNothing);
    expect(calls.where((call) => call.method == 'dispose'), hasLength(1));

    // In default TestWidgetsFlutterBinding (without debugEnableMacOSNativeGlass),
    // non-video sheets keep pure-Flutter BackdropFilter for golden/toImage tests.
    unawaited(controller.show<void>(builder: (_) => const SizedBox(height: 100)));
    await tester.pumpAndSettle();
    expect(find.byType(AppKitView), findsNothing);
    expect(find.byType(BackdropFilter), findsOneWidget);
    controller.close();
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('macOS native glass powers all GlassSurfaces and live-updates Liquid Glass and theme in-place', (
    tester,
  ) async {
    GlassSurface.debugEnableMacOSNativeGlass = true;
    final platformViewCalls = <MethodCall>[];
    final glassUpdates = <Map<String, Object?>>[];
    const glassChannel = MethodChannel('com.satra/macos_glass_surface');

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      platformViewCalls.add(call);
      return null;
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(glassChannel, (call) async {
      if (call.method == 'update') {
        glassUpdates.add((call.arguments as Map).cast<String, Object?>());
      }
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(glassChannel, null);
    });

    final themeNotifier = ValueNotifier<ThemeData>(monoTheme(MonoPalette.dark));
    addTearDown(themeNotifier.dispose);

    await tester.pumpWidget(
      ValueListenableBuilder<ThemeData>(
        valueListenable: themeNotifier,
        builder: (context, theme, _) => MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Stack(
              children: [
                Positioned(top: 0, left: 0, right: 0, child: ToolbarScrim(child: SizedBox(height: 48))),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppKitView), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.ancestor(of: find.byType(AppKitView), matching: find.byType(ClipRRect)), findsNothing);
    expect(platformViewCalls.where((c) => c.method == 'create'), hasLength(1));

    // Toggle Liquid Glass ON -> updates native NSGlassEffectView in-place without recreating AppKitView.
    await SettingsService.instance.write(SettingsService.liquidGlass, true);
    await tester.pump();

    expect(platformViewCalls.where((c) => c.method == 'create'), hasLength(1));
    expect(glassUpdates, isNotEmpty);
    expect(glassUpdates.last['liquidGlass'], isTrue);
    expect(glassUpdates.last['dark'], isTrue);
    final defaultTint = glassUpdates.last['tintStrength']! as double;
    expect(defaultTint, lessThan(0.20));

    // Raising Liquid Glass Opacity updates native tintStrength live in-place.
    await SettingsService.instance.write(SettingsService.liquidGlassOpacity, 0.75);
    await tester.pump();

    expect(platformViewCalls.where((c) => c.method == 'create'), hasLength(1));
    expect(glassUpdates.last['tintStrength']! as double, greaterThan(defaultTint));

    // Switch theme to Light -> updates native appearance & tint in-place without recreating AppKitView.
    themeNotifier.value = monoTheme(MonoPalette.light);
    await tester.pumpAndSettle();

    expect(platformViewCalls.where((c) => c.method == 'create'), hasLength(1));
    expect(glassUpdates.last['liquidGlass'], isTrue);
    expect(glassUpdates.last['dark'], isFalse);

    // Toggle Liquid Glass OFF -> switches back to NSVisualEffectView in-place and forwards blur/brightness sliders.
    await SettingsService.instance.write(SettingsService.liquidGlass, false);
    await tester.pump();

    expect(platformViewCalls.where((c) => c.method == 'create'), hasLength(1));
    expect(glassUpdates.last['liquidGlass'], isFalse);
    expect(glassUpdates.last['blurScale'], 1.0);
    expect(glassUpdates.last['backgroundBrightness'], 1.0);

    await SettingsService.instance.write(SettingsService.glassBlurAmount, 1.5);
    await SettingsService.instance.write(SettingsService.glassBackgroundBrightness, 0.6);
    await tester.pump();

    expect(platformViewCalls.where((c) => c.method == 'create'), hasLength(1));
    expect(glassUpdates.last['blurScale'], 1.5);
    expect(glassUpdates.last['backgroundBrightness'], 0.6);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
