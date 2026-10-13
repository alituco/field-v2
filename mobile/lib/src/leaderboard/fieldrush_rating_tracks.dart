import 'leaderboard.dart';
import '../profile/profile.dart';

enum RatingTrack {
  outfield('OUTFIELD', 'Outfield'),
  goalkeeper('GOALKEEPER', 'Keeper');

  const RatingTrack(this.value, this.label);
  final String value;
  final String label;
}

/// Both ladders share one earned city. Preferred city is discovery-only.
class FieldrushPlayerRatings {
  const FieldrushPlayerRatings({
    required this.outfield,
    required this.goalkeeper,
    this.primaryCityId,
    this.primaryCityName,
    this.preferredCityId,
    this.globalRanks = const {},
    this.events = const {},
  });

  final PlayerRatingLeaderboardEntry outfield;
  final PlayerRatingLeaderboardEntry goalkeeper;
  final String? primaryCityId, primaryCityName, preferredCityId;
  final Map<RatingTrack, int> globalRanks;
  final Map<RatingTrack, List<ProfileRatingEvent>> events;

  List<ProfileRatingEvent> eventsFor(RatingTrack track) =>
      events[track] ?? const [];

  /// Full history comes from the profile history RPC; snapshots only refresh
  /// recent details and must not truncate a player's history to their 50 rows.
  List<ProfileRatingEvent> mergeHistory(List<ProfileRatingEvent> history) {
    final byMatch = {
      for (final event in history)
        '${event.sourceType}:${event.sourceId}': event,
      for (final track in RatingTrack.values)
        for (final event in eventsFor(track))
          '${event.sourceType}:${event.sourceId}': event,
    };
    return byMatch.values.toList()
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
  }

  PlayerRatingLeaderboardEntry forTrack(RatingTrack track) =>
      track == RatingTrack.goalkeeper ? goalkeeper : outfield;

  PlayerRatingLeaderboardEntry forScope(RatingTrack track, String? cityId) {
    final rating = forTrack(track);
    return PlayerRatingLeaderboardEntry(
      profileId: rating.profileId,
      displayName: rating.displayName,
      username: rating.username,
      avatarUrl: rating.avatarUrl,
      skillRating: rating.skillRating,
      matchesPlayed: rating.matchesPlayed,
      wins: rating.wins,
      losses: rating.losses,
      draws: rating.draws,
      lastChange: rating.lastChange,
      region: cityId == null ? 'global' : rating.region,
      rank: cityId == null
          ? globalRanks[track] ?? 0
          : cityId == primaryCityId
          ? rating.rank
          : 0,
    );
  }

  factory FieldrushPlayerRatings.fromJson(Map<String, dynamic> json) {
    final ratings = Map<String, dynamic>.from(json['ratings'] as Map);
    final out = Map<String, dynamic>.from(ratings['OUTFIELD'] as Map);
    final keeper = Map<String, dynamic>.from(ratings['GOALKEEPER'] as Map);
    return FieldrushPlayerRatings(
      outfield: PlayerRatingLeaderboardEntry.fromJson(out),
      goalkeeper: PlayerRatingLeaderboardEntry.fromJson(keeper),
      primaryCityId: json['primary_city_id'] as String?,
      primaryCityName: json['primary_city_name'] as String?,
      preferredCityId: json['preferred_city_id'] as String?,
      globalRanks: {
        RatingTrack.outfield: (out['global_rank'] as num?)?.toInt() ?? 0,
        RatingTrack.goalkeeper: (keeper['global_rank'] as num?)?.toInt() ?? 0,
      },
      events: {
        for (final entry in {
          RatingTrack.outfield: out,
          RatingTrack.goalkeeper: keeper,
        }.entries)
          entry.key: [
            for (final row in entry.value['events'] as List? ?? const [])
              ProfileRatingEvent.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
          ],
      },
    );
  }
}

/// Optional capability keeps legacy test repositories honest: a missing Keeper
/// response must never borrow a player's Outfield rating.
abstract interface class TrackLeaderboardRepository {
  Future<FieldrushPlayerRatings> loadPlayerRatings({
    required LeaderboardSeason season,
    String? profileId,
  });

  Future<PlayerRatingLeaderboardPage> loadRatingPage({
    required LeaderboardSeason season,
    required RatingTrack track,
    String? cityId,
    int offset = 0,
    int pageSize = 23,
  });
}
