import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 26, 13, 30);

  OpenQueueGame game({
    String id = 'game',
    String status = 'LIVE',
    MatchOperationalState operational = MatchOperationalState.normal,
    DateTime? actualStartedAt,
    DateTime? startsAt,
    int defenders = 4,
    int attackers = 8,
    int highest = 1,
    int lowest = 5,
  }) => OpenQueueGame(
    id: id,
    status: status,
    venue: 'Test pitch',
    startsAt: startsAt ?? DateTime.utc(2026, 10, 26, 11),
    endsAt: (startsAt ?? DateTime.utc(2026, 10, 26, 11)).add(
      const Duration(hours: 1),
    ),
    actualStartedAt: actualStartedAt,
    timezone: 'America/Phoenix',
    priceFils: 13000,
    currency: 'USD',
    ageLabel: '18+',
    capacity: 14,
    confirmedCount: 14,
    goalkeeperCapacity: 2,
    defenderCapacity: defenders,
    attackerCapacity: attackers,
    highestDivision: highest,
    lowestDivision: lowest,
    operationalState: operational,
    spots: const {},
  );

  test(
    'live registration expires at actual kickoff plus advertised duration',
    () {
      final delayed = game(actualStartedAt: DateTime.utc(2026, 10, 26, 13));
      expect(delayed.registrationEndsAt, DateTime.utc(2026, 10, 26, 14));
      expect(delayed.blocksNewBookingAt(now), isTrue);
      expect(
        delayed.blocksNewBookingAt(DateTime.utc(2026, 10, 26, 14)),
        isFalse,
      );
      expect(delayed.isActiveReservation, isTrue);
    },
  );

  test(
    'missing actual kickoff uses scheduled finish without hiding the game',
    () {
      final stale = game();
      expect(stale.blocksNewBookingAt(now), isFalse);
      expect(stale.isActiveReservation, isTrue);
    },
  );

  test('review and missing-data reservations stay visible but never block', () {
    for (final state in [
      MatchOperationalState.underReview,
      MatchOperationalState.noData,
    ]) {
      for (final status in ['OPEN', 'FULL', 'LIVE', 'FINAL']) {
        final unresolved = game(
          status: status,
          operational: state,
          actualStartedAt: now,
          startsAt: now,
        );
        expect(unresolved.isActiveReservation, isTrue);
        expect(unresolved.blocksNewBookingAt(now), isFalse);
      }
    }
  });

  test('future reservations block and closed games do not', () {
    expect(
      game(
        status: 'LIVE',
        startsAt: now,
        operational: MatchOperationalState.resolved,
      ).blocksNewBookingAt(now),
      isTrue,
    );
    for (final status in ['OPEN', 'FULL']) {
      expect(
        game(status: status, startsAt: now).blocksNewBookingAt(now),
        isTrue,
      );
      expect(game(status: status).blocksNewBookingAt(now), isFalse);
    }
    for (final status in ['FINAL', 'CANCELLED']) {
      expect(
        game(status: status, startsAt: now).blocksNewBookingAt(now),
        isFalse,
      );
    }
  });

  test('both game payload parsers retain the immutable actual kickoff', () {
    final json = <String, dynamic>{
      'id': 'game',
      'status': 'LIVE',
      'starts_at': '2026-10-26T11:00:00Z',
      'ends_at': '2026-10-26T12:00:00Z',
      'actual_started_at': '2026-10-26T13:00:00Z',
    };
    for (final parsed in [
      OpenQueueGame.fromJson(json),
      OpenQueueGame.fromBookingJson(json),
    ]) {
      expect(parsed.actualStartedAt?.toUtc(), DateTime.utc(2026, 10, 26, 13));
      expect(parsed.blocksNewBookingAt(now), isTrue);
    }
  });

  test('hydration retains old unresolved matches behind a current booking', () {
    OpenQueueBooking booking(OpenQueueGame g) => OpenQueueBooking(
      id: 'booking-${g.id}',
      gameId: g.id,
      profileId: 'me',
      role: OpenQueueRole.attacker,
      status: 'CONFIRMED',
      amountPaidFils: 13000,
      bookedAt: now,
      game: g,
    );
    final current = game(
      id: 'next',
      status: 'OPEN',
      startsAt: now.add(const Duration(days: 2)),
    );
    final review = game(
      id: 'review',
      operational: MatchOperationalState.underReview,
    );
    final stale = game(id: 'stale');
    final result = hydrateUpcomingOpenQueueBookings(
      bookings: [booking(stale), booking(review), booking(current)],
      games: [],
      now: now,
    );
    expect(result.map((b) => b.gameId), ['next', 'review', 'stale']);
  });

  test('position labels respect current, historical and mixed formations', () {
    final current = game();
    final historical = game(defenders: 6, attackers: 6);
    expect(
      roleCapacityLabelForGames(OpenQueueRole.goalkeeper, [current]),
      '1 slot per team',
    );
    expect(
      roleCapacityLabelForGames(OpenQueueRole.defender, [current]),
      '2 slots per team',
    );
    expect(
      roleCapacityLabelForGames(OpenQueueRole.attacker, [current]),
      '4 slots per team',
    );
    expect(
      roleCapacityLabelForGames(OpenQueueRole.defender, [historical]),
      '3 slots per team',
    );
    expect(
      roleCapacityLabelForGames(OpenQueueRole.defender, [current, historical]),
      'Varies by game',
    );
    expect(
      roleCapacityLabelForGames(OpenQueueRole.attacker, []),
      '4 slots per team',
    );
    expect(
      roleCapacityLabelForGames(OpenQueueRole.defender, []),
      '2 slots per team',
    );
    expect(OpenQueueRole.defender.matchCapacity, 6);
  });

  test(
    'placement admits any division without relaxing revealed division ranges',
    () {
      final restricted = game(highest: 1, lowest: 1);
      for (final played in [0, 1]) {
        expect(
          restricted.allowsPlayerDivision(
            skillRating: 800,
            matchesPlayed: played,
          ),
          isTrue,
        );
      }
      expect(
        restricted.allowsPlayerDivision(skillRating: 800, matchesPlayed: 2),
        isFalse,
      );
      expect(
        restricted.allowsPlayerDivision(skillRating: 1800, matchesPlayed: 2),
        isTrue,
      );
    },
  );
}
