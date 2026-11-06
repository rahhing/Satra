import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/widgets/glass_surface.dart';
import 'package:satra/widgets/linux_video_blur.dart';

void main() {
  const channel = MethodChannel('com.satra/mpv_player');
  final calls = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    calls.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('reports physical pane bounds, sigma and normalized corner radii', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1200, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 30,
              top: 40,
              width: 200,
              height: 120,
              child: GlassSurface(
                blurNativeVideo: true,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                child: SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(calls.last.method, 'setVideoBlurRegion');
    expect(calls.last.arguments['rect'], [60.0, 80.0, 400.0, 240.0, 56.0, 56.0, 56.0, 0.0, 0.0]);

    final count = calls.length;
    await tester.pump();
    expect(calls.length, count);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.last.arguments, {'id': calls.first.arguments['id']});
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('follows a retained pane through ancestor translation and resize', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final offset = ValueNotifier(Offset.zero);
    final width = ValueNotifier(180.0);
    addTearDown(offset.dispose);
    addTearDown(width.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: ValueListenableBuilder(
            valueListenable: offset,
            child: RepaintBoundary(
              child: ValueListenableBuilder(
                valueListenable: width,
                builder: (_, value, _) => SizedBox(
                  width: value,
                  height: 100,
                  child: const GlassSurface(blurNativeVideo: true, child: SizedBox.expand()),
                ),
              ),
            ),
            builder: (_, value, child) => Transform.translate(offset: value, child: child),
          ),
        ),
      ),
    );
    await tester.pump();
    final original = List<double>.from(calls.last.arguments['rect']);
    offset.value = const Offset(17, 29);
    await tester.pump();
    expect(calls.last.arguments['rect'][0], original[0] + 17);
    expect(calls.last.arguments['rect'][1], original[1] + 29);
    width.value = 220;
    await tester.pump();
    expect(calls.last.arguments['rect'][2], 220);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('clears native blur when effects are disabled', (tester) async {
    Widget pane(bool highContrast) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(highContrast: highContrast),
        child: const GlassSurface(blurNativeVideo: true, child: SizedBox(width: 200, height: 100)),
      ),
    );
    await tester.pumpWidget(pane(false));
    await tester.pump();
    expect(find.byType(LinuxVideoBlur), findsOneWidget);
    final id = calls.last.arguments['id'];
    await tester.pumpWidget(pane(true));
    await tester.pump();
    expect(find.byType(LinuxVideoBlur), findsNothing);
    expect(calls.last.arguments, {'id': id});
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('ordinary glass uses only Flutter blur', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GlassSurface(child: SizedBox(width: 200, height: 100))));
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(LinuxVideoBlur), findsNothing);
    expect(calls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('reparenting a visible pane does not briefly clear native blur', (tester) async {
    final paneKey = GlobalKey();
    final pane = GlassSurface(key: paneKey, blurNativeVideo: true, child: const SizedBox(width: 200, height: 100));
    Widget host(bool wrapped) => MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: wrapped ? RepaintBoundary(child: Opacity(opacity: 0.9, child: pane)) : pane,
      ),
    );
    await tester.pumpWidget(host(false));
    await tester.pump();
    final id = calls.last.arguments['id'];
    calls.clear();
    for (final wrapped in [true, false, true, false]) {
      await tester.pumpWidget(host(wrapped));
      await tester.pump();
    }
    expect(calls.where((call) => !call.arguments.containsKey('rect')), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.last.arguments, {'id': id});
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
