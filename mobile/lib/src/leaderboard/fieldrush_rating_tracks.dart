import 'leaderboard.dart';
import '../profile/profile.dart';
import '../ranking/player_rating_visibility.dart';

enum RatingTrack {
  outfield('OUTFIELD', 'Outfield'),
  goalkeeper('GOALKEEPER', 'Keeper');

  const RatingTrack(this.value, this.label);
  final String value;
  final String label;
}

/// Owner-only server projection. This never changes public rank eligibility or
/// fills a missing official SR with a client-calculated assessment seed.
class FieldrushPlacementPrediction {
  const FieldrushPlacementPrediction({
    required this.skillRating,
    required this.countedMatches,
    this.lastChange,
  });
  final int skillRating, countedMatches;
  final int? lastChange;

  static FieldrushPlacementPrediction? fromJson(Object? value) {
    if (value is! Map) return null;
    final sr = value['skill_rating'];
    final count = value['lifetime_counted_matches'];
    final delta = value['last_change'];
    if (sr is! int ||
        count is! int ||
        count < 0 ||
        count > 1 ||
        (delta != null && delta is! int)) {
      return null;
    }
    return FieldrushPlacementPrediction(
      skillRating: sr,
      countedMatches: count,
      lastChange: count == 1 ? delta as int? : null,
    );
  }
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
    this.placementPredictions = const {},
  });

  final PlayerRatingLeaderboardEntry outfield;
  final PlayerRatingLeaderboardEntry goalkeeper;
  final String? primaryCityId, primaryCityName, preferredCityId;
  final Map<RatingTrack, int> globalRanks;
  final Map<RatingTrack, List<ProfileRatingEvent>> events;
  final Map<RatingTrack, FieldrushPlacementPrediction> placementPredictions;

  FieldrushPlacementPrediction? predictionFor(RatingTrack track) =>
      forTrack(track).ratingVisible ? null : placementPredictions[track];

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
      visibility: rating.visibility,
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
      placementPredictions: {
        for (final track in RatingTrack.values)
          if (FieldrushPlacementPrediction.fromJson(
                (json['placement_predictions'] is Map
                    ? json['placement_predictions'] as Map
                    : const {})[track.value],
              )
              case final prediction?)
            track: prediction,
      },
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
              ProfileRatingEvent.fromJson({
                ...Map<String, dynamic>.from(row as Map),
                if (PlayerRatingVisibility.fromJson(
                      entry.value,
                    )?.ratingVisible ==
                    false)
                  'rating_visible': false,
              }),
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
