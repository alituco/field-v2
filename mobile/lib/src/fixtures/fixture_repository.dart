import 'package:supabase_flutter/supabase_flutter.dart';

import 'fixture.dart';
import 'fixture_reliability_roster.dart';

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

abstract interface class FixtureReliabilityBookingRepository {
  Future<ClanFixtureChargePreview> previewCreateFixtureCharge({
    required String clanId,
    required DateTime matchDate,
    required FixtureTimeSlot timeSlot,
  });

  Future<ClanFixtureChargePreview> previewJoinFixtureCharge({
    required String fixtureId,
    required String clanId,
  });

  Future<ClanFixtureCancellationPreview> previewFixtureCancellation(
    String fixtureId,
  );

  Future<ClanFixtureCancellationPreview> cancelFixtureBooking({
    required String fixtureId,
    required String reason,
  });
}

abstract interface class FixtureReliabilityRosterRepository {
  Future<FixtureReliabilityRoster> getMyFixtureReliabilityRoster(
    String fixtureId,
  );

  Future<FixtureReliabilityRoster> saveMyFixtureReliabilityRoster({
    required String fixtureId,
    required String clanId,
    required List<String> profileIds,
  });
}

class SupabaseFixtureRepository
    implements
        FixtureRepository,
        FixtureReliabilityBookingRepository,
        FixtureReliabilityRosterRepository {
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
      occurred_at,
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
    ),
    fixture_player_appearances(
      fixture_id,
      profile_id,
      clan_id,
      side,
      played,
      rating_at_start,
      rating_change,
      player:profiles!fixture_player_appearances_profile_id_fkey(
        id,
        display_name,
        username,
        avatar_url
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
          .order('match_date')
          .order('time_slot'),
      _loadRegionRanks(),
    ]);
    final rows = results[0] as List<dynamic>;
    final regionRanks = results[1] as Map<String, int>;

    return [
      for (final row in rows)
        _fixtureFromRow(
          Map<String, dynamic>.from(row as Map),
          regionRanks,
          currentUserId: _client.auth.currentUser?.id,
        ),
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
  Future<ClanFixtureChargePreview> previewCreateFixtureCharge({
    required String clanId,
    required DateTime matchDate,
    required FixtureTimeSlot timeSlot,
  }) async {
    final response = await _client.rpc(
      'preview_create_clan_fixture_charge',
      params: {
        'clan_id_to_use': clanId,
        'match_date_to_use': _dateParam(matchDate),
        'time_slot_to_use': timeSlot.label,
      },
    );
    return ClanFixtureChargePreview.fromJson(_rpcMap(response));
  }

  @override
  Future<ClanFixtureChargePreview> previewJoinFixtureCharge({
    required String fixtureId,
    required String clanId,
  }) async {
    final response = await _client.rpc(
      'preview_join_clan_fixture_charge',
      params: {'fixture_id_to_use': fixtureId, 'clan_id_to_use': clanId},
    );
    return ClanFixtureChargePreview.fromJson(_rpcMap(response));
  }

  @override
  Future<ClanFixtureCancellationPreview> previewFixtureCancellation(
    String fixtureId,
  ) async {
    final response = await _client.rpc(
      'preview_clan_fixture_cancellation',
      params: {'fixture_id_to_use': fixtureId},
    );
    return ClanFixtureCancellationPreview.fromJson(_rpcMap(response));
  }

  @override
  Future<ClanFixtureCancellationPreview> cancelFixtureBooking({
    required String fixtureId,
    required String reason,
  }) async {
    final response = await _client.rpc(
      'cancel_clan_fixture_booking',
      params: {
        'fixture_id_to_cancel': fixtureId,
        'reason_to_use': reason.trim(),
      },
    );
    return ClanFixtureCancellationPreview.fromJson(_rpcMap(response));
  }

  @override
  Future<FixtureReliabilityRoster> getMyFixtureReliabilityRoster(
    String fixtureId,
  ) async {
    final response = await _client.rpc(
      'get_my_fixture_reliability_roster',
      params: {'fixture_id_to_view': fixtureId},
    );
    return FixtureReliabilityRoster.fromJson(_rpcMap(response));
  }

  @override
  Future<FixtureReliabilityRoster> saveMyFixtureReliabilityRoster({
    required String fixtureId,
    required String clanId,
    required List<String> profileIds,
  }) async {
    await _client.rpc(
      'set_fixture_reliability_roster',
      params: {
        'fixture_id_to_manage': fixtureId,
        'clan_id_to_manage': clanId,
        'profile_ids_to_confirm': profileIds,
        'note_to_use': 'Confirmed from match booking details',
      },
    );
    return getMyFixtureReliabilityRoster(fixtureId);
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

    return _fixtureFromRow(
      response,
      regionRanks,
      currentUserId: _client.auth.currentUser?.id,
    );
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
  Map<String, int> regionRanks, {
  String? currentUserId,
}) {
  void addRank(String key) {
    final value = row[key];
    if (value is! Map) return;
    final clan = Map<String, dynamic>.from(value);
    clan['region_rank'] = regionRanks[clan['id']];
    row[key] = clan;
  }

  addRank('home_clan');
  addRank('away_clan');
  final rawAppearances = row['fixture_player_appearances'];
  if (rawAppearances is List) {
    row['fixture_player_appearances'] = [
      for (final rawAppearance in rawAppearances)
        if (rawAppearance is Map)
          {
            ...Map<String, dynamic>.from(rawAppearance),
            'is_me':
                currentUserId != null &&
                rawAppearance['profile_id'] == currentUserId,
          },
    ];
  }
  return Fixture.fromJson(row);
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

Map<String, dynamic> _rpcMap(Object? response) {
  return switch (response) {
    final Map value => Map<String, dynamic>.from(value),
    final List value when value.isNotEmpty => Map<String, dynamic>.from(
      value.first as Map,
    ),
    _ => throw StateError('The server did not return a reliability quote.'),
  };
}
