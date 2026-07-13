import 'package:supabase_flutter/supabase_flutter.dart';

import 'leaderboard.dart';

abstract class LeaderboardRepository {
  Future<LeaderboardPlayerStats> loadPlayerStats(LeaderboardSeason season);

  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating();

  Future<List<PlayerRatingLeaderboardEntry>> loadPlayerRatingLeaderboard({
    String region = 'bahrain',
  });
}

class SupabaseLeaderboardRepository implements LeaderboardRepository {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating() async {
    final response = await _client.rpc('get_my_player_rating');
    final rows = response as List<dynamic>;
    if (rows.isEmpty) throw StateError('Your Player Rating is unavailable.');
    return PlayerRatingLeaderboardEntry.fromJson(
      Map<String, dynamic>.from(rows.first as Map),
    );
  }

  @override
  Future<List<PlayerRatingLeaderboardEntry>> loadPlayerRatingLeaderboard({
    String region = 'bahrain',
  }) async {
    final response = await _client.rpc(
      'list_player_rating_leaderboard',
      params: {'region_to_use': region},
    );
    return [
      for (final row in response as List<dynamic>)
        PlayerRatingLeaderboardEntry.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
    ];
  }

  @override
  Future<LeaderboardPlayerStats> loadPlayerStats(
    LeaderboardSeason season,
  ) async {
    final fixturesResponse = await _client
        .from('fixtures')
        .select('id, home_clan_id, away_clan_id, home_score, away_score')
        .eq('status', 'FINAL')
        .gte('match_date', season.startsOn)
        .lte('match_date', season.endsOn);
    final fixtureRows = fixturesResponse as List<dynamic>;
    final finalFixtures = [
      for (final row in fixtureRows) Map<String, dynamic>.from(row as Map),
    ];
    final fixtureIds = [
      for (final fixture in finalFixtures) fixture['id'] as String,
    ];
    final clanRecords = _clanRecordsFromFixtures(finalFixtures);

    if (fixtureIds.isEmpty) {
      return const LeaderboardPlayerStats(
        finalMatchCount: 0,
        clanRecords: {},
        topScorers: [],
        topAssisters: [],
      );
    }

    final scorersResponse = await _client
        .from('fixture_scorers')
        .select('profile_id, assist_profile_id')
        .inFilter('fixture_id', fixtureIds);
    final scorerRows = scorersResponse as List<dynamic>;

    final goalsByProfile = <String, int>{};
    final assistsByProfile = <String, int>{};
    final profileIds = <String>{};

    for (final row in scorerRows) {
      final scorer = Map<String, dynamic>.from(row as Map);
      final profileId = scorer['profile_id'] as String?;
      final assistProfileId = scorer['assist_profile_id'] as String?;

      if (profileId != null) {
        profileIds.add(profileId);
        goalsByProfile[profileId] = (goalsByProfile[profileId] ?? 0) + 1;
      }

      if (assistProfileId != null) {
        profileIds.add(assistProfileId);
        assistsByProfile[assistProfileId] =
            (assistsByProfile[assistProfileId] ?? 0) + 1;
      }
    }

    if (profileIds.isEmpty) {
      return LeaderboardPlayerStats(
        finalMatchCount: fixtureIds.length,
        clanRecords: clanRecords,
        topScorers: const [],
        topAssisters: const [],
      );
    }

    final profilesResponse = await _client
        .from('profiles')
        .select('id, display_name, username, avatar_url')
        .inFilter('id', profileIds.toList());
    final profileRows = profilesResponse as List<dynamic>;
    final profilesById = <String, Map<String, dynamic>>{};
    for (final row in profileRows) {
      final profile = Map<String, dynamic>.from(row as Map);
      profilesById[profile['id'] as String] = profile;
    }

    return LeaderboardPlayerStats(
      finalMatchCount: fixtureIds.length,
      clanRecords: clanRecords,
      topScorers: _rankedPlayerStats(goalsByProfile, profilesById),
      topAssisters: _rankedPlayerStats(assistsByProfile, profilesById),
    );
  }

  Map<String, LeaderboardClanRecord> _clanRecordsFromFixtures(
    List<Map<String, dynamic>> fixtures,
  ) {
    final records = <String, LeaderboardClanRecord>{};

    void addResult(
      String clanId, {
      int wins = 0,
      int losses = 0,
      int draws = 0,
    }) {
      final current =
          records[clanId] ??
          const LeaderboardClanRecord(wins: 0, losses: 0, draws: 0);
      records[clanId] = LeaderboardClanRecord(
        wins: current.wins + wins,
        losses: current.losses + losses,
        draws: current.draws + draws,
      );
    }

    for (final fixture in fixtures) {
      final homeClanId = fixture['home_clan_id'] as String?;
      final awayClanId = fixture['away_clan_id'] as String?;
      final homeScore = _asNullableInt(fixture['home_score']);
      final awayScore = _asNullableInt(fixture['away_score']);

      if (homeClanId == null ||
          awayClanId == null ||
          homeScore == null ||
          awayScore == null) {
        continue;
      }

      if (homeScore > awayScore) {
        addResult(homeClanId, wins: 1);
        addResult(awayClanId, losses: 1);
      } else if (awayScore > homeScore) {
        addResult(awayClanId, wins: 1);
        addResult(homeClanId, losses: 1);
      } else {
        addResult(homeClanId, draws: 1);
        addResult(awayClanId, draws: 1);
      }
    }

    return records;
  }

  List<LeaderboardPlayerStat> _rankedPlayerStats(
    Map<String, int> counts,
    Map<String, Map<String, dynamic>> profilesById,
  ) {
    final stats = <LeaderboardPlayerStat>[];

    for (final entry in counts.entries) {
      final profile = profilesById[entry.key];
      if (profile == null) continue;

      final displayName = (profile['display_name'] as String? ?? '').trim();
      final username = (profile['username'] as String? ?? '').trim();
      stats.add(
        LeaderboardPlayerStat(
          profileId: entry.key,
          displayName: displayName.isEmpty ? 'Player' : displayName,
          username: username.isEmpty
              ? _fallbackUsername(displayName)
              : username,
          avatarUrl: profile['avatar_url'] as String?,
          value: entry.value,
        ),
      );
    }

    stats.sort((a, b) {
      final countCompare = b.value.compareTo(a.value);
      if (countCompare != 0) return countCompare;
      return a.displayName.compareTo(b.displayName);
    });

    return stats.take(5).toList();
  }

  String _fallbackUsername(String displayName) {
    final normalized = displayName
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return normalized.isEmpty ? 'player' : normalized;
  }

  int? _asNullableInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
