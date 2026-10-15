import '../ranking/rating_division.dart';
import '../ranking/player_rating_visibility.dart';

const minimumClanLeaderboardMatches = 4;
const minimumPlayerLeaderboardMatches = 2;

/// A bounded server page plus the current player's actual neighboring ranks.
class PlayerRatingLeaderboardPage {
  const PlayerRatingLeaderboardPage({
    required this.players,
    required this.aroundMe,
    required this.totalCount,
    required this.nextOffset,
  });

  final List<PlayerRatingLeaderboardEntry> players;
  final List<PlayerRatingLeaderboardEntry> aroundMe;
  final int totalCount;
  final int? nextOffset;

  factory PlayerRatingLeaderboardPage.fromJson(Map<String, dynamic> json) {
    List<PlayerRatingLeaderboardEntry> entries(Object? value) => [
      for (final row in value as List<dynamic>? ?? const [])
        PlayerRatingLeaderboardEntry.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
    ];
    return PlayerRatingLeaderboardPage(
      players: entries(json['players']),
      aroundMe: entries(json['around_me']),
      totalCount: _leaderboardInt(json['total_count']),
      nextOffset: json['next_offset'] == null
          ? null
          : _leaderboardInt(json['next_offset']),
    );
  }
}

class PlayerRatingLeaderboardEntry with PublicPlayerRating {
  const PlayerRatingLeaderboardEntry({
    required this.rank,
    required this.profileId,
    required this.displayName,
    required this.username,
    required this.skillRating,
    required this.matchesPlayed,
    required this.wins,
    required this.losses,
    required this.draws,
    required this.lastChange,
    required this.region,
    this.avatarUrl,
    this.visibility,
  });

  final int rank;
  final String profileId;
  final String displayName;
  final String username;
  final String? avatarUrl;
  @override
  final int? skillRating;
  @override
  final int matchesPlayed;
  final int wins;
  final int losses;
  final int draws;
  final int? lastChange;
  @override
  final PlayerRatingVisibility? visibility;
  final String region;

  bool get isRanked =>
      ratingVisible &&
      rank > 0 &&
      seasonCountedMatches >= seasonQualificationGames;

  int get gamesNeededToRank => (seasonQualificationGames - seasonCountedMatches)
      .clamp(0, seasonQualificationGames);

  RatingDivision? get division =>
      ratingVisible ? divisionFromRating(skillRating!) : null;

  String get divisionLabel => division?.label ?? 'Placement';

  String get recordLabel => '${wins}W · ${draws}D · ${losses}L';

  String get initials {
    final words = displayName.trim().split(RegExp(r'\s+'));
    return words
        .where((word) => word.isNotEmpty)
        .take(2)
        .map((word) => word[0])
        .join()
        .toUpperCase();
  }

  factory PlayerRatingLeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return PlayerRatingLeaderboardEntry(
      rank: _leaderboardInt(json['rank']),
      profileId: json['profile_id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? 'Player',
      username: json['username'] as String? ?? 'player',
      avatarUrl: json['avatar_url'] as String?,
      skillRating: publicRatingNumber(
        json,
        'skill_rating',
        legacyFallback: 1200,
      ),
      matchesPlayed: _leaderboardInt(json['matches_played']),
      wins: _leaderboardInt(json['wins']),
      losses: _leaderboardInt(json['losses']),
      draws: _leaderboardInt(json['draws']),
      lastChange: publicRatingNumber(json, 'last_change', legacyFallback: 0),
      visibility: PlayerRatingVisibility.fromJson(json),
      region: json['region'] as String? ?? 'phoenix',
    );
  }
}

int _leaderboardInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

enum LeaderboardSeasonLifecycle { draft, scheduled, active, ended }

class LeaderboardSeason {
  const LeaderboardSeason({
    required this.id,
    required this.label,
    required this.rangeLabel,
    required this.startsOn,
    required this.endsOn,
    this.minimumRatedGames = minimumPlayerLeaderboardMatches,
    this.visibleToPlayers = true,
    this.lifecycle,
  });

  final String id;
  final String label;
  final String rangeLabel;
  final String startsOn;
  final String endsOn;

  /// Leaderboard and prize qualification are season-specific; lifetime
  /// placement remains two games.
  final int minimumRatedGames;

  /// Visibility only controls the public season picker, not match history.
  /// Older catalogs omit these fields and retain their date-based behavior.
  final bool visibleToPlayers;
  final LeaderboardSeasonLifecycle? lifecycle;

  String get fullLabel =>
      RegExp(r'^S\d+$', caseSensitive: false).hasMatch(label)
      ? 'Season ${label.substring(1)}'
      : label;

  factory LeaderboardSeason.fromJson(Map<String, dynamic> json) {
    final startsOn = json['starts_on'] as String;
    final endsOn = json['ends_on'] as String;
    final start = DateTime.parse(startsOn);
    final end = DateTime.parse(endsOn);
    if (end.isBefore(start)) {
      throw const FormatException('Season end must follow its start.');
    }
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final rangeLabel = start.year == end.year
        ? '${months[start.month - 1]} - ${months[end.month - 1]} ${start.year}'
        : '${months[start.month - 1]} ${start.year} - ${months[end.month - 1]} ${end.year}';
    final minimumRatedGames = _leaderboardInt(
      json['minimum_rated_games'],
      fallback: minimumPlayerLeaderboardMatches,
    );
    if (minimumRatedGames < minimumPlayerLeaderboardMatches) {
      throw const FormatException(
        'Prize qualification must be at least two games.',
      );
    }
    final visibility = json['visible_to_players'];
    if (visibility != null && visibility is! bool) {
      throw const FormatException('Invalid season visibility.');
    }
    final lifecycleValue = json['lifecycle'];
    final lifecycle = switch (lifecycleValue) {
      null => null,
      'DRAFT' => LeaderboardSeasonLifecycle.draft,
      'SCHEDULED' => LeaderboardSeasonLifecycle.scheduled,
      'ACTIVE' => LeaderboardSeasonLifecycle.active,
      'ENDED' => LeaderboardSeasonLifecycle.ended,
      _ => throw const FormatException('Invalid season lifecycle.'),
    };
    return LeaderboardSeason(
      id: json['id'] as String,
      label: json['label'] as String,
      rangeLabel: rangeLabel,
      startsOn: startsOn,
      endsOn: endsOn,
      minimumRatedGames: minimumRatedGames,
      visibleToPlayers: visibility as bool? ?? true,
      lifecycle: lifecycle,
    );
  }
}

const _initialLeaderboardSeason = LeaderboardSeason(
  id: 's0',
  label: 'S0',
  rangeLabel: 'Jun - Sep 2026',
  startsOn: '2026-06-01',
  endsOn: '2026-09-30',
);

/// Offline/legacy fallback only. Live repositories use the server catalog so
/// admin edits to future seasons apply consistently throughout the app.
List<LeaderboardSeason> get leaderboardSeasons =>
    leaderboardSeasonsThrough(_phoenixToday());

List<LeaderboardSeason> leaderboardSeasonsThrough(DateTime date) {
  final last = _quarterSeasonNumber(date).clamp(1, 400);
  return [
    _initialLeaderboardSeason,
    for (var number = 1; number <= last; number++) _quarterSeason(number),
  ];
}

int _quarterSeasonNumber(DateTime date) =>
    (date.year - 2026) * 4 + (date.month - 1) ~/ 3 - 2;

LeaderboardSeason _quarterSeason(int number) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final start = DateTime.utc(2026, 10 + (number - 1) * 3);
  final end = DateTime.utc(start.year, start.month + 3, 0);
  String day(DateTime value) => value.toIso8601String().substring(0, 10);
  return LeaderboardSeason(
    id: 's$number',
    label: 'S$number',
    rangeLabel:
        '${months[start.month - 1]} - ${months[end.month - 1]} ${start.year}',
    startsOn: day(start),
    endsOn: day(end),
  );
}

LeaderboardSeason get activeLeaderboardSeason =>
    leaderboardSeasonForDate(_phoenixToday());

LeaderboardSeason leaderboardSeasonForDate(DateTime date) {
  final number = _quarterSeasonNumber(date);
  return number < 1 ? _initialLeaderboardSeason : _quarterSeason(number);
}

bool isActiveLeaderboardSeason(LeaderboardSeason season, {DateTime? now}) {
  final marketDay = now ?? _phoenixToday();
  final day = DateTime.utc(marketDay.year, marketDay.month, marketDay.day);
  final startsOn = DateTime.parse('${season.startsOn}T00:00:00Z');
  final endsOn = DateTime.parse('${season.endsOn}T00:00:00Z');
  return !day.isBefore(startsOn) && !day.isAfter(endsOn);
}

DateTime _phoenixToday() {
  // Phoenix does not observe daylight saving time.
  final now = DateTime.now().toUtc().subtract(const Duration(hours: 7));
  return DateTime.utc(now.year, now.month, now.day);
}

class LeaderboardClanRecord {
  const LeaderboardClanRecord({
    required this.wins,
    required this.losses,
    required this.draws,
  });

  final int wins;
  final int losses;
  final int draws;

  int get matchesPlayed => wins + losses + draws;

  String get label {
    final drawLabel = draws > 0 ? ' - ${draws}D' : '';
    return '${wins}W$drawLabel - ${losses}L';
  }
}

class LeaderboardPlayerStat {
  const LeaderboardPlayerStat({
    required this.profileId,
    required this.displayName,
    required this.username,
    required this.value,
    this.avatarUrl,
  });

  final String profileId;
  final String displayName;
  final String username;
  final int value;
  final String? avatarUrl;

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words.take(2).map((word) => word[0]).join().toUpperCase();
  }
}

class LeaderboardPlayerStats {
  const LeaderboardPlayerStats({
    required this.finalMatchCount,
    required this.clanRecords,
    required this.topScorers,
    required this.topAssisters,
  });

  final int finalMatchCount;
  final Map<String, LeaderboardClanRecord> clanRecords;
  final List<LeaderboardPlayerStat> topScorers;
  final List<LeaderboardPlayerStat> topAssisters;

  bool isClanEligible(String clanId) {
    return (clanRecords[clanId]?.matchesPlayed ?? 0) >=
        minimumClanLeaderboardMatches;
  }
}
