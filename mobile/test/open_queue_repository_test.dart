import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hydrateUpcomingOpenQueueBookings', () {
    final now = DateTime(2026, 7, 15, 12);

    test('returns both active bookings hydrated and ordered by kickoff', () {
      final early = _game(
        id: 'game-early',
        startsAt: now.add(const Duration(days: 1)),
        venue: 'TFA, Saar',
        confirmedCount: 8,
      );
      final later = _game(
        id: 'game-later',
        startsAt: now.add(const Duration(days: 3)),
        venue: 'Busaiteen Arena',
        status: 'FULL',
        confirmedCount: 12,
      );
      final staleEarly = _game(
        id: early.id,
        startsAt: early.startsAt,
        venue: 'Old venue snapshot',
        confirmedCount: 4,
      );
      final staleLater = _game(
        id: later.id,
        startsAt: later.startsAt,
        venue: 'Old venue snapshot',
        confirmedCount: 7,
      );

      final result = hydrateUpcomingOpenQueueBookings(
        now: now,
        bookings: [
          _booking(id: 'booking-later', game: staleLater),
          _booking(id: 'booking-early', game: staleEarly),
          _booking(id: 'booking-early', game: staleEarly),
        ],
        games: [later, early],
      );

      expect(result.map((booking) => booking.id), [
        'booking-early',
        'booking-later',
      ]);
      expect(result.first.game.venue, 'TFA, Saar');
      expect(result.first.game.confirmedCount, 8);
      expect(result.last.game.venue, 'Busaiteen Arena');
      expect(result.last.game.confirmedCount, 12);
    });

    test('removes scored, played, cancelled, and cancelled-booking rows', () {
      final valid = _game(
        id: 'valid',
        startsAt: now.add(const Duration(hours: 4)),
      );
      final scored = _game(
        id: 'scored',
        startsAt: now.add(const Duration(hours: 3)),
        whiteScore: 2,
        blackScore: 1,
      );
      final played = _game(
        id: 'played',
        startsAt: now.subtract(const Duration(minutes: 1)),
      );
      final cancelled = _game(
        id: 'cancelled',
        startsAt: now.add(const Duration(hours: 5)),
        status: 'CANCELLED',
      );
      final finalGame = _game(
        id: 'final',
        startsAt: now.add(const Duration(hours: 6)),
        status: 'FINAL',
      );

      final result = hydrateUpcomingOpenQueueBookings(
        now: now,
        bookings: [
          _booking(id: 'valid-booking', game: valid),
          _booking(id: 'scored-booking', game: scored),
          _booking(id: 'played-booking', game: played),
          _booking(id: 'cancelled-game-booking', game: cancelled),
          _booking(id: 'final-game-booking', game: finalGame),
          _booking(id: 'cancelled-booking', game: valid, status: 'CANCELLED'),
        ],
        games: [valid, scored, played, cancelled, finalGame],
      );

      expect(result, hasLength(1));
      expect(result.single.id, 'valid-booking');
    });
  });

  test('a game at or before the cutoff is not an upcoming reservation', () {
    final now = DateTime(2026, 7, 15, 12);
    expect(_game(id: 'now', startsAt: now).isUpcomingReservationAt(now), false);
    expect(
      _game(
        id: 'future',
        startsAt: now.add(const Duration(seconds: 1)),
      ).isUpcomingReservationAt(now),
      true,
    );
  });

  test('team assignment becomes due exactly three hours before kickoff', () {
    final kickoff = DateTime.utc(2026, 7, 21, 17, 30);
    final game = _game(
      id: 'team-cutoff',
      startsAt: kickoff,
      status: 'FULL',
      confirmedCount: 12,
    );
    final cutoff = kickoff.subtract(const Duration(hours: 3));

    expect(
      game.isTeamAssignmentDueAt(
        cutoff.subtract(const Duration(milliseconds: 1)),
      ),
      false,
    );
    expect(game.teamAssignmentAt, cutoff);
    expect(game.isTeamAssignmentDueAt(cutoff), true);
    expect(
      game.isTeamAssignmentDueAt(cutoff.add(const Duration(minutes: 1))),
      true,
    );
  });
}

OpenQueueGame _game({
  required String id,
  required DateTime startsAt,
  String status = 'OPEN',
  String venue = 'TFA, Saar',
  int confirmedCount = 6,
  int? whiteScore,
  int? blackScore,
}) {
  return OpenQueueGame(
    id: id,
    status: status,
    venue: venue,
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: '16+',
    capacity: 12,
    confirmedCount: confirmedCount,
    spots: const {},
    whiteScore: whiteScore,
    blackScore: blackScore,
  );
}

OpenQueueBooking _booking({
  required String id,
  required OpenQueueGame game,
  String status = 'CONFIRMED',
}) {
  return OpenQueueBooking(
    id: id,
    gameId: game.id,
    profileId: 'player-1',
    role: OpenQueueRole.midfielder,
    status: status,
    amountPaidFils: 3000,
    bookedAt: game.startsAt.subtract(const Duration(days: 1)),
    game: game,
  );
}
