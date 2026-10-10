import 'package:supabase_flutter/supabase_flutter.dart';

import '../fixtures/fixture.dart';
import 'clan.dart';
import 'clan_reliability.dart';

abstract class ClanRepository {
  Future<List<Clan>> listClans();

  Future<ClanMembership?> getMyClanMembership();

  Future<List<ClanMember>> listClanMembers(String clanId);

  Future<List<ClanJoinRequest>> listPendingJoinRequests(String clanId);

  Future<ClanJoinRequest?> getMyPendingJoinRequest(String clanId);

  Future<List<Fixture>> listClanFixtures(String clanId);

  Future<Clan> createClan({
    required String name,
    required String tag,
    required String motto,
    required String emblem,
    required String themeId,
    required String patternId,
  });

  Future<Clan> updateClanIdentity({
    required String clanId,
    required String motto,
    required String emblem,
    required String themeId,
    required String patternId,
  });

  Future<void> setClanMemberLeader({
    required String clanId,
    required String profileId,
    required bool makeLeader,
  });

  Future<void> transferClanOwnership({
    required String clanId,
    required String newOwnerProfileId,
  });

  Future<void> kickClanMember({
    required String clanId,
    required String profileId,
  });

  Future<String?> leaveClan(String clanId);

  Future<void> requestToJoinClan(String clanId);

  Future<void> cancelJoinRequest(String requestId);

  Future<void> reviewJoinRequest({
    required String requestId,
    required bool approve,
  });

  Future<void> archiveClan(String clanId);
}

abstract interface class ClanReliabilityRepository {
  Future<ClanReliabilitySummary> getClanReliabilitySummary(String clanId);
}

class SupabaseClanRepository
    implements ClanRepository, ClanReliabilityRepository {
  SupabaseClient get _client => Supabase.instance.client;

  static const _fixtureSelect = '''
    id,
    status,
    operational_state,
    operational_state_updated_at,
    operational_reason_code,
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
      skill_rating
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
      skill_rating
    )
  ''';

  @override
  Future<List<Clan>> listClans() async {
    final response = await _client.rpc('list_clans');
    final rows = response as List<dynamic>;

    return [
      for (final row in rows) Clan.fromJson(Map<String, dynamic>.from(row)),
    ];
  }

  @override
  Future<ClanReliabilitySummary> getClanReliabilitySummary(
    String clanId,
  ) async {
    final response = await _client.rpc(
      'get_clan_reliability_summary',
      params: {'clan_id_to_use': clanId},
    );
    final row = switch (response) {
      final Map value => Map<String, dynamic>.from(value),
      final List value when value.isNotEmpty && value.first is Map =>
        Map<String, dynamic>.from(value.first as Map),
      _ => throw StateError('Clan reliability details are unavailable.'),
    };
    return ClanReliabilitySummary.fromJson(row);
  }

  @override
  Future<ClanMembership?> getMyClanMembership() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    final response = await _client
        .from('clan_members')
        .select('clan_id, role')
        .eq('profile_id', userId)
        .isFilter('left_at', null)
        .maybeSingle();

    if (response == null) return null;
    return ClanMembership.fromJson(Map<String, dynamic>.from(response));
  }

  @override
  Future<List<ClanMember>> listClanMembers(String clanId) async {
    final response = await _client
        .from('clan_members')
        .select('''
          profile_id,
          role,
          created_at,
          profiles!clan_members_profile_id_fkey(display_name)
        ''')
        .eq('clan_id', clanId)
        .isFilter('left_at', null)
        .order('created_at');
    final rows = response as List<dynamic>;

    return [
      for (final row in rows)
        ClanMember.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<List<ClanJoinRequest>> listPendingJoinRequests(String clanId) async {
    final response = await _client
        .from('clan_join_requests')
        .select('''
          id,
          clan_id,
          profile_id,
          status,
          requested_at,
          cancellation_code,
          cancellation_reason,
          cancelled_at,
          cancelled_by,
          profiles!clan_join_requests_profile_id_fkey(
            display_name,
            username,
            avatar_url
          )
        ''')
        .eq('clan_id', clanId)
        .eq('status', 'PENDING')
        .order('requested_at');
    final rows = response as List<dynamic>;

    return [
      for (final row in rows)
        ClanJoinRequest.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<ClanJoinRequest?> getMyPendingJoinRequest(String clanId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    final response = await _client
        .from('clan_join_requests')
        .select('''
          id,
          clan_id,
          profile_id,
          status,
          requested_at,
          cancellation_code,
          cancellation_reason,
          cancelled_at,
          cancelled_by,
          profiles!clan_join_requests_profile_id_fkey(
            display_name,
            username,
            avatar_url
          )
        ''')
        .eq('clan_id', clanId)
        .eq('profile_id', userId)
        .eq('status', 'PENDING')
        .maybeSingle();

    if (response == null) return null;
    return ClanJoinRequest.fromJson(Map<String, dynamic>.from(response));
  }

  @override
  Future<List<Fixture>> listClanFixtures(String clanId) async {
    await _client.rpc('cancel_underfilled_fixtures');

    final response = await _client
        .from('fixtures')
        .select(_fixtureSelect)
        .or('home_clan_id.eq.$clanId,away_clan_id.eq.$clanId')
        .order('match_date', ascending: false)
        .order('time_slot', ascending: false);
    final rows = response as List<dynamic>;

    return [
      for (final row in rows)
        Fixture.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<Clan> createClan({
    required String name,
    required String tag,
    required String motto,
    required String emblem,
    required String themeId,
    required String patternId,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AuthException('You need to sign in again.');
    }

    await _ensureProfile(user);

    final response = await _client
        .from('clans')
        .insert({
          'name': name.trim(),
          'tag': tag.trim().toUpperCase(),
          'motto': motto.trim(),
          'emblem': emblem,
          'theme_id': themeId,
          'pattern_id': patternId,
          'created_by': user.id,
        })
        .select()
        .single();

    return Clan.fromJson({
      ...Map<String, dynamic>.from(response),
      'member_count': 1,
    });
  }

  @override
  Future<Clan> updateClanIdentity({
    required String clanId,
    required String motto,
    required String emblem,
    required String themeId,
    required String patternId,
  }) async {
    final response = await _client
        .from('clans')
        .update({
          'motto': motto.trim(),
          'emblem': emblem,
          'theme_id': themeId,
          'pattern_id': patternId,
        })
        .eq('id', clanId)
        .select('id')
        .maybeSingle();

    if (response == null) {
      throw StateError('Only clan owners and leaders can customize this clan.');
    }

    final clans = await listClans();
    return clans.firstWhere((clan) => clan.id == clanId);
  }

  @override
  Future<void> setClanMemberLeader({
    required String clanId,
    required String profileId,
    required bool makeLeader,
  }) async {
    await _client.rpc(
      'set_clan_member_leader',
      params: {
        'clan_id_to_manage': clanId,
        'profile_id_to_manage': profileId,
        'make_leader': makeLeader,
      },
    );
  }

  @override
  Future<void> transferClanOwnership({
    required String clanId,
    required String newOwnerProfileId,
  }) async {
    await _client.rpc(
      'transfer_clan_ownership',
      params: {
        'clan_id_to_manage': clanId,
        'new_owner_profile_id': newOwnerProfileId,
      },
    );
  }

  @override
  Future<void> kickClanMember({
    required String clanId,
    required String profileId,
  }) async {
    await _client.rpc(
      'kick_clan_member',
      params: {'clan_id_to_manage': clanId, 'profile_id_to_remove': profileId},
    );
  }

  @override
  Future<String?> leaveClan(String clanId) async {
    final response = await _client.rpc(
      'leave_clan',
      params: {'clan_id_to_leave': clanId},
    );
    return response as String?;
  }

  @override
  Future<void> requestToJoinClan(String clanId) async {
    await _client.rpc('request_clan_join', params: {'clan_id_to_join': clanId});
  }

  @override
  Future<void> cancelJoinRequest(String requestId) async {
    await _client.rpc(
      'cancel_clan_join_request',
      params: {'request_id_to_cancel': requestId},
    );
  }

  @override
  Future<void> reviewJoinRequest({
    required String requestId,
    required bool approve,
  }) async {
    await _client.rpc(
      'review_clan_join_request',
      params: {'request_id_to_review': requestId, 'approve_request': approve},
    );
  }

  @override
  Future<void> archiveClan(String clanId) async {
    await _client.rpc('archive_clan', params: {'clan_id_to_archive': clanId});
  }

  Future<void> _ensureProfile(User user) async {
    final existing = await _client
        .from('profiles')
        .select('id')
        .eq('id', user.id)
        .maybeSingle();

    if (existing != null) return;

    throw const AuthException(
      'Finish setting up your account before creating a clan. '
      'Return to onboarding to complete your details.',
    );
  }
}
