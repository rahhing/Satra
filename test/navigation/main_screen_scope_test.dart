import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/navigation/main_screen_scope.dart';

void main() {
  testWidgets('non-listening MainScreenFocusScope.of exposes shell action callbacks', (tester) async {
    var downloadsCalls = 0;
    var settingsCalls = 0;
    String? spotlightQuery;
    late BuildContext childContext;

    await tester.pumpWidget(
      MaterialApp(
        home: MainScreenFocusScope(
          openDownloads: () => downloadsCalls++,
          openSettings: () => settingsCalls++,
          openSpotlight: ({initialQuery}) => spotlightQuery = initialQuery ?? '',
          sideNavigationWidth: 0,
          child: Builder(
            builder: (context) {
              childContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final scope = MainScreenFocusScope.of(childContext, listen: false)!;
    scope.openDownloads?.call();
    scope.openSettings?.call();
    scope.openSpotlight?.call(initialQuery: 'matrix');

    expect(downloadsCalls, 1);
    expect(settingsCalls, 1);
    expect(spotlightQuery, 'matrix');
  });

  testWidgets('MainScreenFocusScope.of returns null without a scope', (tester) async {
    late BuildContext childContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            childContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(MainScreenFocusScope.of(childContext, listen: false), isNull);
  });

  testWidgets('non-listening MainScreenFocusScope.of does not register an inherited dependency', (tester) async {
    var foregroundWidth = 1280.0;
    var childBuilds = 0;
    var spotlightCalls = 0;
    late StateSetter rebuildScope;
    final child = Builder(
      builder: (context) {
        childBuilds++;
        MainScreenFocusScope.of(context, listen: false)?.openSpotlight?.call();
        return const SizedBox.shrink();
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuildScope = setState;
            return MainScreenFocusScope(
              openSpotlight: ({initialQuery}) => spotlightCalls++,
              foregroundWidth: foregroundWidth,
              child: child,
            );
          },
        ),
      ),
    );

    expect(childBuilds, 1);
    expect(spotlightCalls, 1);

    rebuildScope(() => foregroundWidth = 1440);
    await tester.pump();

    expect(childBuilds, 1);
    expect(spotlightCalls, 1);
  });
}
