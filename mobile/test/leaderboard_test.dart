import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clans need at least four completed season matches to qualify', () {
    const stats = LeaderboardPlayerStats(
      finalMatchCount: 7,
      clanRecords: {
        'three-games': LeaderboardClanRecord(wins: 2, losses: 1, draws: 0),
        'four-games': LeaderboardClanRecord(wins: 2, losses: 1, draws: 1),
      },
      topScorers: [],
      topAssisters: [],
    );

    expect(stats.isClanEligible('three-games'), isFalse);
    expect(stats.isClanEligible('four-games'), isTrue);
    expect(stats.isClanEligible('no-games'), isFalse);
  });

  test('players need two completed season games to be ranked', () {
    final oneGame = _player(rank: 0, matchesPlayed: 1);
    final twoGames = _player(rank: 8, matchesPlayed: 2);

    expect(oneGame.isRanked, isFalse);
    expect(oneGame.gamesNeededToRank, 1);
    expect(twoGames.isRanked, isTrue);
    expect(twoGames.gamesNeededToRank, 0);
  });

  test('player season selection rolls over on the market calendar dates', () {
    expect(leaderboardSeasonForDate(DateTime.utc(2026, 6, 1)).id, 's0');
    expect(leaderboardSeasonForDate(DateTime.utc(2026, 9, 30)).id, 's0');
    expect(leaderboardSeasonForDate(DateTime.utc(2026, 10, 1)).id, 's1');
    expect(leaderboardSeasonForDate(DateTime.utc(2026, 12, 31)).id, 's1');

    final s0 = leaderboardSeasons.first;
    final s1 = leaderboardSeasons.last;
    expect(
      isActiveLeaderboardSeason(s0, now: DateTime.utc(2026, 9, 30)),
      isTrue,
    );
    expect(
      isActiveLeaderboardSeason(s0, now: DateTime.utc(2026, 10, 1)),
      isFalse,
    );
    expect(
      isActiveLeaderboardSeason(s1, now: DateTime.utc(2026, 10, 1)),
      isTrue,
    );
  });
}

PlayerRatingLeaderboardEntry _player({
  required int rank,
  required int matchesPlayed,
}) {
  return PlayerRatingLeaderboardEntry(
    rank: rank,
    profileId: 'player',
    displayName: 'Player One',
    username: 'player_one',
    skillRating: 1300,
    matchesPlayed: matchesPlayed,
    wins: matchesPlayed,
    losses: 0,
    draws: 0,
    lastChange: 4,
    region: 'bahrain',
  );
}
