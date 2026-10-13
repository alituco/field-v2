import 'fieldrush_rating_tracks.dart';
import 'leaderboard.dart';

/// Public placement progress deliberately contains no unrevealed skill rating.
class FieldrushPlacementPlayer {
  const FieldrushPlacementPlayer({
    required this.profileId,
    required this.displayName,
    required this.username,
    required this.matchesPlayed,
    this.avatarUrl,
  });
  final String profileId, displayName, username;
  final int matchesPlayed;
  final String? avatarUrl;

  factory FieldrushPlacementPlayer.fromJson(Map<String, dynamic> json) =>
      FieldrushPlacementPlayer(
        profileId: json['profile_id'] as String,
        displayName: json['display_name'] as String? ?? 'Player',
        username: json['username'] as String? ?? '',
        matchesPlayed: (json['matches_played'] as num?)?.toInt() ?? 0,
        avatarUrl: json['avatar_url'] as String?,
      );
}

class FieldrushPlacementPage {
  const FieldrushPlacementPage({
    required this.players,
    required this.totalCount,
    required this.nextOffset,
  });
  final List<FieldrushPlacementPlayer> players;
  final int totalCount;
  final int? nextOffset;

  factory FieldrushPlacementPage.fromJson(Map<String, dynamic> json) =>
      FieldrushPlacementPage(
        players: [
          for (final row in json['players'] as List? ?? const [])
            FieldrushPlacementPlayer.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
        ],
        totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
        nextOffset: (json['next_offset'] as num?)?.toInt(),
      );
}

abstract interface class PlacementLeaderboardRepository {
  Future<FieldrushPlacementPage> loadPlacementPage({
    required LeaderboardSeason season,
    required RatingTrack track,
    String? cityId,
    int offset = 0,
    int pageSize = 4,
  });
}
