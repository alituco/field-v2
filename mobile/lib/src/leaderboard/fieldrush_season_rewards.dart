import 'fieldrush_rating_tracks.dart';
import 'leaderboard.dart';

/// Published cash-prize information, not a payment or an awarded balance.
class FieldrushSeasonRewards {
  const FieldrushSeasonRewards({
    required this.minimumRatedGames,
    required this.prizesInCents,
    required this.players,
    this.currentPlayer,
    this.nextPlayer,
  });

  final int minimumRatedGames;
  final List<int> prizesInCents;
  final List<PlayerRatingLeaderboardEntry> players;
  final PlayerRatingLeaderboardEntry? currentPlayer, nextPlayer;

  String amountLabel(int place) {
    final cents = prizesInCents[place - 1];
    return '\$${(cents / 100).toStringAsFixed(cents % 100 == 0 ? 0 : 2)}';
  }

  factory FieldrushSeasonRewards.fromJson(Map<String, dynamic> json) {
    if (json['currency'] != 'USD') {
      throw const FormatException('Unsupported season reward currency.');
    }
    PlayerRatingLeaderboardEntry? player(Object? value) => value is Map
        ? PlayerRatingLeaderboardEntry.fromJson(
            Map<String, dynamic>.from(value),
          )
        : null;
    return FieldrushSeasonRewards(
      minimumRatedGames: (json['minimum_rated_games'] as num).toInt(),
      prizesInCents: [
        for (final key in [
          'first_prize_cents',
          'second_prize_cents',
          'third_prize_cents',
        ])
          (json[key] as num).toInt(),
      ],
      players: [
        for (final row in json['prize_players'] as List<dynamic>? ?? const [])
          if (player(row) case final entry?) entry,
      ],
      currentPlayer: player(json['current_player']),
      nextPlayer: player(json['next_player']),
    );
  }
}

abstract interface class SeasonRewardsRepository {
  Future<FieldrushSeasonRewards?> loadSeasonRewards({
    required LeaderboardSeason season,
    required RatingTrack track,
    required String cityId,
  });
}
