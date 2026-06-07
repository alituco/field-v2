import 'package:supabase_flutter/supabase_flutter.dart';

import 'clan.dart';

abstract class ClanRepository {
  Future<List<Clan>> listClans();

  Future<Clan> createClan({
    required String name,
    required String tag,
    required String motto,
    required String emblem,
    required String themeId,
    required String patternId,
  });
}

class SupabaseClanRepository implements ClanRepository {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<List<Clan>> listClans() async {
    final response = await _client.rpc('list_clans');
    final rows = response as List<dynamic>;

    return [
      for (final row in rows) Clan.fromJson(Map<String, dynamic>.from(row)),
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

  Future<void> _ensureProfile(User user) async {
    final metadata = user.userMetadata;
    final metadataName = metadata?['display_name'] ?? metadata?['name'];
    final fallbackName =
        metadataName is String && _isValidDisplayName(metadataName)
        ? metadataName.trim()
        : 'Player';

    await _client.from('profiles').upsert({
      'id': user.id,
      'phone': user.phone,
      'display_name': fallbackName,
    }, onConflict: 'id');
  }

  bool _isValidDisplayName(String value) {
    final length = value.trim().length;
    return length >= 2 && length <= 24;
  }
}
