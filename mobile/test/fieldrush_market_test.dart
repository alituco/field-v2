import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final kickoff = DateTime.utc(2026, 10, 10, 3, 30);
  OpenQueueGame game({
    int capacity = 14,
    String status = 'OPEN',
    String? booking,
    String currency = 'USD',
    DateTime? start,
    int durationMinutes = 60,
  }) => OpenQueueGame(
    id: 'game',
    status: status,
    venue: 'Phoenix',
    startsAt: start ?? kickoff,
    endsAt: (start ?? kickoff).add(Duration(minutes: durationMinutes)),
    timezone: 'America/Phoenix',
    priceFils: 13000,
    currency: currency,
    ageLabel: '18+',
    capacity: capacity,
    confirmedCount: 0,
    myBookingId: booking,
    spots: const {
      OpenQueueRole.goalkeeper: 2,
      OpenQueueRole.defender: 6,
      OpenQueueRole.midfielder: 4,
      OpenQueueRole.attacker: 6,
    },
  );

  test('Phoenix game uses Friday local time despite Saturday UTC', () {
    expect(game().localStartsAt, DateTime.utc(2026, 10, 9, 20, 30));
    expect(game().startTimeLabel, '8:30 PM');
    expect(
      gameLocalDateTime(kickoff, 'Asia/Bahrain'),
      DateTime.utc(2026, 10, 10, 6, 30),
    );
  });
  test('7v7 excludes MID even if a stale feed reports MID spots', () {
    final now = kickoff.subtract(const Duration(days: 1));
    expect(game().supportedRoles, fieldrushOpenQueueRoles);
    expect(game().capacityFor(OpenQueueRole.defender), 6);
    expect(game().canBookAt(OpenQueueRole.midfielder, now), isFalse);
    expect(game().canBookAt(OpenQueueRole.attacker, now), isTrue);
    expect(game(capacity: 12).canBookAt(OpenQueueRole.midfielder, now), isTrue);
    expect(
      game(status: 'CANCELLED').canBookAt(OpenQueueRole.attacker, now),
      isFalse,
    );
    expect(
      game(booking: 'mine').canBookAt(OpenQueueRole.attacker, now),
      isFalse,
    );
    expect(game().canBookAt(OpenQueueRole.attacker, kickoff), isFalse);
  });

  test(
    'all seven Phoenix matchdays support configured kickoff and duration',
    () {
      final monday = DateTime.utc(2026, 10, 6, 1, 15);
      for (var day = 0; day < 7; day++) {
        for (final minutes in [30, 90, 180]) {
          final start = monday.add(Duration(days: day));
          final value = game(start: start, durationMinutes: minutes);
          expect(value.localStartsAt.weekday, day + 1);
          expect(value.startTimeLabel, '6:15 PM');
          expect(
            value.localEndsAt.difference(value.localStartsAt).inMinutes,
            minutes,
          );
          expect(
            value.canBookAt(
              OpenQueueRole.defender,
              start.subtract(const Duration(hours: 1)),
            ),
            isTrue,
          );
        }
      }
    },
  );

  test(
    'late Saturday slot can finish Sunday without changing its matchday',
    () {
      final value = game(
        start: DateTime.utc(2026, 10, 11, 6, 15),
        durationMinutes: 90,
      );
      expect(value.calendarDateLabel, 'SAT, 10 OCT');
      expect(value.timeLabel, '11:15 PM–12:45 AM');
      expect(value.localEndsAt.weekday, DateTime.sunday);
    },
  );
  test('USD uses cents and legacy BHD is not relabeled', () {
    expect(game().priceLabel, r'$13.00');
    expect(game(currency: 'BHD').priceLabel, '13 BHD');
    final quote = OpenQueueBookingCostPreview.fromJson({
      'currency': 'USD',
      'total_fils': 13000,
    });
    expect(quote.totalLabel, r'$13.00');
    final refund = OpenQueueCancellationPreview.fromJson({
      'currency': 'USD',
      'refund_bps': 10000,
      'refund_percent': 100,
      'refund_amount_fils': 13000,
    });
    expect(refund.refundLabel, r'$13.00 to Field wallet');
  });
  test('city is only displayed when supplied by the server', () {
    expect(FieldrushAccount.fromJson({}).homeCity, isNull);
    final account = FieldrushAccount.fromJson({
      'home_city': 'Phoenix, AZ',
      'ranking_region': 'phoenix',
      'home_city_locked': true,
    });
    expect(account.homeCity, 'Phoenix, AZ');
    expect(account.rankingRegion, 'phoenix');
    expect(account.homeCityLocked, isTrue);
  });
}
