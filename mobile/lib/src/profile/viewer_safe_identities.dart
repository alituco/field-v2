import 'package:supabase_flutter/supabase_flutter.dart';

/// Replaces authored identity in read payloads without removing official rows,
/// participant IDs, scores, ratings, counts or payment/booking information.
/// Missing safe identities never fall back to a payload's old photo or bio.
Future<Map<String, dynamic>> viewerSafeIdentityPayload(
  SupabaseClient client,
  Map<String, dynamic> payload,
) async => (await _safePayload(client, payload)) as Map<String, dynamic>;

Future<List<dynamic>> viewerSafeIdentityRows(
  SupabaseClient client,
  List<dynamic> rows,
) async => (await _safePayload(client, rows)) as List<dynamic>;

class _IdentityRef {
  const _IdentityRef(
    this.row,
    this.id, {
    required this.clan,
    this.aliases = const {},
  });
  final Map<String, dynamic> row;
  final String id;
  final bool clan;
  final Map<String, String> aliases;
}

Future<Object?> _safePayload(SupabaseClient client, Object? payload) async {
  final viewerId = client.auth.currentUser?.id;
  final references = <_IdentityRef>[];
  Object? copy(
    Object? value, {
    String? inheritedProfileId,
    String? inheritedClanId,
    bool clanContext = false,
  }) {
    if (value is List) {
      return <dynamic>[for (final item in value) copy(item)];
    }
    if (value is! Map) {
      return value;
    }
    final row = <String, dynamic>{
      for (final entry in value.entries) entry.key as String: entry.value,
    };
    final profileId = row['profile_id'] ?? row['id'] ?? inheritedProfileId;
    final clanId = row['clan_id'] ?? row['id'] ?? inheritedClanId;
    final hasPlayerContent =
        [
          'display_name',
          'username',
          'bio',
          'avatar_url',
        ].any(row.containsKey) ||
        (row.containsKey('highlight') && row['profile_id'] is String);
    final hasClanContent =
        (row.containsKey('name') && row.containsKey('tag')) || clanContext;
    if (hasPlayerContent && profileId is String && profileId.isNotEmpty) {
      references.add(_IdentityRef(row, profileId, clan: false));
    } else if (hasClanContent && clanId is String && clanId.isNotEmpty) {
      references.add(_IdentityRef(row, clanId, clan: true));
    }
    if (!hasClanContent &&
        row['clan_id'] is String &&
        row.containsKey('clan_name')) {
      references.add(
        _IdentityRef(
          row,
          row['clan_id'] as String,
          clan: true,
          aliases: const {'name': 'clan_name'},
        ),
      );
    }
    for (final key in row.keys.toList()) {
      row[key] = copy(
        row[key],
        inheritedProfileId: key == 'profiles' || key == 'player'
            ? row['profile_id'] as String?
            : null,
        inheritedClanId: key == 'clans' || key == 'clan'
            ? row['clan_id'] as String?
            : null,
        clanContext: const {
          'clans',
          'clan',
          'home_clan',
          'away_clan',
        }.contains(key),
      );
    }
    return row;
  }

  final result = copy(payload);
  Future<Map<String, Map<String, dynamic>>> identities(bool clan) async {
    final ids = references
        .where((ref) => ref.clan == clan)
        .map((ref) => ref.id)
        .toSet()
        .toList();
    final result = <String, Map<String, dynamic>>{};
    for (var offset = 0; offset < ids.length; offset += 100) {
      final batch = ids.sublist(offset, (offset + 100).clamp(0, ids.length));
      final response = await client.rpc(
        clan
            ? 'list_fieldrush_clan_identities'
            : 'list_fieldrush_profile_identities',
        params: {clan ? 'clan_ids_to_use' : 'profile_ids_to_use': batch},
      );
      if (response is! List) {
        throw const FormatException('Player content is unavailable.');
      }
      for (final value in response) {
        if (value is! Map ||
            value['id'] is! String ||
            !batch.contains(value['id'])) {
          throw const FormatException('Player content is unavailable.');
        }
        final identity = Map<String, dynamic>.from(value);
        if (identity['content_hidden'] is! bool) {
          throw const FormatException('Player content is unavailable.');
        }
        result[identity['id'] as String] = identity;
      }
    }
    return result;
  }

  final safe = await Future.wait([identities(false), identities(true)]);
  if (client.auth.currentUser?.id != viewerId) {
    throw const AuthException('Sign in again to view player content.');
  }
  for (final ref in references) {
    final identity = safe[ref.clan ? 1 : 0][ref.id];
    final fields = ref.clan
        ? <String, dynamic>{
            'name': 'Hidden clan',
            'tag': 'HIDE',
            'motto': '',
            'emblem': '⚽',
            'theme_id': 'pitch',
            'pattern_id': 'solid',
          }
        : <String, dynamic>{
            'display_name': 'Blocked player',
            'username': '',
            'bio': '',
            'avatar_url': null,
          };
    for (final entry in fields.entries) {
      final key = ref.aliases[entry.key] ?? entry.key;
      if (ref.row.containsKey(key)) {
        ref.row[key] = identity?[entry.key] ?? entry.value;
      }
    }
    ref.row['content_hidden'] =
        identity == null || identity['content_hidden'] == true;
  }
  return result;
}
