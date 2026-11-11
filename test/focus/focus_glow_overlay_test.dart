import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/focus/focus_glow_overlay.dart';
import 'package:satra/services/settings_service.dart';
import '../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  test('focusGlow preference is off by default', () {
    expect(SettingsService.focusGlow.defaultValue, isFalse);
    expect(SettingsService.instance.read(SettingsService.focusGlow), isFalse);
  });

  testWidgets('glow switches off and back on without moving focus', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: FocusGlowOverlay(
            isFocused: true,
            borderRadius: 12,
            color: Colors.white,
            child: SizedBox(width: 100, height: 150),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CompositedTransformFollower), findsNothing);
    for (final enabled in [true, false, true, false]) {
      await SettingsService.instance.write(SettingsService.focusGlow, enabled);
      await tester.pumpAndSettle();
      expect(find.byType(CompositedTransformFollower), enabled ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
