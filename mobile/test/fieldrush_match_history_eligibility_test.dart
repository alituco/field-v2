import 'package:field/src/profile/fieldrush_match_history_screen.dart';
import 'package:field/src/profile/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final sample in [
    (counted: false, delta: 0, side: 'WHITE', score: '0–1'),
    (counted: false, delta: -5, side: 'BLACK', score: '1–0'),
    (counted: true, delta: 0, side: 'AWAY', score: '1–0'),
  ]) {
    testWidgets('history counted=${sample.counted} delta=${sample.delta}', (
      tester,
    ) async {
      final event = ProfileRatingEvent.fromJson({
        'event_id': 'event',
        'source_type': 'OPEN_QUEUE',
        'source_id': 'game',
        'played_at': '2026-10-14T20:00:00Z',
        'result': sample.side == 'WHITE' ? 'LOSS' : 'WIN',
        'rating_before': 1000,
        'rating_after': 1000 + sample.delta,
        'rating_change': sample.delta,
        'rating_status': 'RATED',
        'rating_visible': true,
        'counted_as_played': sample.counted,
        'actual_played_seconds': 480,
        'rating_explanation': sample.counted
            ? 'This appearance counts: at least 10 playing minutes were verified.'
            : 'No SR change: 8 min 0 sec played; 10 minutes are required.',
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
                  'player_side': sample.side,
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
        findsNothing,
      );
      expect(find.textContaining('10 playing minutes'), findsNothing);
      expect(find.textContaining('10 minutes are required'), findsNothing);
      expect(find.text('SR'), findsOneWidget);
      expect(find.textContaining('· ${sample.score}'), findsOneWidget);
      expect(
        find.text('${sample.delta}'),
        sample.counted || sample.delta != 0 ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('—'),
        sample.counted || sample.delta != 0 ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
