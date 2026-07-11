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
}
