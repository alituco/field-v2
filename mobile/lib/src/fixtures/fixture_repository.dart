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
    cancellation_reason,
    created_by,
    created_at,
    updated_at,
    home_clan:clans!fixtures_home_clan_id_fkey(
      id,
      name,
      tag,
      emblem,
      theme_id,
      pattern_id,
      skill_rating
    ),
    away_clan:clans!fixtures_away_clan_id_fkey(
      id,
      name,
      tag,
      emblem,
      theme_id,
      pattern_id,
      skill_rating
    ),
    fixture_clock_states(
      status,
      started_at,
      accumulated_seconds,
      duration_seconds
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

    final response = await _client
        .from('fixtures')
        .select(_fixtureSelect)
        .neq('status', fixtureStatusToWire(FixtureStatus.cancelled))
        .order('match_date')
        .order('time_slot');
    final rows = response as List<dynamic>;

    return [
      for (final row in rows)
        Fixture.fromJson(Map<String, dynamic>.from(row as Map)),
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

    final response = await _client
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
            skill_rating
          )
        ''')
        .eq('profile_id', userId)
        .maybeSingle();

    if (response == null) return null;
    final row = Map<String, dynamic>.from(response);
    final clanData = row['clans'];
    if (clanData is! Map) return null;

    return MyClanMembership(
      clan: FixtureClan.fromJson(Map<String, dynamic>.from(clanData)),
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

    final response = await _client
        .from('fixtures')
        .select(_fixtureSelect)
        .eq('id', fixtureId)
        .single();

    return Fixture.fromJson(Map<String, dynamic>.from(response));
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
