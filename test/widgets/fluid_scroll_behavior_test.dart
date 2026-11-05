import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/services/device_performance.dart';
import 'package:satra/theme/fluid_scroll_behavior.dart';
import 'package:satra/utils/pointer_scroll_axis.dart';

class _ScrollTestBinding extends AutomatedTestWidgetsFlutterBinding with PointerScrollAxisLock {}

void main() {
  _ScrollTestBinding();
  tearDown(DevicePerformance.debugReset);

  Future<void> wheel(WidgetTester tester, Offset delta, {Offset position = const Offset(200, 150)}) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(kind: PointerDeviceKind.mouse, position: position, scrollDelta: delta),
    );
    await tester.pump();
  }

  Future<void> host(
    WidgetTester tester,
    ScrollController vertical, {
    ScrollController? horizontal,
    bool reduce = false,
  }) => tester.pumpWidget(
    MaterialApp(
      scrollBehavior: const FluidScrollBehavior(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Scaffold(
          body: ListView(
            controller: vertical,
            children: [
              if (horizontal != null)
                SizedBox(
                  height: 250,
                  child: ListView(
                    controller: horizontal,
                    scrollDirection: Axis.horizontal,
                    children: const [SizedBox(width: 2000)],
                  ),
                ),
              const SizedBox(height: 3000),
            ],
          ),
        ),
      ),
    ),
  );

  testWidgets('wheel steps ease and accumulate instead of jumping or dropping distance', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await host(tester, controller);
    await wheel(tester, const Offset(0, 100));
    expect(controller.offset, 0);
    await tester.pump(const Duration(milliseconds: 80));
    expect(controller.offset, inExclusiveRange(0, 100));
    await wheel(tester, const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(200, 0.01));
  });

  testWidgets('reversing the wheel immediately reverses unfinished travel', (tester) async {
    final controller = ScrollController(initialScrollOffset: 300);
    addTearDown(controller.dispose);
    await host(tester, controller);
    await wheel(tester, const Offset(0, 200));
    await tester.pump(const Duration(milliseconds: 60));
    final beforeReverse = controller.offset;
    await wheel(tester, const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(beforeReverse - 100, 0.01));
  });

  testWidgets('vertical wheel over a shelf scrolls the page; horizontal wheel scrolls the shelf', (tester) async {
    final vertical = ScrollController();
    final horizontal = ScrollController();
    addTearDown(vertical.dispose);
    addTearDown(horizontal.dispose);
    await host(tester, vertical, horizontal: horizontal);
    await wheel(tester, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(vertical.offset, closeTo(80, 0.01));
    expect(horizontal.offset, 0);
    await wheel(tester, const Offset(90, 0));
    await tester.pumpAndSettle();
    expect(horizontal.offset, closeTo(90, 0.01));
    expect(vertical.offset, closeTo(80, 0.01));
  });

  testWidgets('reduce motion uses immediate native wheel scrolling', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await host(tester, controller, reduce: true);
    await wheel(tester, const Offset(0, 100));
    expect(controller.offset, 100);
  });

  testWidgets('macOS wheel signals move immediately without a second animation', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await host(tester, controller);
    await wheel(tester, const Offset(0, 100));
    expect(controller.offset, 100);
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, 100);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('shift-wheel keeps horizontal shelf navigation', (tester) async {
    final vertical = ScrollController();
    final horizontal = ScrollController();
    addTearDown(vertical.dispose);
    addTearDown(horizontal.dispose);
    await host(tester, vertical, horizontal: horizontal);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await wheel(tester, const Offset(0, 80));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(horizontal.offset, closeTo(80, 0.01));
    expect(vertical.offset, 0);
  });

  testWidgets('nested native page views retain their wheel priority', (tester) async {
    final vertical = ScrollController();
    final pages = PageController();
    addTearDown(vertical.dispose);
    addTearDown(pages.dispose);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const FluidScrollBehavior(),
        home: Scaffold(
          body: ListView(
            controller: vertical,
            children: [
              SizedBox(
                height: 250,
                child: PageView(
                  controller: pages,
                  scrollDirection: Axis.vertical,
                  scrollBehavior: const MaterialScrollBehavior().copyWith(overscroll: false, scrollbars: false),
                  children: const [
                    ColoredBox(color: Colors.blue),
                    ColoredBox(color: Colors.orange),
                  ],
                ),
              ),
              const SizedBox(height: 3000),
            ],
          ),
        ),
      ),
    );
    await wheel(tester, const Offset(0, 100));
    expect(pages.offset, greaterThan(0));
    expect(vertical.offset, 0);
    await tester.pumpAndSettle();
  });

  testWidgets('trackpad pans scroll vertically over shelves and horizontally within them', (tester) async {
    final vertical = ScrollController(initialScrollOffset: 100);
    final horizontal = ScrollController(initialScrollOffset: 100);
    addTearDown(vertical.dispose);
    addTearDown(horizontal.dispose);
    await host(tester, vertical, horizontal: horizontal);
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    const position = Offset(200, 100);
    await tester.sendEventToBinding(pointer.panZoomStart(position));
    await tester.sendEventToBinding(pointer.panZoomUpdate(position, pan: const Offset(22, -40)));
    await tester.pump();
    await tester.sendEventToBinding(pointer.panZoomUpdate(position, pan: const Offset(30, -120)));
    await tester.pump();
    expect(vertical.offset, greaterThan(100));
    expect(horizontal.offset, 100);
    final downOffset = vertical.offset;
    await tester.sendEventToBinding(pointer.panZoomUpdate(position, pan: const Offset(70, -60)));
    await tester.pump();
    expect(vertical.offset, lessThan(downOffset));
    expect(horizontal.offset, 100);
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
    vertical.jumpTo(0);
    await tester.pump();
    await tester.sendEventToBinding(pointer.panZoomStart(position));
    await tester.sendEventToBinding(pointer.panZoomUpdate(position, pan: const Offset(-40, -22)));
    await tester.pump();
    await tester.sendEventToBinding(pointer.panZoomUpdate(position, pan: const Offset(-120, -30)));
    await tester.pump();
    expect(horizontal.offset, greaterThan(100));
    expect(vertical.offset, 0);
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux}));

  testWidgets('touch drags keep native scrolling', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await host(tester, controller);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    expect(controller.offset, greaterThan(100));
    await tester.pumpAndSettle();
  });

  testWidgets('mouse drags scroll vertical and horizontal views', (tester) async {
    final vertical = ScrollController();
    final horizontal = ScrollController();
    addTearDown(vertical.dispose);
    addTearDown(horizontal.dispose);
    await host(tester, vertical, horizontal: horizontal);

    await tester.dragFrom(const Offset(200, 120), const Offset(-180, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(horizontal.offset, greaterThan(100));

    await tester.dragFrom(const Offset(200, 350), const Offset(0, -180), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(vertical.offset, greaterThan(100));
  });

  testWidgets('reduced effects use immediate native wheel scrolling', (tester) async {
    DevicePerformance.debugReset(override: VisualEffectsSetting.reduced);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await host(tester, controller);
    await wheel(tester, const Offset(0, 100));
    expect(controller.offset, 100);
  });
}
