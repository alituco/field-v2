import 'package:field/src/fixtures/fixture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'legacy clan kickoff combines its date and time in the stored market',
    () {
      Fixture fixture(String slot) => Fixture.fromJson({
        'id': 'fixture',
        'home_clan_id': 'clan',
        'match_date': '2026-10-13',
        'time_slot': slot,
        'home_clan': {'id': 'clan', 'name': 'Clan'},
      });

      expect(
        fixture('7:00 PM - 8:00 PM').scheduledStartAt,
        DateTime.utc(2026, 10, 13, 16),
      );
      expect(
        fixture('8:30 PM - 9:30 PM').scheduledStartAt,
        DateTime.utc(2026, 10, 13, 17, 30),
      );
      // The calendar date must not make a tonight fixture expire at midnight.
      expect(
        fixture(
          '8:30 PM - 9:30 PM',
        ).scheduledStartAt.isAfter(DateTime.utc(2026, 10, 13, 10)),
        isTrue,
      );
    },
  );
}
