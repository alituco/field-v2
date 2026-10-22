import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/ranking/rating_division.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'configured minimum is total players and remains separate from full capacity',
    () {
      final base = <String, dynamic>{
        'id': 'small-game',
        'status': 'OPEN',
        'capacity': 14,
        'starts_at': '2099-01-01T00:00:00Z',
        'ends_at': '2099-01-01T01:00:00Z',
        'confirmed_count': 2,
        'minimum_players': 2,
        'participation_rules_version': 's0-configurable-v1',
        'teams_assigned_at': '2098-12-31T23:00:00Z',
      };
      for (final game in [
        OpenQueueGame.fromJson(base),
        OpenQueueGame.fromBookingJson(base),
      ]) {
        expect(game.minimumPlayers, 2);
        expect(game.hasMinimumPlayers, isTrue);
        expect(game.isFull, isFalse);
        expect(game.isUpcomingMatchConfirmed, isTrue);
        expect(game.hasActiveTeamAssignment, isTrue);
        expect(game.statusLabel, 'Minimum reached');
        expect(game.minimumPlayersLabel, '2 minimum · 14 maximum');
      }
      final below = OpenQueueGame.fromJson({...base, 'minimum_players': 3});
      expect(below.hasMinimumPlayers, isFalse);
      expect(below.isUpcomingMatchConfirmed, isFalse);
      expect(
        below.minimumPlayersProgressLabel,
        '1 more needed · 3 minimum · 14 maximum',
      );
      final odd = OpenQueueGame.fromJson({
        ...base,
        'minimum_players': 3,
        'confirmed_count': 3,
      });
      expect(odd.hasMinimumPlayers, isTrue);
      final old = OpenQueueGame.fromJson({
        ...base,
        'participation_rules_version': 's0-standard-v1',
      });
      expect(old.hasMinimumPlayers, isFalse);
      expect(old.isUpcomingMatchConfirmed, isFalse);
      expect(old.statusLabel, 'Spots available');
      final malformed = OpenQueueGame.fromJson({...base, 'minimum_players': 1});
      expect(malformed.hasMinimumPlayers, isFalse);
      expect(malformed.requiredMinimumPlayers, 14);
    },
  );

  test(
    'game division ranges describe server admission and preserve old all-division games',
    () {
      OpenQueueGame game(int highest, int lowest) => OpenQueueGame(
        id: 'game',
        status: 'OPEN',
        venue: 'Phoenix',
        startsAt: DateTime.utc(2099),
        endsAt: DateTime.utc(2099, 1, 1, 1),
        timezone: 'America/Phoenix',
        priceFils: 13000,
        ageLabel: '18+',
        capacity: 14,
        confirmedCount: 0,
        spots: const {},
        highestDivision: highest,
        lowestDivision: lowest,
      );
      final restricted = game(2, 4);
      expect(restricted.divisionRangeLabel, 'DIV 2–4');
      expect(restricted.allowedDivisions, [2, 3, 4]);
      expect(
        restricted.allowsPlayerDivision(skillRating: 1200, matchesPlayed: 1),
        isFalse,
      );
      expect(
        restricted.allowsPlayerDivision(skillRating: 1200, matchesPlayed: 2),
        isTrue,
      );
      expect(
        restricted.allowsPlayerDivision(skillRating: 1099, matchesPlayed: 2),
        isFalse,
      );
      expect(
        restricted.allowsPlayerDivision(skillRating: 1650, matchesPlayed: 2),
        isFalse,
      );
      expect(
        game(1, 5).allowsPlayerDivision(skillRating: 1200, matchesPlayed: 0),
        isTrue,
      );
      expect(game(3, 3).divisionRangeLabel, 'DIV 3');
      final json = <String, dynamic>{
        'id': 'game',
        'starts_at': '2099-01-01T00:00:00Z',
        'ends_at': '2099-01-01T01:00:00Z',
        'highest_division': 2,
        'lowest_division': 4,
      };
      for (final parsed in [
        OpenQueueGame.fromJson(json),
        OpenQueueGame.fromBookingJson(json),
      ]) {
        expect(parsed.allowedDivisions, [2, 3, 4]);
      }
      json.remove('highest_division');
      json.remove('lowest_division');
      expect(OpenQueueGame.fromJson(json).acceptsPlacementPlayers, isTrue);
    },
  );
  test('Player Rating uses the shared five-division thresholds', () {
    expect(ratingDivisionLabel(0), 'Division 5');
    expect(ratingDivisionLabel(1099), 'Division 5');
    expect(ratingDivisionLabel(1100), 'Division 4');
    expect(ratingDivisionLabel(1299), 'Division 4');
    expect(ratingDivisionLabel(1300), 'Division 3');
    expect(ratingDivisionLabel(1499), 'Division 3');
    expect(ratingDivisionLabel(1500), 'Division 2');
    expect(ratingDivisionLabel(1649), 'Division 2');
    expect(ratingDivisionLabel(1650), 'Division 1');
    expect(ratingDivisionLabel(2600), 'Division 1');
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

  test('older 7v7 payloads retain their original 1/3/3 formation', () {
    expect(OpenQueueRole.goalkeeper.matchCapacity, 2);
    expect(OpenQueueRole.defender.matchCapacity, 6);
    expect(OpenQueueRole.midfielder.matchCapacity, 0);
    expect(OpenQueueRole.attacker.matchCapacity, 6);
    expect(OpenQueueRole.midfielder.legacyMatchCapacity, 4);
    expect(
      OpenQueueRole.values.fold<int>(
        0,
        (total, role) => total + role.matchCapacity,
      ),
      14,
    );
  });

  group('saved game formation', () {
    Map<String, dynamic> gameJson({int capacity = 14}) => {
      'id': 'formation-game',
      'status': 'OPEN',
      'starts_at': '2099-01-01T00:00:00Z',
      'ends_at': '2099-01-01T01:00:00Z',
      'capacity': capacity,
      'goalkeeper_spots': 2,
      'defender_spots': 4,
      'midfielder_spots': 0,
      'attacker_spots': 8,
    };

    test(
      'feed, match detail and booking history use saved 1/2/4 capacities',
      () {
        final json = {
          ...gameJson(),
          'goalkeeper_capacity': 2,
          'defender_capacity': 4,
          'midfielder_capacity': 0,
          'attacker_capacity': 8,
        };
        for (final game in [
          OpenQueueGame.fromJson(json),
          OpenQueueGame.fromBookingJson(json),
          OpenQueueMatchDetail.fromJson({'game': json}).game,
        ]) {
          expect(game.goalkeeperCapacity, 2);
          expect(game.defenderCapacity, 4);
          expect(game.midfielderCapacity, 0);
          expect(game.attackerCapacity, 8);
          expect(game.capacityFor(OpenQueueRole.goalkeeper), 2);
          expect(game.capacityFor(OpenQueueRole.defender), 4);
          expect(game.capacityFor(OpenQueueRole.midfielder), 0);
          expect(game.capacityFor(OpenQueueRole.attacker), 8);
        }
      },
    );

    test('omitted capacity metadata preserves old 7v7 and 6v6 history', () {
      for (final parse in [
        OpenQueueGame.fromJson,
        OpenQueueGame.fromBookingJson,
      ]) {
        final seven = parse(gameJson());
        expect(seven.goalkeeperCapacity, isNull);
        expect(seven.defenderCapacity, isNull);
        expect(seven.attackerCapacity, isNull);
        expect(seven.capacityFor(OpenQueueRole.goalkeeper), 2);
        expect(seven.capacityFor(OpenQueueRole.defender), 6);
        expect(seven.capacityFor(OpenQueueRole.midfielder), 0);
        expect(seven.capacityFor(OpenQueueRole.attacker), 6);
        final six = parse(gameJson(capacity: 12));
        expect(six.capacityFor(OpenQueueRole.goalkeeper), 2);
        expect(six.capacityFor(OpenQueueRole.defender), 4);
        expect(six.capacityFor(OpenQueueRole.midfielder), 4);
        expect(six.capacityFor(OpenQueueRole.attacker), 2);
      }
    });

    test('zero defender capacity stays unavailable even with stale spots', () {
      final game = OpenQueueGame.fromJson({
        ...gameJson(),
        'goalkeeper_capacity': 2,
        'defender_capacity': 0,
        'midfielder_capacity': 0,
        'attacker_capacity': 12,
      });
      expect(game.capacityFor(OpenQueueRole.defender), 0);
      expect(game.canBook(OpenQueueRole.defender), isFalse);
      expect(game.canBook(OpenQueueRole.attacker), isTrue);
    });

    test('booking copies keep their saved formation', () {
      final booking = OpenQueueBooking.fromJson({
        'id': 'booking',
        'game_id': 'formation-game',
        'profile_id': 'profile',
        'role': 'ATT',
        'status': 'CONFIRMED',
        'amount_paid_fils': 13000,
        'booked_at': '2098-12-31T12:00:00Z',
        'game': {
          ...gameJson(),
          'goalkeeper_capacity': 2,
          'defender_capacity': 4,
          'midfielder_capacity': 0,
          'attacker_capacity': 8,
        },
      });
      final copied = booking.copyWith();
      expect(copied.game.capacityFor(OpenQueueRole.defender), 4);
      expect(copied.game.capacityFor(OpenQueueRole.attacker), 8);
      expect(copied.role, OpenQueueRole.attacker);
    });
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
      'policy_version_id': 'policy-v2',
      'team_assignment_at': '2026-07-14T16:00:00Z',
      'party_lock_at': '2026-07-14T15:30:00Z',
      'team_assignment_lead_minutes': 90,
      'party_lock_lead_minutes': 120,
      'max_party_size': 3,
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
    expect(game.policyVersionId, 'policy-v2');
    expect(game.teamAssignmentLeadLabel, '1 hour 30 minutes before kickoff');
    expect(game.partyLockLeadLabel, '2 hours before kickoff');
    expect(game.maxPartySize, 3);
    expect(game.bahrainStartsAt.weekday, DateTime.tuesday);
    expect(game.timeLabel, '8:30 PM–9:30 PM');
  });

  test('pending booking ignores a stale team assignment', () {
    final booking = OpenQueueBooking.fromJson({
      'id': 'booking',
      'game_id': 'game',
      'profile_id': 'profile',
      'role': 'MID',
      'status': 'CONFIRMED',
      'team': ' white ',
      'amount_paid_fils': 3000,
      'booked_at': '2026-07-14T12:00:00Z',
      'game': {
        'id': 'game',
        'status': 'OPEN',
        'venue': 'TFA, Saar',
        'starts_at': '2026-07-15T17:30:00Z',
        'ends_at': '2026-07-15T18:30:00Z',
        'timezone': 'Asia/Bahrain',
        'price_fils': 3000,
        'age_label': 'All ages',
        'capacity': 12,
        'confirmed_count': 8,
      },
    });

    expect(booking.game.confirmedCount, 8);
    expect(booking.game.isFull, isFalse);
    expect(booking.assignedTeam, isNull);
    expect(booking.kitInstruction, isNull);
  });

  for (final team in [openQueueWhiteTeamId, openQueueBlackTeamId]) {
    test('assigned $team kit does not depend on public SR aggregates', () {
      final booking = _privacyMaskedAssignment(team: team);

      expect(booking.game.hasActiveTeamAssignment, isTrue);
      expect(booking.assignedTeam, team);
      expect(booking.kitInstruction, 'WEAR $team');
      expect(booking.game.whiteAverageSr, isNull);
      expect(booking.game.blackAverageSr, isNull);
      expect(booking.game.matchAverageSr, isNull);
      expect(booking.game.teamSrSpread, isNull);
    });
  }

  test('privacy-independent assignment retains canonical readiness guards', () {
    for (final overrides in <Map<String, Object?>>[
      {'status': 'OPEN'},
      {'confirmed_count': 13},
      {'capacity': 0, 'confirmed_count': 0},
      {'teams_assigned_at': null},
      {'team_assignment_at': '2099-01-01T00:00:00Z'},
      {'white_score': 1, 'black_score': 0},
      {'status': 'CANCELLED'},
    ]) {
      final booking = _privacyMaskedAssignment(gameOverrides: overrides);
      expect(
        booking.game.hasActiveTeamAssignment,
        isFalse,
        reason: '$overrides',
      );
      expect(booking.assignedTeam, isNull, reason: '$overrides');
      expect(booking.kitInstruction, isNull, reason: '$overrides');
    }
    final invalidTeam = _privacyMaskedAssignment(team: 'GREEN');
    expect(invalidTeam.game.hasActiveTeamAssignment, isTrue);
    expect(invalidTeam.assignedTeam, isNull);
    expect(invalidTeam.kitInstruction, isNull);
  });

  test('played or scored games are never upcoming reservations', () {
    final startsAt = DateTime.now().add(const Duration(days: 10));
    OpenQueueGame game({required String status, int? whiteScore}) {
      return OpenQueueGame(
        id: '$status-$whiteScore',
        status: status,
        venue: 'TFA, Saar',
        startsAt: startsAt,
        endsAt: startsAt.add(const Duration(hours: 1)),
        timezone: 'Asia/Bahrain',
        priceFils: 3000,
        ageLabel: 'All ages',
        capacity: 12,
        confirmedCount: 12,
        spots: const {},
        whiteScore: whiteScore,
        blackScore: whiteScore == null ? null : 1,
      );
    }

    expect(game(status: 'FULL').isUpcomingReservation, isTrue);
    expect(game(status: 'FINAL', whiteScore: 2).isUpcomingReservation, isFalse);
    expect(game(status: 'OPEN', whiteScore: 2).isUpcomingReservation, isFalse);
  });

  test('party invite notifications parse their navigation context', () {
    final notification = OpenQueuePartyInviteNotification.fromJson({
      'notification_id': 'notification-one',
      'type': 'OPEN_QUEUE_PARTY_INVITE',
      'game_id': 'game-one',
      'party_id': 'party-one',
      'membership_id': 'membership-one',
      'created_at': '2026-07-15T12:00:00Z',
      'read_at': null,
      'is_read': false,
      'inviter': {
        'profile_id': 'sami',
        'display_name': 'Sami Nasser',
        'username': 'sami',
        'avatar_url': null,
      },
      'game': {
        'starts_at': '2026-07-17T17:30:00Z',
        'venue': 'TFA, Saar',
        'status': 'OPEN',
        'party_lock_at': '2026-07-17T14:30:00Z',
        'policy_version_id': 'policy-v2',
      },
    });

    expect(notification.id, 'notification-one');
    expect(notification.gameId, 'game-one');
    expect(notification.membershipId, 'membership-one');
    expect(notification.inviter.displayName, 'Sami Nasser');
    expect(notification.venue, 'TFA, Saar');
    expect(notification.gameStatus, 'OPEN');
    expect(notification.gameStartsAt, isNotNull);
    expect(notification.partyLockAt, isNotNull);
    expect(notification.policyVersionId, 'policy-v2');
    expect(notification.isRead, isFalse);
  });

  test('party candidates expose their current party without hiding them', () {
    final context = OpenQueuePartyContext.fromJson({
      'game_id': 'game-one',
      'game_status': 'OPEN',
      'can_use_parties': true,
      'max_party_size': 4,
      'received_invites': const [],
      'eligible_players': [
        {
          'profile_id': 'layla',
          'display_name': 'Layla Abbas',
          'role': 'MID',
          'is_in_party': true,
          'current_party_id': 'party-two',
          'is_current_party_owner': true,
          'current_party_size': 3,
        },
      ],
    });

    expect(context.eligiblePlayers, hasLength(1));
    final player = context.eligiblePlayers.single;
    expect(player.isInParty, isTrue);
    expect(player.currentPartyId, 'party-two');
    expect(player.isCurrentPartyOwner, isTrue);
    expect(player.currentPartySize, 3);
  });

  test('party context parses its snapshotted server policy', () {
    final context = OpenQueuePartyContext.fromJson({
      'game_id': 'policy-game',
      'game_status': 'FULL',
      'can_use_parties': true,
      'policy_version_id': 'policy-v2',
      'server_now': '2026-07-16T12:00:00Z',
      'team_assignment_at': '2026-07-17T16:00:00Z',
      'party_lock_at': '2026-07-17T15:15:00Z',
      'team_assignment_lead_minutes': 90,
      'party_lock_lead_minutes': 135,
      'max_party_size': 3,
      'received_invites': const [],
      'eligible_players': const [],
    });

    expect(context.policyVersionId, 'policy-v2');
    expect(context.maxPartySize, 3);
    expect(context.teamAssignmentAt, isNotNull);
    expect(context.partyLockAt, isNotNull);
    expect(context.teamAssignmentLeadLabel, '1 hour 30 minutes before kickoff');
    expect(context.partyLockLeadLabel, '2 hours 15 minutes before kickoff');
  });

  test(
    'solo lobby aggregate is independent of individual rating visibility',
    () {
      final detail = OpenQueueMatchDetail.fromJson({
        'game': {
          'id': 'solo-detail',
          'status': 'OPEN',
          'starts_at': '2026-10-23T01:00:00Z',
          'ends_at': '2026-10-23T02:00:00Z',
        },
        'lobby_average_sr': 1150.4,
        'players': [
          {
            'id': 'placement-player',
            'display_name': 'Placement Player',
            'role': 'DEF',
            'skill_rating': null,
            'rating_at_match_start': null,
            'rating_at_team_assignment': null,
            'rating_visible': false,
            'matches_played': 1,
          },
        ],
      });
      expect(detail.lobbyAverageSr, 1150);
      expect(detail.players.single.displayedRating, isNull);
      expect(
        OpenQueueMatchDetail.fromJson({
          'game': {
            'id': 'legacy',
            'starts_at': '2026-10-23T01:00:00Z',
            'ends_at': '2026-10-23T02:00:00Z',
          },
        }).lobbyAverageSr,
        isNull,
      );
    },
  );

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
      const Duration(minutes: 24, seconds: 31),
    );
  });
}

OpenQueueBooking _privacyMaskedAssignment({
  String team = openQueueWhiteTeamId,
  Map<String, Object?> gameOverrides = const {},
}) => OpenQueueBooking.fromJson({
  'id': 'booking',
  'game_id': 'game',
  'profile_id': 'profile',
  'role': 'ATT',
  'status': 'CONFIRMED',
  'team': team,
  'amount_paid_fils': 8000,
  'booked_at': '2026-10-15T12:00:00Z',
  'game': {
    'id': 'game',
    'status': 'FULL',
    'venue': 'Reach 11 Fields',
    'starts_at': '2099-01-01T01:00:00Z',
    'ends_at': '2099-01-01T02:00:00Z',
    'timezone': 'America/Phoenix',
    'currency': 'USD',
    'price_fils': 8000,
    'capacity': 14,
    'confirmed_count': 14,
    'teams_assigned_at': '2000-01-01T00:00:00Z',
    'team_assignment_at': '2000-01-01T00:00:00Z',
    'white_average_sr': null,
    'black_average_sr': null,
    'match_average_sr': null,
    'team_sr_spread': null,
    ...gameOverrides,
  },
});
