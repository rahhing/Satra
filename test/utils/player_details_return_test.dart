import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/utils/video_player_navigation.dart';

void main() {
  for (final origin in ['Home', 'Library', 'Details']) {
    testWidgets('player exit opens current details from $origin', (tester) async {
      final key = GlobalKey<NavigatorState>();
      final existing = origin == 'Details';
      var detailsCreated = 0;
      PageRoute<bool> details() {
        detailsCreated++;
        return MaterialPageRoute<bool>(
          settings: const RouteSettings(name: '/media_detail', arguments: 'server:movie'),
          builder: (_) => const Scaffold(body: Text('Current media details')),
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          home: Scaffold(body: Text(origin)),
        ),
      );
      final navigator = key.currentState!;
      if (existing) {
        unawaited(navigator.push(details()));
        await tester.pumpAndSettle();
      }
      final playerRoute = VideoPlayerRoute(builder: (_) => const Scaffold(body: Text('Player')));
      final result = playerRoute.push(navigator);
      await tester.pumpAndSettle();
      returnPlayerToDetails(
        navigator,
        playerRoute: playerRoute,
        detailsKey: 'server:movie',
        buildDetailsRoute: details,
      );
      await tester.pump();
      expect(find.text(origin), findsNothing, reason: 'the original page must stay covered during the transition');
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(find.text('Current media details'), findsOneWidget);
      expect(detailsCreated, 1, reason: 'reuse details when already underneath playback');
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text(origin), findsOneWidget);
    });
  }

  testWidgets('falls back to the original page when details cannot be created', (tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        home: const Scaffold(body: Text('Library')),
      ),
    );
    final navigator = key.currentState!;
    final playerRoute = VideoPlayerRoute(builder: (_) => const Scaffold(body: Text('Player')));
    final result = playerRoute.push(navigator);
    await tester.pumpAndSettle();
    returnPlayerToDetails(
      navigator,
      playerRoute: playerRoute,
      detailsKey: 'server:movie',
      buildDetailsRoute: () => throw StateError('Details unavailable'),
    );
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(find.text('Library'), findsOneWidget);
  });
}
