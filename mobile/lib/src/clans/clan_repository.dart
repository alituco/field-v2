import 'package:supabase_flutter/supabase_flutter.dart';

import '../fixtures/fixture.dart';
import 'clan.dart';

abstract class ClanRepository {
  Future<List<Clan>> listClans();

  Future<ClanMembership?> getMyClanMembership();

  Future<List<ClanMember>> listClanMembers(String clanId);

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
}

class SupabaseClanRepository implements ClanRepository {
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
  Future<ClanMembership?> getMyClanMembership() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    final response = await _client
        .from('clan_members')
        .select('clan_id, role')
        .eq('profile_id', userId)
        .maybeSingle();

    if (response == null) return null;
    return ClanMembership.fromJson(Map<String, dynamic>.from(response));
  }

  @override
  Future<List<ClanMember>> listClanMembers(String clanId) async {
    final response = await _client
        .from('clan_members')
        .select('profile_id, role, created_at, profiles(display_name, phone)')
        .eq('clan_id', clanId)
        .order('created_at');
    final rows = response as List<dynamic>;

    return [
      for (final row in rows)
        ClanMember.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
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
      throw StateError('Only the clan owner can customize this clan.');
    }

    final clans = await listClans();
    return clans.firstWhere((clan) => clan.id == clanId);
  }

  Future<void> _ensureProfile(User user) async {
    final metadata = user.userMetadata;
    final metadataName = metadata?['display_name'] ?? metadata?['name'];
    final fallbackName =
        metadataName is String && _isValidDisplayName(metadataName)
        ? metadataName.trim()
        : 'Player';

    final existing = await _client
        .from('profiles')
        .select('id')
        .eq('id', user.id)
        .maybeSingle();

    if (existing != null) return;

    await _client.from('profiles').insert({
      'id': user.id,
      'phone': user.phone,
      'display_name': fallbackName,
    });
  }

  bool _isValidDisplayName(String value) {
    final length = value.trim().length;
    return length >= 2 && length <= 24;
  }
}
