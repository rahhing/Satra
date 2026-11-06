import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/widgets/overlay_sheet.dart';

void main() {
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
    expect(args['viewType'], 'com.satra/video_sheet_blur');
    expect(const StandardMessageCodec().decodeMessage(ByteData.sublistView(args['params'])), {'dark': true});

    unawaited(controller.push<void>(builder: (_) => const SizedBox(height: 300)));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'create'), hasLength(1));
    expect(tester.getSize(find.byType(AppKitView)).height, 300);
    controller.close();
    await tester.pumpAndSettle();
    expect(find.byType(AppKitView), findsNothing);
    expect(calls.where((call) => call.method == 'dispose'), hasLength(1));

    // A later non-player sheet must never retain the native video material.
    unawaited(controller.show<void>(builder: (_) => const SizedBox(height: 100)));
    await tester.pumpAndSettle();
    expect(find.byType(AppKitView), findsNothing);
    expect(find.byType(BackdropFilter), findsOneWidget);
    controller.close();
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
