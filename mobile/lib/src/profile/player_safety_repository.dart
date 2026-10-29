import 'package:supabase_flutter/supabase_flutter.dart';

/// A player's own safety preferences. Blocking changes content/following,
/// never official game participation, results, bookings or payments.
class PlayerSafetyState {
  const PlayerSafetyState({
    required this.profileId,
    required this.blockedByMe,
    required this.interactionBlocked,
  });

  final String profileId;
  final bool blockedByMe;
  final bool interactionBlocked;

  factory PlayerSafetyState.fromJson(Map<String, dynamic> json) {
    final id = json['profile_id'];
    final own = json['blocked_by_me'];
    final blocked = json['interaction_blocked'];
    if (id is! String ||
        id.isEmpty ||
        own is! bool ||
        blocked is! bool ||
        (own && !blocked)) {
      throw const FormatException('Player safety settings are unavailable.');
    }
    return PlayerSafetyState(
      profileId: id,
      blockedByMe: own,
      interactionBlocked: blocked,
    );
  }
}

class BlockedPlayer {
  const BlockedPlayer({
    required this.profileId,
    required this.username,
    required this.displayName,
    this.blockedAt,
  });

  final String profileId;
  final String username;
  final String displayName;
  final DateTime? blockedAt;

  String get label => username.isNotEmpty ? '@$username' : displayName;

  factory BlockedPlayer.fromJson(Map<String, dynamic> json) {
    final id = json['profile_id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Blocked players are unavailable.');
    }
    return BlockedPlayer(
      profileId: id,
      username: (json['username'] as String? ?? '').trim(),
      displayName: (json['display_name'] as String? ?? 'Player').trim(),
      blockedAt: DateTime.tryParse(json['blocked_at'] as String? ?? ''),
    );
  }
}

abstract interface class PlayerSafetyRepository {
  String? get currentUserId;
  Future<PlayerSafetyState> getState(String profileId);
  Future<PlayerSafetyState> setBlocked(
    String profileId, {
    required bool blocked,
  });
  Future<List<BlockedPlayer>> listBlockedPlayers();
}

/// Optional capability: existing repositories/test doubles need not perform
/// safety reads. The production repository always supplies this capability.
abstract interface class PlayerSafetyRepositoryProvider {
  PlayerSafetyRepository get playerSafetyRepository;
}

PlayerSafetyRepository? playerSafetyFor(Object repository) =>
    repository is PlayerSafetyRepositoryProvider
    ? repository.playerSafetyRepository
    : null;

class SupabasePlayerSafetyRepository implements PlayerSafetyRepository {
  SupabasePlayerSafetyRepository({SupabaseClient? client})
    : _injectedClient = client;

  final SupabaseClient? _injectedClient;
  SupabaseClient get _client => _injectedClient ?? Supabase.instance.client;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  String _target(String profileId, {bool allowSelf = true}) {
    if (currentUserId == null) {
      throw const AuthException('You need to sign in again.');
    }
    final id = profileId.trim();
    if (id.isEmpty || (!allowSelf && id == currentUserId)) {
      throw ArgumentError('Choose another player.');
    }
    return id;
  }

  @override
  Future<PlayerSafetyState> getState(String profileId) async {
    final id = _target(profileId);
    final value = await _client.rpc(
      'get_fieldrush_player_safety',
      params: {'profile_id_to_use': id},
    );
    final state = PlayerSafetyState.fromJson(_object(value));
    if (state.profileId != id) {
      throw const FormatException('Player safety settings are unavailable.');
    }
    return state;
  }

  @override
  Future<PlayerSafetyState> setBlocked(
    String profileId, {
    required bool blocked,
  }) async {
    final id = _target(profileId, allowSelf: false);
    final value = await _client.rpc(
      'set_fieldrush_player_block',
      params: {'profile_id_to_use': id, 'blocked_to_use': blocked},
    );
    final state = PlayerSafetyState.fromJson(_object(value));
    if (state.profileId != id || state.blockedByMe != blocked) {
      throw const FormatException(
        'The player safety change was not confirmed.',
      );
    }
    return state;
  }

  @override
  Future<List<BlockedPlayer>> listBlockedPlayers() async {
    if (currentUserId == null) {
      throw const AuthException('You need to sign in again.');
    }
    final value = await _client.rpc('list_fieldrush_blocked_players');
    if (value is! List) {
      throw const FormatException('Blocked players are unavailable.');
    }
    return [for (final row in value) BlockedPlayer.fromJson(_object(row))];
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map) {
    throw const FormatException('Player safety settings are unavailable.');
  }
  return Map<String, dynamic>.from(value);
}
