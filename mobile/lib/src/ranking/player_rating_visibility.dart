/// Public rating state is independent of season leaderboard qualification.
/// Missing metadata supports older servers; explicit hidden/null values never
/// manufacture a seed or a zero-point update.
class PlayerRatingVisibility {
  const PlayerRatingVisibility({
    required this.lifetimeCountedMatches,
    required this.seasonCountedMatches,
    required this.ratingVisible,
    required this.provisional,
    required this.placementMatchesRemaining,
    this.minimumRatedGames = 2,
  });

  final int lifetimeCountedMatches;
  final int seasonCountedMatches;
  final bool ratingVisible;
  final bool provisional;
  final int placementMatchesRemaining;
  final int minimumRatedGames;

  static PlayerRatingVisibility? fromJson(Map<String, dynamic> json) {
    if (!json.containsKey('rating_visible') &&
        !json.containsKey('lifetime_counted_matches')) {
      return null;
    }
    final lifetime = _integer(json['lifetime_counted_matches']) ?? 0;
    final seasonMinimum = _integer(json['minimum_rated_games']) ?? 2;
    final visible = json['rating_visible'] is bool
        ? json['rating_visible'] == true
        : lifetime >= 2;
    return PlayerRatingVisibility(
      lifetimeCountedMatches: lifetime,
      seasonCountedMatches:
          _integer(json['season_counted_matches']) ??
          _integer(json['matches_played']) ??
          0,
      ratingVisible: visible,
      provisional:
          visible &&
          (json['provisional'] is bool
              ? json['provisional'] == true
              : lifetime < 10),
      placementMatchesRemaining: visible
          ? 0
          : (_integer(json['placement_matches_remaining']) ?? (2 - lifetime))
                .clamp(0, 2),
      minimumRatedGames: seasonMinimum >= 2 ? seasonMinimum : 2,
    );
  }
}

mixin PublicPlayerRating {
  int? get skillRating;
  int get matchesPlayed;
  PlayerRatingVisibility? get visibility;

  bool get ratingVisible =>
      skillRating != null && (visibility?.ratingVisible ?? matchesPlayed >= 2);
  bool get provisional => ratingVisible && (visibility?.provisional ?? false);
  int get lifetimeCountedMatches =>
      visibility?.lifetimeCountedMatches ?? matchesPlayed;
  int get seasonCountedMatches =>
      visibility?.seasonCountedMatches ?? matchesPlayed;
  int get seasonQualificationGames => visibility?.minimumRatedGames ?? 2;
  int get placementMatchesRemaining =>
      visibility?.placementMatchesRemaining ?? (2 - matchesPlayed).clamp(0, 2);
}

int? publicRatingNumber(
  Map<String, dynamic> json,
  String key, {
  int? legacyFallback,
}) {
  if (PlayerRatingVisibility.fromJson(json)?.ratingVisible == false) {
    return null;
  }
  if (json.containsKey(key)) return _integer(json[key]);
  return PlayerRatingVisibility.fromJson(json) == null ? legacyFallback : null;
}

int? _integer(Object? value) => switch (value) {
  int value => value,
  num value => value.toInt(),
  String value => int.tryParse(value),
  _ => null,
};

/// A held/non-rated result may explain itself, but never promise numeric SR.
bool permitsPublicRatingResult(String? status) =>
    status == null ||
    const {
      'RATED',
      'SETTLED',
      'FINAL',
      'RATED_FORFEIT',
    }.contains(status.toUpperCase());

String? publicRatingStatusLabel(String? status) =>
    switch (status?.toUpperCase()) {
      'PENDING' || 'PENDING_REVIEW' || 'HELD' => 'Rating pending review',
      'UNSETTLED' => 'Rating pending',
      'NOT_RATED' || 'UNRATED' || 'NO_CONTEST' || 'CANCELLED' => 'Not rated',
      'INELIGIBLE' || 'NOT_ELIGIBLE' => 'No counted rating appearance',
      _ => null,
    };

/// Counted-match credit is separate from a valid conduct-related SR movement.
/// The server explains eligibility; missing timing never becomes an estimate.
String? publicRatingAppearanceExplanation(
  String? explanation,
  bool? countedAsPlayed,
) => explanation?.trim().isNotEmpty == true
    ? explanation
    : countedAsPlayed == false
    ? 'This appearance does not count toward rating progress.'
    : null;
