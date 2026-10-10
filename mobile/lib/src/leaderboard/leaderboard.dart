import '../ranking/rating_division.dart';

const minimumClanLeaderboardMatches = 4;
const minimumPlayerLeaderboardMatches = 2;

class PlayerRatingLeaderboardEntry {
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
  });

  final int rank;
  final String profileId;
  final String displayName;
  final String username;
  final String? avatarUrl;
  final int skillRating;
  final int matchesPlayed;
  final int wins;
  final int losses;
  final int draws;
  final int lastChange;
  final String region;

  bool get isRanked =>
      rank > 0 && matchesPlayed >= minimumPlayerLeaderboardMatches;

  int get gamesNeededToRank => (minimumPlayerLeaderboardMatches - matchesPlayed)
      .clamp(0, minimumPlayerLeaderboardMatches);

  RatingDivision get division => divisionFromRating(skillRating);

  String get divisionLabel => division.label;

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
      skillRating: _leaderboardInt(json['skill_rating'], fallback: 1200),
      matchesPlayed: _leaderboardInt(json['matches_played']),
      wins: _leaderboardInt(json['wins']),
      losses: _leaderboardInt(json['losses']),
      draws: _leaderboardInt(json['draws']),
      lastChange: _leaderboardInt(json['last_change']),
      region: json['region'] as String? ?? 'bahrain',
    );
  }
}

int _leaderboardInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

class LeaderboardSeason {
  const LeaderboardSeason({
    required this.id,
    required this.label,
    required this.rangeLabel,
    required this.startsOn,
    required this.endsOn,
  });

  final String id;
  final String label;
  final String rangeLabel;
  final String startsOn;
  final String endsOn;
}

const leaderboardSeasons = [
  LeaderboardSeason(
    id: 's0',
    label: 'S0',
    rangeLabel: 'Jun - Sep 2026',
    startsOn: '2026-06-01',
    endsOn: '2026-09-30',
  ),
  LeaderboardSeason(
    id: 's1',
    label: 'S1',
    rangeLabel: 'Oct - Dec 2026',
    startsOn: '2026-10-01',
    endsOn: '2026-12-31',
  ),
];

LeaderboardSeason get activeLeaderboardSeason =>
    leaderboardSeasonForDate(_bahrainToday());

LeaderboardSeason leaderboardSeasonForDate(DateTime date) {
  final day = DateTime.utc(date.year, date.month, date.day);
  for (final season in leaderboardSeasons) {
    final startsOn = DateTime.parse('${season.startsOn}T00:00:00Z');
    final endsOn = DateTime.parse('${season.endsOn}T00:00:00Z');
    if (!day.isBefore(startsOn) && !day.isAfter(endsOn)) return season;
  }

  final first = leaderboardSeasons.first;
  final firstStart = DateTime.parse('${first.startsOn}T00:00:00Z');
  if (day.isBefore(firstStart)) return first;
  return leaderboardSeasons.last;
}

bool isActiveLeaderboardSeason(LeaderboardSeason season, {DateTime? now}) {
  final bahrainDay = now ?? _bahrainToday();
  final day = DateTime.utc(bahrainDay.year, bahrainDay.month, bahrainDay.day);
  final startsOn = DateTime.parse('${season.startsOn}T00:00:00Z');
  final endsOn = DateTime.parse('${season.endsOn}T00:00:00Z');
  return !day.isBefore(startsOn) && !day.isAfter(endsOn);
}

DateTime _bahrainToday() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 3));
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
