import 'package:field/src/profile/fieldrush_match_history_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final sample in [
    (counted: false, delta: 0),
    (counted: false, delta: -5),
    (counted: true, delta: 0),
  ]) {
    testWidgets('history counted=${sample.counted} delta=${sample.delta}', (
      tester,
    ) async {
      final event = ProfileRatingEvent.fromJson({
        'event_id': 'event',
        'source_type': 'OPEN_QUEUE',
        'source_id': 'game',
        'played_at': '2026-10-14T20:00:00Z',
        'result': 'LOSS',
        'rating_before': 1000,
        'rating_after': 1000 + sample.delta,
        'rating_change': sample.delta,
        'rating_status': 'RATED',
        'rating_visible': true,
        'counted_as_played': sample.counted,
        'actual_played_seconds': 480,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FieldrushMatchHistoryScreen(
            profile: PlayerProfile(
              id: 'me',
              displayName: 'Alex',
              username: 'alex',
              bio: '',
              followingCount: 0,
              fansCount: 0,
              appearances: 1,
              goals: 0,
              assists: 0,
              highlights: const [],
              career: const [],
              previousGames: [
                ProfilePreviousGame.fromJson({
                  'id': 'game',
                  'source_type': 'OPEN_QUEUE',
                  'played_at': '2026-10-14T20:00:00Z',
                  'timezone': 'America/Phoenix',
                  'white_score': 0,
                  'black_score': 1,
                  'player_side': 'WHITE',
                }),
              ],
            ),
            ratingEvents: [event],
            onOpenGame: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('This appearance does not count toward rating progress.'),
        sample.counted ? findsNothing : findsOneWidget,
      );
      expect(
        find.text('PLAYER SR'),
        sample.counted || sample.delta != 0 ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('${sample.delta}'),
        sample.counted || sample.delta != 0 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
