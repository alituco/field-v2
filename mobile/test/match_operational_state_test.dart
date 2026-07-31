import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_widgets.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fixture parses NO_DATA without changing canonical status', () {
    final fixture = Fixture.fromJson({
      'id': 'fixture-no-data',
      'status': 'FINAL',
      'operational_state': 'NO_DATA',
      'operational_state_updated_at': '2026-07-30T18:00:00Z',
      'operational_reason_code': 'RESULT_MISSING',
      'home_clan_id': 'home',
      'away_clan_id': 'away',
      'venue': 'Field',
      'day': 'FRIDAY',
      'time_slot': FixtureTimeSlot.early.label,
      'match_date': '2026-07-24',
      'home_score': 3,
      'away_score': 0,
      'created_by': 'owner',
      'home_clan': _homeClanJson,
      'away_clan': _awayClanJson,
    });

    expect(fixture.status, FixtureStatus.finalResult);
    expect(fixture.operationalState, MatchOperationalState.noData);
    expect(fixture.operationalReasonCode, 'RESULT_MISSING');
    expect(fixture.operationalStatusDetail, 'Result missing');
    expect(fixture.statusLabel, 'No data');
    expect(fixture.detailStatusLabel, 'No data');
    expect(fixture.hasPendingOperationalResolution, isTrue);
    expect(fixture.shouldDisplayScore, isFalse);
    expect(fixture.operationalStateUpdatedAt, DateTime.utc(2026, 7, 30, 18));
  });

  test('solo game parses UNDER_REVIEW and preserves it in fixture detail', () {
    final game = OpenQueueGame.fromJson({
      'id': 'solo-review',
      'status': 'FINAL',
      'operational_state': 'UNDER_REVIEW',
      'operational_state_updated_at': '2026-07-30T19:00:00Z',
      'operational_reason_code': 'DISPUTED',
      'venue': 'Field',
      'starts_at': '2026-07-24T16:00:00Z',
      'ends_at': '2026-07-24T17:00:00Z',
      'timezone': 'Asia/Bahrain',
      'price_fils': 3000,
      'age_label': 'All ages',
      'capacity': 12,
      'confirmed_count': 12,
      'white_score': 4,
      'black_score': 2,
    });

    expect(game.status, 'FINAL');
    expect(game.operationalState, MatchOperationalState.underReview);
    expect(game.operationalReasonCode, 'DISPUTED');
    expect(game.operationalStatusDetail, 'Resolution disputed');
    expect(game.statusLabel, 'Under review');
    expect(game.shouldDisplayScore, isFalse);

    final detailFixture = OpenQueueMatchDetail(
      game: game,
      scorers: const [],
      timeline: const [],
    ).toFixture();
    expect(detailFixture.status, FixtureStatus.finalResult);
    expect(detailFixture.operationalState, MatchOperationalState.underReview);
    expect(detailFixture.operationalReasonCode, 'DISPUTED');
    expect(detailFixture.detailStatusLabel, 'Under review');
    expect(detailFixture.shouldDisplayScore, isFalse);
  });

  testWidgets(
    'past fixture cards replace provisional scores with state labels',
    (tester) async {
      final fixture = _fixture(
        operationalState: MatchOperationalState.noData,
        homeScore: 3,
        awayScore: 0,
      );
      final game = _soloGame(
        operationalState: MatchOperationalState.underReview,
        whiteScore: 4,
        blackScore: 2,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  FixtureCard(fixture: fixture),
                  SoloFixtureCard(game: game),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('No data'), findsOneWidget);
      expect(find.text('NO DATA'), findsOneWidget);
      expect(find.text('Under review'), findsOneWidget);
      expect(find.text('UNDER REVIEW'), findsOneWidget);
      expect(find.text('3 - 0'), findsNothing);
      expect(find.text('4 - 2'), findsNothing);
      expect(
        find.byKey(const ValueKey('fixture-operational-state-fixture')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('solo-operational-state-solo')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Fixture _fixture({
  required MatchOperationalState operationalState,
  required int homeScore,
  required int awayScore,
}) {
  return Fixture(
    id: 'fixture',
    status: FixtureStatus.finalResult,
    operationalState: operationalState,
    homeClanId: 'home',
    awayClanId: 'away',
    venue: 'Field',
    day: 'FRIDAY',
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: DateTime.utc(2026, 7, 24),
    homeScore: homeScore,
    awayScore: awayScore,
    createdBy: 'owner',
    homeClan: FixtureClan.fromJson(_homeClanJson),
    awayClan: FixtureClan.fromJson(_awayClanJson),
  );
}

OpenQueueGame _soloGame({
  required MatchOperationalState operationalState,
  required int whiteScore,
  required int blackScore,
}) {
  return OpenQueueGame(
    id: 'solo',
    status: 'FINAL',
    operationalState: operationalState,
    venue: 'Field',
    startsAt: DateTime.utc(2026, 7, 24, 16),
    endsAt: DateTime.utc(2026, 7, 24, 17),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: 'All ages',
    capacity: 12,
    confirmedCount: 12,
    spots: const {},
    whiteScore: whiteScore,
    blackScore: blackScore,
  );
}

const _homeClanJson = <String, dynamic>{
  'id': 'home',
  'name': 'Home',
  'tag': 'HOM',
  'emblem': '⚽',
  'theme_id': 'pitch',
  'pattern_id': 'solid',
  'skill_rating': 1500,
};

const _awayClanJson = <String, dynamic>{
  'id': 'away',
  'name': 'Away',
  'tag': 'AWY',
  'emblem': '⚽',
  'theme_id': 'shadow',
  'pattern_id': 'solid',
  'skill_rating': 1500,
};
