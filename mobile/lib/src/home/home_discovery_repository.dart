import 'package:supabase_flutter/supabase_flutter.dart';
import '../ranking/player_rating_visibility.dart';

class HomePlayerResult with PublicPlayerRating {
  const HomePlayerResult({
    required this.id,
    required this.name,
    required this.username,
    this.avatarUrl,
    this.skillRating,
    this.matchesPlayed = 0,
    this.cityName,
    this.isSelf = false,
    this.visibility,
  });
  final String id;
  final String name;
  final String username;
  final String? avatarUrl;
  @override
  final int? skillRating;
  @override
  final int matchesPlayed;
  @override
  final PlayerRatingVisibility? visibility;
  final String? cityName;
  final bool isSelf;
}

class HomeNotification {
  const HomeNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    this.readAt,
    this.entityType,
    this.entityId,
    this.data = const {},
  });
  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
  final DateTime? readAt;
  final String? entityType;
  final String? entityId;
  final Map<String, dynamic> data;

  factory HomeNotification.fromJson(Map<String, dynamic> json) {
    final payload = json['data'];
    return HomeNotification(
      id: json['id'] as String,
      title: json['title'] as String,
      body: json['body'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      readAt: DateTime.tryParse(json['read_at'] as String? ?? ''),
      entityType: json['related_entity_type'] as String?,
      entityId: json['related_entity_id'] as String?,
      data: payload is Map ? Map<String, dynamic>.from(payload) : const {},
    );
  }

  // Entity IDs are not interchangeable: party notifications refer to a
  // membership and reliability notifications refer to an incident. Only these
  // known types may use a payload field to identify their destination.
  String? get openQueueGameId => switch (entityType?.trim().toUpperCase()) {
    'OPEN_QUEUE_GAME' => _nonEmptyString(entityId),
    'OPEN_QUEUE_PARTY_MEMBERSHIP' => _nonEmptyString(data['game_id']),
    _ => null,
  };

  String? get fixtureId => switch (entityType?.trim().toUpperCase()) {
    'FIXTURE' => _nonEmptyString(entityId),
    'CLAN_RELIABILITY_INCIDENT' => _nonEmptyString(data['fixture_id']),
    _ => null,
  };
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final result = value.trim();
  return result.isEmpty ? null : result;
}

abstract interface class HomeDiscoveryRepository {
  Future<List<HomePlayerResult>> searchPlayers(String query);
  Future<List<HomeNotification>> notifications();
  Future<void> markRead(String notificationId);
  Future<void> dismiss(String notificationId);
}

class SupabaseHomeDiscoveryRepository implements HomeDiscoveryRepository {
  SupabaseHomeDiscoveryRepository({SupabaseClient? client})
    : _injectedClient = client;

  final SupabaseClient? _injectedClient;
  SupabaseClient get _client => _injectedClient ?? Supabase.instance.client;

  @override
  Future<List<HomePlayerResult>> searchPlayers(String query) async {
    final input = query.trim().replaceFirst(RegExp(r'^@'), '');
    if (input.length < 2) return [];
    // One bounded public RPC supplies current-season placement and earned city
    // without fetching individual accounts or issuing one rating call per row.
    final rows =
        await _client.rpc(
              'search_fieldrush_players',
              params: {'query_to_use': input},
            )
            as List;
    return [
      for (final row in rows)
        HomePlayerResult(
          id: row['id'] as String,
          name: row['display_name'] as String? ?? 'Player',
          username: row['username'] as String? ?? '',
          avatarUrl: _nonEmptyString(row['avatar_url']),
          skillRating: publicRatingNumber(
            Map<String, dynamic>.from(row as Map),
            'skill_rating',
          ),
          visibility: PlayerRatingVisibility.fromJson(
            Map<String, dynamic>.from(row),
          ),
          matchesPlayed: (row['matches_played'] as num?)?.toInt() ?? 0,
          cityName: _nonEmptyString(row['city_name']),
          isSelf: row['is_self'] == true,
        ),
    ];
  }

  @override
  Future<List<HomeNotification>> notifications() async {
    final user = _client.auth.currentUser;
    if (user == null) return [];
    final rows = await _client
        .from('notifications')
        .select(
          'id,title,body,created_at,read_at,related_entity_type,related_entity_id,data',
        )
        .eq('recipient_profile_id', user.id)
        .isFilter('resolved_at', null)
        .isFilter('dismissed_at', null)
        .order('created_at', ascending: false)
        .limit(50);
    return [for (final row in rows) HomeNotification.fromJson(row)];
  }

  @override
  Future<void> markRead(String notificationId) async {
    await _client.rpc(
      'mark_my_home_notification_read',
      params: {'notification_id_to_use': notificationId},
    );
  }

  @override
  Future<void> dismiss(String notificationId) async {
    await _client.rpc(
      'dismiss_my_home_notification',
      params: {'notification_id_to_use': notificationId},
    );
  }
}
