import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/widgets/glass_surface.dart';

void main() {
  testWidgets('fades the glass and content without putting blur under opacity', (tester) async {
    const progress = AlwaysStoppedAnimation<double>(0.5);
    await tester.pumpWidget(
      const MaterialApp(
        home: GlassTransitionScope(
          animation: progress,
          child: GlassSurface(opacity: 0.8, child: Text('Panel')),
        ),
      ),
    );
    final filter = find.byType(BackdropFilter);
    expect(filter, findsOneWidget);
    expect(find.ancestor(of: filter, matching: find.byType(Opacity)), findsNothing);
    final contentOpacity = tester.widget<Opacity>(find.descendant(of: filter, matching: find.byType(Opacity)).first);
    expect(contentOpacity.opacity, 0.5);
    final pane = tester.widget<DecoratedBox>(find.descendant(of: filter, matching: find.byType(DecoratedBox)).first);
    expect((pane.decoration as BoxDecoration).color!.a, closeTo(0.4, 0.01));
  });
}
