import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/retained_tab_view.dart';

void main() {
  testWidgets('switching tabs retains scroll offsets, form values and state identities', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final field = GlobalKey();
    Widget host(int index) => MaterialApp(
      home: Material(
        child: RetainedTabView(
          index: index,
          children: [
            ListView(
              controller: scroll,
              children: [
                TextField(key: field),
                const SizedBox(height: 2000),
              ],
            ),
            const Center(child: Text('Second tab')),
          ],
        ),
      ),
    );
    await tester.pumpWidget(host(0));
    await tester.enterText(find.byType(TextField), 'Keep my search');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final state = field.currentState;
    scroll.jumpTo(200);
    await tester.pumpWidget(host(1));
    await tester.pumpAndSettle();
    expect(find.text('Second tab'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(field.currentState, same(state));
    expect(scroll.offset, 200);
    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();
    expect(scroll.offset, 200);
    expect(field.currentState, same(state));
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller, isNull);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, 'Keep my search');
  });

  testWidgets('hidden tabs disable tickers and semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(home: RetainedTabView(index: 1, children: [Text('Hidden tab'), Text('Visible tab')])),
    );
    expect(find.bySemanticsLabel('Hidden tab'), findsNothing);
    expect(find.bySemanticsLabel('Visible tab'), findsOneWidget);
    final modes = tester.widgetList<TickerMode>(
      find.descendant(
        of: find.byType(RetainedTabView),
        matching: find.byType(TickerMode, skipOffstage: false),
        skipOffstage: false,
      ),
    );
    expect(modes.map((mode) => mode.enabled), [false, true]);
    semantics.dispose();
  });
}
