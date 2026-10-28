import 'package:field/src/clans/clan.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/fieldrush_rating_tracks.dart';
import 'package:field/src/leaderboard/fieldrush_placement.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/profile/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final count in [0, 1, 2, 9, 10]) {
    test(
      'public rating count $count is independent of season participation',
      () {
        final json = _rating(count);
        final rating = PlayerRatingLeaderboardEntry.fromJson(json);
        final profile = ProfilePlayerRating.fromJson(json);
        for (final value in [rating, profile]) {
          expect(value.ratingVisible, count >= 2);
          expect(value.provisional, count >= 2 && count < 10);
          expect(value.lifetimeCountedMatches, count);
          expect(value.seasonCountedMatches, 0);
          expect(value.placementMatchesRemaining, (2 - count).clamp(0, 2));
          expect(value.skillRating, count >= 2 ? 1080 : null);
        }
        expect(rating.isRanked, isFalse);
        expect(rating.gamesNeededToRank, 2);
        expect(rating.lastChange, count >= 2 ? 0 : null);
        expect(rating.division, count >= 2 ? isNotNull : isNull);
      },
    );
  }

  test(
    'explicit hidden and null numbers never become default seed or zero',
    () {
      final hidden = PlayerRatingLeaderboardEntry.fromJson({
        ..._rating(1),
        'skill_rating': 1980,
        'last_change': 80,
      });
      expect(hidden.skillRating, isNull);
      expect(hidden.lastChange, isNull);
      final missing = PlayerRatingLeaderboardEntry.fromJson({
        'rating_visible': false,
        'lifetime_counted_matches': 0,
      });
      expect(missing.skillRating, isNull);
      expect(missing.lastChange, isNull);
      final nullLegacy = PlayerRatingLeaderboardEntry.fromJson({
        'skill_rating': null,
        'last_change': null,
        'matches_played': 20,
      });
      expect(nullLegacy.skillRating, isNull);
      expect(nullLegacy.lastChange, isNull);
      expect(nullLegacy.ratingVisible, isFalse);
    },
  );

  test('old responses keep their season-based placement semantics', () {
    final placed = PlayerRatingLeaderboardEntry.fromJson({
      'matches_played': 2,
      'skill_rating': 1300,
      'last_change': 12,
      'rank': 1,
    });
    expect(placed.ratingVisible, isTrue);
    expect(placed.isRanked, isTrue);
    expect(placed.provisional, isFalse);
    expect(placed.seasonQualificationGames, 2);
    expect(PlayerRatingLeaderboardEntry.fromJson({}).skillRating, 1200);
  });

  test(
    'three-game season qualification never delays two-game lifetime reveal',
    () {
      final json = {
        ..._rating(2),
        'rank': 1,
        'matches_played': 2,
        'season_counted_matches': 2,
        'minimum_rated_games': 3,
      };
      final rating = PlayerRatingLeaderboardEntry.fromJson(json);
      final profile = ProfilePlayerRating.fromJson(json);
      for (final value in [rating, profile]) {
        expect(value.ratingVisible, isTrue);
        expect(value.provisional, isTrue);
        expect(value.placementMatchesRemaining, 0);
        expect(value.seasonQualificationGames, 3);
      }
      expect(rating.isRanked, isFalse);
      expect(rating.gamesNeededToRank, 1);
      final qualified = PlayerRatingLeaderboardEntry.fromJson({
        ...json,
        'season_counted_matches': 3,
      });
      expect(qualified.isRanked, isTrue);
      expect(qualified.gamesNeededToRank, 0);
    },
  );

  test('roles and scope copies preserve independent reveal state', () {
    final ratings = FieldrushPlayerRatings.fromJson({
      'ratings': {'OUTFIELD': _rating(12), 'GOALKEEPER': _rating(1)},
    });
    expect(ratings.outfield.ratingVisible, isTrue);
    expect(ratings.goalkeeper.ratingVisible, isFalse);
    expect(ratings.goalkeeper.skillRating, isNull);
    expect(
      ratings.forScope(RatingTrack.outfield, null).lifetimeCountedMatches,
      12,
    );
    expect(ratings.forScope(RatingTrack.outfield, null).ratingVisible, isTrue);
  });

  test('placement progress is lifetime even when the season has no games', () {
    final placement = FieldrushPlacementPlayer.fromJson(_rating(1));
    expect(placement.matchesPlayed, 0);
    expect(placement.lifetimeCountedMatches, 1);
    expect(placement.isPlacement, isTrue);
    expect(FieldrushPlacementPlayer.fromJson(_rating(10)).isPlacement, isFalse);
  });

  test('history masks hidden, pending and nonrated numeric updates', () {
    for (final state in [
      {'rating_visible': false},
      {'rating_status': 'PENDING_REVIEW'},
      {'rating_status': 'NO_CONTEST'},
    ]) {
      final event = ProfileRatingEvent.fromJson({
        'rating_before': 1000,
        'rating_after': 1040,
        'rating_change': 40,
        'team_average_rating': 1100,
        'opponent_average_rating': 1200,
        'expected_score': 0.4,
        'base_rating_change': 15,
        'margin_multiplier': 1.5,
        'margin_bonus_applied': 25,
        'rating_explanation': 'Awaiting confirmed participation.',
        ...state,
      });
      expect(event.ratingBefore, isNull);
      expect(event.ratingAfter, isNull);
      expect(event.ratingChange, isNull);
      expect(event.teamAverageRating, isNull);
      expect(event.opponentAverageRating, isNull);
      expect(event.expectedScore, isNull);
      expect(event.baseRatingChange, isNull);
      expect(event.marginMultiplier, isNull);
      expect(event.marginBonusApplied, isNull);
      expect(event.hasPublicRating, isFalse);
      expect(event.ratingExplanation, 'Awaiting confirmed participation.');
    }
    final revealedDraw = ProfileRatingEvent.fromJson({
      'rating_before': 1000,
      'rating_after': 1000,
      'rating_change': 0,
      'rating_status': 'RATED',
    });
    expect(revealedDraw.hasPublicRating, isTrue);
    expect(revealedDraw.ratingChange, 0);
    expect(ProfileRatingEvent.fromJson({}).ratingChange, isNull);
  });

  test('hidden parent state masks nested history for both profile RPCs', () {
    final hidden = {
      ..._rating(1),
      'events': [
        {'rating_before': 1000, 'rating_after': 1040, 'rating_change': 40},
      ],
    };
    expect(
      ProfilePlayerRating.fromJson(hidden).events.single.ratingChange,
      isNull,
    );
    final ratings = FieldrushPlayerRatings.fromJson({
      'ratings': {'OUTFIELD': hidden, 'GOALKEEPER': _rating(0)},
    });
    expect(ratings.eventsFor(RatingTrack.outfield).single.ratingChange, isNull);
  });

  test('counted credit is independent from a settled conduct penalty', () {
    for (final sample in [
      (counted: false, delta: 0, shown: false),
      (counted: false, delta: -5, shown: true),
      (counted: true, delta: 0, shown: true),
    ]) {
      final json = {
        'rating_status': 'RATED',
        'rating_visible': true,
        'counted_as_played': sample.counted,
        'actual_played_seconds': 480,
        'rating_before': 1000,
        'rating_after': 1000 + sample.delta,
        'rating_change': sample.delta,
        'rating_at_match_start': 1000,
        'is_me': true,
      };
      final event = ProfileRatingEvent.fromJson(json);
      expect(event.countedAsPlayed, sample.counted);
      expect(event.actualPlayedSeconds, 480);
      expect(event.hasPublicRating, sample.shown);
      expect(event.ratingChange, sample.delta);
      final player = OpenQueuePlayer.fromJson(json);
      expect(player.countedAsPlayed, sample.counted);
      expect(player.actualPlayedSeconds, 480);
      expect(player.publicRatingChange, sample.shown ? sample.delta : null);
      expect(
        player.toFixtureLineupPlayer().ratingChange,
        sample.shown ? sample.delta : null,
      );
      if (!sample.counted) {
        expect(event.publicRatingExplanation, contains('does not count'));
        expect(player.publicRatingExplanation, contains('does not count'));
      }
    }
    expect(ProfileRatingEvent.fromJson({}).countedAsPlayed, isNull);
    expect(OpenQueuePlayer.fromJson({}).actualPlayedSeconds, isNull);
  });

  test(
    'solo player snapshots cannot reveal hidden SR or promise held delta',
    () {
      final hidden = OpenQueuePlayer.fromJson({
        'rating_visible': false,
        'rating_at_team_assignment': 1000,
        'rating_at_match_start': 1000,
        'rating_change': 40,
        'is_me': true,
      });
      expect(hidden.displayedRating, isNull);
      expect(hidden.ratingChange, isNull);
      expect(hidden.toFixtureLineupPlayer().displayedRating, isNull);
      final held = OpenQueueMatchDetail.fromJson({
        'game': {
          'starts_at': '2026-10-14T19:00:00Z',
          'ends_at': '2026-10-14T20:00:00Z',
          'status': 'FINAL',
        },
        'rating_status': 'PENDING_REVIEW',
        'rating_explanation': 'Awaiting organizer confirmation.',
        'players': [
          {'is_me': true, 'rating_at_match_start': 1000, 'rating_change': 40},
        ],
      });
      expect(held.viewerRatingUpdate, isNull);
      expect(held.viewerRatingExplanation, 'Awaiting organizer confirmation.');
    },
  );

  test('clan player cards accept lifetime reveal with no season games', () {
    final member = ClanMember.fromJson({
      ..._rating(10),
      'profiles': {'display_name': 'Alex'},
    });
    expect(member.ratingVisible, isTrue);
    expect(member.skillRating, 1080);
  });
}

Map<String, dynamic> _rating(int lifetime) => {
  'profile_id': 'player',
  'matches_played': 0,
  'season_counted_matches': 0,
  'lifetime_counted_matches': lifetime,
  'rating_visible': lifetime >= 2,
  'provisional': lifetime >= 2 && lifetime < 10,
  'placement_matches_remaining': (2 - lifetime).clamp(0, 2),
  'skill_rating': lifetime >= 2 ? 1080 : null,
  'last_change': lifetime >= 2 ? 0 : null,
};
