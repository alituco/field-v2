import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Player Rating tiers use independent rating thresholds', () {
    expect(playerRatingTier(0), 'Bronze III');
    expect(playerRatingTier(799), 'Bronze I');
    expect(playerRatingTier(800), 'Silver III');
    expect(playerRatingTier(1200), 'Gold III');
    expect(playerRatingTier(1600), 'Platinum III');
    expect(playerRatingTier(2000), 'Diamond III');
    expect(playerRatingTier(2600), 'Diamond I');
  });

  test(
    'a full game cannot book any role and never creates a waitlist state',
    () {
      final game = OpenQueueGame(
        id: 'game',
        status: 'FULL',
        venue: 'TFA, Saar',
        startsAt: DateTime.now().add(const Duration(days: 2)),
        endsAt: DateTime.now().add(const Duration(days: 2, hours: 1)),
        timezone: 'Asia/Bahrain',
        priceFils: 3000,
        ageLabel: 'All ages',
        capacity: 12,
        confirmedCount: 12,
        spots: const {
          OpenQueueRole.goalkeeper: 0,
          OpenQueueRole.defender: 0,
          OpenQueueRole.midfielder: 0,
          OpenQueueRole.attacker: 0,
        },
      );

      expect(game.isFull, isTrue);
      for (final role in OpenQueueRole.values) {
        expect(game.canBook(role), isFalse);
      }
      expect(game.status, isNot('WAITLIST'));
    },
  );

  test('role caps match balanced six-a-side teams', () {
    expect(OpenQueueRole.goalkeeper.matchCapacity, 2);
    expect(OpenQueueRole.defender.matchCapacity, 4);
    expect(OpenQueueRole.midfielder.matchCapacity, 4);
    expect(OpenQueueRole.attacker.matchCapacity, 2);
    expect(
      OpenQueueRole.values.fold<int>(
        0,
        (total, role) => total + role.matchCapacity,
      ),
      12,
    );
  });
}
