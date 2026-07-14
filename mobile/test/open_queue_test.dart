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

  test('fixture feed games parse results and the caller booking safely', () {
    final game = OpenQueueGame.fromJson({
      'id': 'solo-final',
      'status': 'FINAL',
      'venue': 'TFA, Saar',
      'starts_at': '2026-07-14T17:30:00Z',
      'ends_at': '2026-07-14T18:30:00Z',
      'timezone': 'Asia/Bahrain',
      'price_fils': 3000,
      'age_label': 'All ages',
      'capacity': 12,
      'confirmed_count': 12,
      'goalkeeper_spots': 0,
      'defender_spots': 0,
      'midfielder_spots': 0,
      'attacker_spots': 0,
      'white_score': 5,
      'black_score': 3,
      'my_booking_id': 'booking-1',
      'my_booking_role': 'ATT',
      'my_booking_team': 'WHITE',
      'white_average_sr': 1237.6,
      'black_average_sr': 1232.7,
      'match_average_sr': 1235.15,
      'team_sr_spread': 4.9,
      'teams_assigned_at': '2026-07-13T12:00:00Z',
    });

    expect(game.status, 'FINAL');
    expect(game.whiteScore, 5);
    expect(game.blackScore, 3);
    expect(game.confirmedCount, 12);
    expect(game.hasMyBooking, isTrue);
    expect(game.myBookingRole, OpenQueueRole.attacker);
    expect(game.myBookingTeam, 'WHITE');
    expect(game.whiteAverageSr, 1238);
    expect(game.blackAverageSr, 1233);
    expect(game.matchAverageSr, 1235);
    expect(game.teamSrSpread, 5);
    expect(game.teamsAssignedAt, isNotNull);
    expect(game.bahrainStartsAt.weekday, DateTime.tuesday);
    expect(game.timeLabel, '8:30 PM–9:30 PM');
  });

  test('solo match detail maps teams, clock, goals, and replay data', () {
    final detail = OpenQueueMatchDetail.fromJson({
      'id': 'solo-detail',
      'status': 'FINAL',
      'venue': 'TFA, Saar',
      'starts_at': '2026-07-14T17:30:00Z',
      'ends_at': '2026-07-14T18:30:00Z',
      'timezone': 'Asia/Bahrain',
      'price_fils': 3000,
      'age_label': 'All ages',
      'capacity': 12,
      'confirmed_count': 12,
      'goalkeeper_spots': 0,
      'defender_spots': 0,
      'midfielder_spots': 0,
      'attacker_spots': 0,
      'white_score': 1,
      'black_score': 0,
      'white_average_sr': 1211,
      'black_average_sr': 1209,
      'match_average_sr': 1210,
      'team_sr_spread': 2,
      'teams_assigned_at': '2026-07-13T12:00:00Z',
      'clock_status': 'ENDED',
      'clock_accumulated_seconds': 3600,
      'clock_duration_seconds': 3600,
      'broadcast_status': 'REPLAY_READY',
      'replay_hls_url': 'https://example.com/solo-replay.m3u8',
      'stream_started_at': '2026-07-14T17:30:00Z',
      'stream_stopped_at': '2026-07-14T18:30:00Z',
      'events': [
        {
          'id': 'goal-one',
          'game_id': 'solo-detail',
          'event_type': 'GOAL',
          'team': 'WHITE',
          'profile_id': 'player-one',
          'minute': 24,
          'second': 11,
          'occurred_at': '2026-07-14T17:54:11Z',
          'created_at': '2026-07-14T17:54:11Z',
          'player': {
            'id': 'player-one',
            'display_name': 'Solo Scorer',
            'username': 'solo.scorer',
          },
        },
      ],
      'players': [
        {
          'id': 'player-one',
          'display_name': 'Solo Scorer',
          'username': 'solo.scorer',
          'role': 'ATT',
          'team': 'WHITE',
          'played': true,
          'is_me': true,
          'rating_at_team_assignment': 1220,
          'rating_at_match_start': 1224,
          'rating_change': 11,
        },
        {
          'id': 'player-two',
          'display_name': 'Solo Keeper',
          'username': 'solo.keeper',
          'role': 'GK',
          'team': 'BLACK',
          'played': true,
          'is_me': false,
          'rating_at_team_assignment': 1209,
          'rating_at_match_start': 1210,
          'rating_change': -10,
        },
      ],
    });

    final fixture = detail.toFixture();
    expect(fixture.homeClan.name, 'White Team');
    expect(fixture.awayClan?.name, 'Black Team');
    expect(fixture.homeScore, 1);
    expect(fixture.awayScore, 0);
    expect(fixture.homeAveragePlayerRating, 1211);
    expect(fixture.awayAveragePlayerRating, 1209);
    expect(fixture.matchAveragePlayerRating, 1210);
    expect(fixture.teamRatingSpread, 2);
    expect(fixture.homeClan.skillRating, 1211);
    expect(fixture.awayClan?.skillRating, 1209);
    expect(fixture.homeLineup.single.displayName, 'Solo Scorer');
    expect(fixture.homeLineup.single.isMe, isTrue);
    expect(fixture.homeLineup.single.displayedRating, 1224);
    expect(fixture.homeLineup.single.ratingChange, 11);
    expect(fixture.awayLineup.single.role, 'GK');
    expect(fixture.clock?.status, 'ENDED');
    expect(fixture.fullGamePlaybackUrl, contains('solo-replay'));
    expect(fixture.timeline.single.clanId, openQueueWhiteTeamId);
    expect(fixture.scorers.single.scorerName, 'Solo Scorer');
    expect(
      fixture.highlightMoments.single.start,
      const Duration(minutes: 24, seconds: 1),
    );
    expect(
      fixture.highlightMoments.single.end,
      const Duration(minutes: 24, seconds: 21),
    );
  });
}
