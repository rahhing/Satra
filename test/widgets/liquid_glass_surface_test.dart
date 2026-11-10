import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/i18n/strings.g.dart';
import 'package:satra/services/settings_service.dart' hide ThemeMode;
import 'package:satra/theme/mono_theme.dart';
import 'package:satra/widgets/glass_surface.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('GlassSurface live-toggles between frosted blur and Liquid Glass optical distortion', (tester) async {
    final settings = SettingsService.instance;

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
}
