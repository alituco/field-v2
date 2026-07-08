import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'profile.dart';

abstract class ProfileRepository {
  Future<PlayerProfile> getCurrentProfile();

  Future<ProfileConnections> getConnections();

  Future<void> followProfile(String profileId);

  Future<void> unfollowProfile(String profileId);

  Future<void> updateCurrentProfile(ProfileUpdate update);

  Future<String> uploadCurrentUserAvatar({
    required Uint8List bytes,
    required String fileExtension,
    required String contentType,
  });
}

class SupabaseProfileRepository implements ProfileRepository {
  static const _avatarBucket = 'profile-avatars';

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<PlayerProfile> getCurrentProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AuthException('You need to sign in again.');
    }

    await _ensureProfile(user);

    final profile = await _loadProfile(user.id);
    final clan = await _loadCurrentClan(user.id);
    final stats = clan == null
        ? const _ProfileStats(appearances: 0, goals: 0, assists: 0)
        : await _loadStats(user.id, clan.id);
    final connectionCounts = await _loadConnectionCounts(user.id);
    final highlights = await _loadHighlights(user.id);
    final career = await _loadCareer(user.id);

    return PlayerProfile(
      id: user.id,
      displayName: profile.displayName,
      username: profile.username,
      bio: profile.bio,
      phone: profile.phone,
      avatarUrl: profile.avatarUrl,
      clan: clan,
      followingCount: connectionCounts.following,
      fansCount: connectionCounts.fans,
      appearances: stats.appearances,
      goals: stats.goals,
      assists: stats.assists,
      highlights: highlights,
      career: career,
    );
  }

  @override
  Future<ProfileConnections> getConnections() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AuthException('You need to sign in again.');
    }

    final followingRows = await _client
        .from('profile_follows')
        .select('following_id')
        .eq('follower_id', user.id)
        .order('created_at', ascending: false);
    final fanRows = await _client
        .from('profile_follows')
        .select('follower_id')
        .eq('following_id', user.id)
        .order('created_at', ascending: false);

    final followingIds = [
      for (final row in followingRows as List<dynamic>)
        Map<String, dynamic>.from(row as Map)['following_id'] as String,
    ];
    final fanIds = [
      for (final row in fanRows as List<dynamic>)
        Map<String, dynamic>.from(row as Map)['follower_id'] as String,
    ];
    final followedByMe = followingIds.toSet();

    final profilesResponse = await _client
        .from('profiles')
        .select('id, display_name, username, avatar_url')
        .neq('id', user.id)
        .order('display_name');
    final profileRows = [
      for (final row in profilesResponse as List<dynamic>)
        Map<String, dynamic>.from(row as Map),
    ];
    final profilesById = {
      for (final row in profileRows) row['id'] as String: row,
    };
    final clansByProfileId = await _loadClansForProfiles(profilesById.keys);

    ProfileConnection? buildConnection(String profileId) {
      final row = profilesById[profileId];
      if (row == null) return null;
      return _connectionFromJson(
        row,
        clan: clansByProfileId[profileId],
        isFollowedByMe: followedByMe.contains(profileId),
      );
    }

    final following = [
      for (final id in followingIds)
        if (buildConnection(id) case final connection?) connection,
    ];
    final fans = [
      for (final id in fanIds)
        if (buildConnection(id) case final connection?) connection,
    ];
    final discover = [
      for (final row in profileRows)
        if (!followedByMe.contains(row['id']))
          _connectionFromJson(
            row,
            clan: clansByProfileId[row['id']],
            isFollowedByMe: false,
          ),
    ];

    return ProfileConnections(
      following: following,
      fans: fans,
      discover: discover,
    );
  }

  @override
  Future<void> followProfile(String profileId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw const AuthException('You need to sign in again.');
    }
    if (profileId == userId) return;

    await _client.from('profile_follows').upsert({
      'follower_id': userId,
      'following_id': profileId,
    }, onConflict: 'follower_id,following_id');
  }

  @override
  Future<void> unfollowProfile(String profileId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw const AuthException('You need to sign in again.');
    }

    await _client
        .from('profile_follows')
        .delete()
        .eq('follower_id', userId)
        .eq('following_id', profileId);
  }

  @override
  Future<void> updateCurrentProfile(ProfileUpdate update) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw const AuthException('You need to sign in again.');
    }

    await _client
        .from('profiles')
        .update({
          'display_name': update.displayName.trim(),
          'username': update.username.trim().toLowerCase(),
          'bio': update.bio.trim(),
          'avatar_url': update.avatarUrl.trim().isEmpty
              ? null
              : update.avatarUrl.trim(),
        })
        .eq('id', userId);
  }

  @override
  Future<String> uploadCurrentUserAvatar({
    required Uint8List bytes,
    required String fileExtension,
    required String contentType,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw const AuthException('You need to sign in again.');
    }

    final extension = _normalizedAvatarExtension(fileExtension, contentType);
    final path =
        '$userId/avatar-${DateTime.now().millisecondsSinceEpoch}.$extension';

    await _client.storage
        .from(_avatarBucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType),
        );

    return _client.storage.from(_avatarBucket).getPublicUrl(path);
  }

  Future<_ProfileRow> _loadProfile(String userId) async {
    final response = await _client
        .from('profiles')
        .select('''
          id,
          phone,
          display_name,
          username,
          bio,
          avatar_url
        ''')
        .eq('id', userId)
        .single();

    return _ProfileRow.fromJson(Map<String, dynamic>.from(response));
  }

  Future<ProfileClan?> _loadCurrentClan(String userId) async {
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

    return ProfileClan.fromJson(Map<String, dynamic>.from(clanData));
  }

  Future<Map<String, ProfileClan>> _loadClansForProfiles(
    Iterable<String> profileIds,
  ) async {
    final ids = profileIds.toList();
    if (ids.isEmpty) return const {};

    final response = await _client
        .from('clan_members')
        .select('''
          profile_id,
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
        .inFilter('profile_id', ids);
    final rows = response as List<dynamic>;

    return {
      for (final row in rows)
        if (_connectionClanFromRow(Map<String, dynamic>.from(row as Map))
            case final entry?)
          entry.key: entry.value,
    };
  }

  Future<_ProfileStats> _loadStats(String userId, String clanId) async {
    final fixturesResponse = await _client
        .from('fixtures')
        .select('id')
        .eq('status', 'FINAL')
        .or('home_clan_id.eq.$clanId,away_clan_id.eq.$clanId');
    final fixtureRows = fixturesResponse as List<dynamic>;
    final fixtureIds = [
      for (final row in fixtureRows)
        (Map<String, dynamic>.from(row as Map)['id'] as String),
    ];

    if (fixtureIds.isEmpty) {
      return const _ProfileStats(appearances: 0, goals: 0, assists: 0);
    }

    final scorersResponse = await _client
        .from('fixture_scorers')
        .select('profile_id, assist_profile_id')
        .inFilter('fixture_id', fixtureIds);
    final scorerRows = scorersResponse as List<dynamic>;

    var goals = 0;
    var assists = 0;
    for (final row in scorerRows) {
      final scorer = Map<String, dynamic>.from(row as Map);
      if (scorer['profile_id'] == userId) goals += 1;
      if (scorer['assist_profile_id'] == userId) assists += 1;
    }

    return _ProfileStats(
      appearances: fixtureIds.length,
      goals: goals,
      assists: assists,
    );
  }

  Future<List<ProfileHighlight>> _loadHighlights(String userId) async {
    final response = await _client
        .from('profile_highlights')
        .select(
          'id, title, thumbnail_url, video_url, duration, views, clan_tag',
        )
        .eq('profile_id', userId)
        .order('sort_order')
        .order('created_at');
    final rows = response as List<dynamic>;

    return [
      for (final row in rows)
        ProfileHighlight.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  Future<_ConnectionCounts> _loadConnectionCounts(String userId) async {
    final followingRows = await _client
        .from('profile_follows')
        .select('following_id')
        .eq('follower_id', userId);
    final fanRows = await _client
        .from('profile_follows')
        .select('follower_id')
        .eq('following_id', userId);

    return _ConnectionCounts(
      following: (followingRows as List<dynamic>).length,
      fans: (fanRows as List<dynamic>).length,
    );
  }

  Future<List<ProfileCareerEntry>> _loadCareer(String userId) async {
    final response = await _client
        .from('profile_career_entries')
        .select('id, clan_name, tag, emblem, period, apps, goals, is_current')
        .eq('profile_id', userId)
        .order('sort_order')
        .order('created_at');
    final rows = response as List<dynamic>;

    return [
      for (final row in rows)
        ProfileCareerEntry.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
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

class _ProfileRow {
  const _ProfileRow({
    required this.displayName,
    required this.username,
    required this.bio,
    this.phone,
    this.avatarUrl,
  });

  final String displayName;
  final String username;
  final String bio;
  final String? phone;
  final String? avatarUrl;

  factory _ProfileRow.fromJson(Map<String, dynamic> json) {
    final displayName = (json['display_name'] as String? ?? 'Player').trim();
    final username = (json['username'] as String? ?? '').trim();

    return _ProfileRow(
      displayName: displayName.isEmpty ? 'Player' : displayName,
      username: username.isEmpty
          ? _usernameFromDisplayName(displayName)
          : username,
      bio: (json['bio'] as String? ?? '').trim(),
      phone: json['phone'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }
}

class _ProfileStats {
  const _ProfileStats({
    required this.appearances,
    required this.goals,
    required this.assists,
  });

  final int appearances;
  final int goals;
  final int assists;
}

class _ConnectionCounts {
  const _ConnectionCounts({required this.following, required this.fans});

  final int following;
  final int fans;
}

MapEntry<String, ProfileClan>? _connectionClanFromRow(
  Map<String, dynamic> row,
) {
  final profileId = row['profile_id'] as String?;
  final clanData = row['clans'];
  if (profileId == null || clanData is! Map) return null;

  return MapEntry(
    profileId,
    ProfileClan.fromJson(Map<String, dynamic>.from(clanData)),
  );
}

ProfileConnection _connectionFromJson(
  Map<String, dynamic> json, {
  required ProfileClan? clan,
  required bool isFollowedByMe,
}) {
  final displayName = (json['display_name'] as String? ?? 'Player').trim();
  final username = (json['username'] as String? ?? '').trim();

  return ProfileConnection(
    id: json['id'] as String? ?? '',
    displayName: displayName.isEmpty ? 'Player' : displayName,
    username: username.isEmpty
        ? _usernameFromDisplayName(displayName)
        : username,
    avatarUrl: json['avatar_url'] as String?,
    clan: clan,
    isFollowedByMe: isFollowedByMe,
  );
}

String _normalizedAvatarExtension(String fileExtension, String contentType) {
  final extension = fileExtension
      .toLowerCase()
      .replaceAll('.', '')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  return switch (extension) {
    'jpg' || 'jpeg' => 'jpg',
    'png' => 'png',
    'webp' => 'webp',
    _ when contentType == 'image/png' => 'png',
    _ when contentType == 'image/webp' => 'webp',
    _ => 'jpg',
  };
}

String _usernameFromDisplayName(String displayName) {
  final normalized = displayName
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (normalized.length >= 2) return normalized;
  return 'player';
}
