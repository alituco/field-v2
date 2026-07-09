class LeaderboardSeason {
  const LeaderboardSeason({
    required this.id,
    required this.label,
    required this.rangeLabel,
    required this.startsOn,
    required this.endsOn,
    this.active = false,
  });

  final String id;
  final String label;
  final String rangeLabel;
  final String startsOn;
  final String endsOn;
  final bool active;
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
}
