import 'package:supabase_flutter/supabase_flutter.dart';

import 'fixture.dart';

abstract class FixtureRepository {
  Future<List<Fixture>> listFixtures();

  Future<Fixture> getFixture(String fixtureId);

  Future<MyClanMembership?> getMyClanMembership();

  Future<Fixture> createFixture({
    required String homeClanId,
    required String venue,
    required DateTime matchDate,
    required FixtureTimeSlot timeSlot,
  });

  Future<Fixture> joinFixture({
    required String fixtureId,
    required String awayClanId,
  });

  Future<List<FixtureSrScenario>> previewSrScenarios({
    required String homeClanId,
    required String awayClanId,
    required String myClanId,
  });

  Future<Fixture> completeFixture({
    required String fixtureId,
    required int homeScore,
    required int awayScore,
  });
}

class SupabaseFixtureRepository implements FixtureRepository {
  SupabaseClient get _client => Supabase.instance.client;

  static const _fixtureSelect = '''
    id,
    status,
    home_clan_id,
    away_clan_id,
    venue,
    day,
    time_slot,
    match_date,
    home_score,
    away_score,
    winner_clan_id,
    home_sr_change,
    away_sr_change,
    video_url,
    cancelled_at,
    cancellation_code,
    cancellation_reason,
    cancelled_by,
    cancellation_context,
    created_by,
    home_paid_by,
    away_paid_by,
    home_paid_at,
    away_paid_at,
    created_at,
    updated_at,
    home_clan:clans!fixtures_home_clan_id_fkey(
      id,
      name,
      tag,
      emblem,
      theme_id,
      pattern_id,
      skill_rating,
      region
    ),
    home_payer:profiles!fixtures_home_paid_by_fkey(
      id,
      display_name,
      username
    ),
    away_payer:profiles!fixtures_away_paid_by_fkey(
      id,
      display_name,
      username
    ),
    cancellation_actor:profiles!fixtures_cancelled_by_fkey(
      id,
      display_name,
      username
    ),
    away_clan:clans!fixtures_away_clan_id_fkey(
      id,
      name,
      tag,
      emblem,
      theme_id,
      pattern_id,
      skill_rating,
      region
    ),
    fixture_clock_states(
      status,
      started_at,
      accumulated_seconds,
      duration_seconds
    ),
    fixture_broadcasts(
      status,
      live_input_id,
      active_video_id,
      hls_url,
      replay_hls_url,
      stream_started_at,
      stream_stopped_at,
      recording_ready_at,
      error_message
    ),
    fixture_scorers(
      id,
      fixture_id,
      clan_id,
      profile_id,
      assist_profile_id,
      minute,
      created_at,
      scorer:profiles!fixture_scorers_profile_id_fkey(
        id,
        display_name,
        username
      ),
      assist:profiles!fixture_scorers_assist_profile_id_fkey(
        id,
        display_name,
        username
      )
    ),
    fixture_events(
      id,
      fixture_id,
      event_type,
      clan_id,
      profile_id,
      assist_profile_id,
      minute,
      second,
      note,
      created_at,
      player:profiles!fixture_events_profile_id_fkey(
        id,
        display_name,
        username
      ),
      assist:profiles!fixture_events_assist_profile_id_fkey(
        id,
        display_name,
        username
      )
    )
  ''';

  @override
  Future<List<Fixture>> listFixtures() async {
    await _cancelUnderfilledFixtures();

    final results = await Future.wait<dynamic>([
      _client
          .from('fixtures')
          .select(_fixtureSelect)
          .neq('status', fixtureStatusToWire(FixtureStatus.cancelled))
          .order('match_date')
          .order('time_slot'),
      _loadRegionRanks(),
    ]);
    final rows = results[0] as List<dynamic>;
    final regionRanks = results[1] as Map<String, int>;

    return [
      for (final row in rows)
        _fixtureFromRow(Map<String, dynamic>.from(row as Map), regionRanks),
    ];
  }

  @override
  Future<Fixture> getFixture(String fixtureId) {
    return _fetchFixture(fixtureId);
  }

  @override
  Future<MyClanMembership?> getMyClanMembership() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    final results = await Future.wait<dynamic>([
      _client
          .from('clan_members')
          .select('''
            role,
            clans(
              id,
              name,
              tag,
              emblem,
              theme_id,
              pattern_id,
              skill_rating,
              region
            )
          ''')
          .eq('profile_id', userId)
          .isFilter('left_at', null)
          .maybeSingle(),
      _loadRegionRanks(),
    ]);
    final response = results[0];

    if (response == null) return null;
    final row = Map<String, dynamic>.from(response);
    final clanData = row['clans'];
    if (clanData is! Map) return null;
    final clanJson = Map<String, dynamic>.from(clanData);
    final regionRanks = results[1] as Map<String, int>;
    clanJson['region_rank'] = regionRanks[clanJson['id']];

    return MyClanMembership(
      clan: FixtureClan.fromJson(clanJson),
      role: row['role'] as String? ?? 'member',
    );
  }

  @override
  Future<Fixture> createFixture({
    required String homeClanId,
    required String venue,
    required DateTime matchDate,
    required FixtureTimeSlot timeSlot,
  }) async {
    final response = await _client.rpc(
      'create_fixture',
      params: {
        'home_clan_id_to_use': homeClanId,
        'fixture_venue': venue.trim(),
        'fixture_date': _dateParam(matchDate),
        'fixture_time_slot': timeSlot.label,
      },
    );
    final row = Map<String, dynamic>.from(response as Map);
    return _fetchFixture(row['id'] as String);
  }

  @override
  Future<Fixture> joinFixture({
    required String fixtureId,
    required String awayClanId,
  }) async {
    final response = await _client.rpc(
      'join_fixture',
      params: {
        'fixture_id_to_join': fixtureId,
        'away_clan_id_to_use': awayClanId,
      },
    );
    final row = Map<String, dynamic>.from(response as Map);
    return _fetchFixture(row['id'] as String);
  }

  @override
  Future<List<FixtureSrScenario>> previewSrScenarios({
    required String homeClanId,
    required String awayClanId,
    required String myClanId,
  }) async {
    final response = await _client.rpc(
      'preview_fixture_sr_scenarios',
      params: {
        'home_clan_id_to_use': homeClanId,
        'away_clan_id_to_use': awayClanId,
        'perspective_clan_id_to_use': myClanId,
      },
    );
    final rows = response as List<dynamic>;

    return [
      for (final rawRow in rows)
        FixtureSrScenario(
          label: (rawRow as Map)['label'] as String,
          myChange: _intValue(rawRow['my_change']),
          opponentChange: _intValue(rawRow['opponent_change']),
        ),
    ];
  }

  @override
  Future<Fixture> completeFixture({
    required String fixtureId,
    required int homeScore,
    required int awayScore,
  }) async {
    final response = await _client.rpc(
      'complete_fixture',
      params: {
        'fixture_id_to_complete': fixtureId,
        'home_score_to_use': homeScore,
        'away_score_to_use': awayScore,
      },
    );
    final row = Map<String, dynamic>.from(response as Map);
    return _fetchFixture(row['id'] as String);
  }

  Future<Fixture> _fetchFixture(String fixtureId) async {
    await _cancelUnderfilledFixtures();

    final results = await Future.wait<dynamic>([
      _client
          .from('fixtures')
          .select(_fixtureSelect)
          .eq('id', fixtureId)
          .single(),
      _loadRegionRanks(),
    ]);
    final response = Map<String, dynamic>.from(results[0] as Map);
    final regionRanks = results[1] as Map<String, int>;

    return _fixtureFromRow(response, regionRanks);
  }

  Future<Map<String, int>> _loadRegionRanks() async {
    final response = await _client
        .from('clans')
        .select('id, name, skill_rating, region')
        .isFilter('archived_at', null);
    final rows =
        [
          for (final row in response as List<dynamic>)
            Map<String, dynamic>.from(row as Map),
        ]..sort((first, second) {
          final regionCompare = (first['region'] as String? ?? 'bahrain')
              .compareTo(second['region'] as String? ?? 'bahrain');
          if (regionCompare != 0) return regionCompare;
          final ratingCompare = _intValue(
            second['skill_rating'],
          ).compareTo(_intValue(first['skill_rating']));
          if (ratingCompare != 0) return ratingCompare;
          return (first['name'] as String? ?? '').compareTo(
            second['name'] as String? ?? '',
          );
        });

    final ranks = <String, int>{};
    final regionPositions = <String, int>{};
    for (final row in rows) {
      final id = row['id'] as String?;
      if (id == null) continue;
      final region = (row['region'] as String? ?? 'bahrain').toLowerCase();
      final rank = (regionPositions[region] ?? 0) + 1;
      regionPositions[region] = rank;
      ranks[id] = rank;
    }
    return ranks;
  }

  Future<void> _cancelUnderfilledFixtures() async {
    await _client.rpc('cancel_underfilled_fixtures');
  }

  String _dateParam(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}

Fixture _fixtureFromRow(
  Map<String, dynamic> row,
  Map<String, int> regionRanks,
) {
  void addRank(String key) {
    final value = row[key];
    if (value is! Map) return;
    final clan = Map<String, dynamic>.from(value);
    clan['region_rank'] = regionRanks[clan['id']];
    row[key] = clan;
  }

  addRank('home_clan');
  addRank('away_clan');
  return Fixture.fromJson(row);
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
