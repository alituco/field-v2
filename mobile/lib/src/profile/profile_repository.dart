import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'profile.dart';

abstract class ProfileRepository {
  String? get currentUserId;

  Future<PlayerProfile> getCurrentProfile();

  Future<PlayerProfile> getProfile(String profileId);

  Future<ProfileConnections> getConnections();

  Future<List<DevProfileOption>> listProfilesForDevelopment();

  Future<void> followProfile(String profileId);

  Future<void> unfollowProfile(String profileId);

  Future<void> updateCurrentProfile(ProfileUpdate update);

  Future<String> uploadCurrentUserAvatar({
    required Uint8List bytes,
    required String fileExtension,
    required String contentType,
  });

  Future<ProfileHighlight> createGoalClip(ProfileGoalClipRequest request);

  Future<ProfileClipMedia> getGoalClipDownload({
    required ProfileHighlightSource sourceType,
    required String matchId,
    required String eventId,
  });

  Future<ProfileHighlight> createCustomClip(ProfileCustomClipRequest request);

  Future<ProfileClipMedia> getCustomClipDownload(
    ProfileCustomClipRequest request,
  );

  Future<ProfileFullGameDownload> prepareFullGameDownload({
    required ProfileHighlightSource sourceType,
    required String matchId,
  });

  Future<ProfileHighlight> refreshHighlight(String highlightId);

  Future<ProfileHighlight> updateHighlightVisibility({
    required String highlightId,
    required bool isPublic,
  });

  Future<void> deleteHighlight(String highlightId);

  Future<int> recordHighlightView(String highlightId);
}

class SupabaseProfileRepository implements ProfileRepository {
  static const _avatarBucket = 'profile-avatars';

  SupabaseClient get _client => Supabase.instance.client;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  Future<ProfileHighlight> createGoalClip(
    ProfileGoalClipRequest request,
  ) async {
    final response = await _client.functions.invoke(
      'profile-goal-clip',
      body: request.toJson(),
    );
    return _highlightFromFunctionResponse(response.data);
  }

  @override
  Future<ProfileClipMedia> getGoalClipDownload({
    required ProfileHighlightSource sourceType,
    required String matchId,
    required String eventId,
  }) async {
    final normalizedMatchId = matchId.trim();
    final normalizedEventId = eventId.trim();
    if (normalizedMatchId.isEmpty || normalizedEventId.isEmpty) {
      throw ArgumentError('A match and goal are required.');
    }
    final response = await _client.functions.invoke(
      'profile-goal-clip',
      body: {
        'action': 'goal_download',
        'source_type': sourceType.wireValue,
        'match_id': normalizedMatchId,
        'event_id': normalizedEventId,
      },
    );
    return _mediaFromFunctionResponse(response.data);
  }

  @override
  Future<ProfileHighlight> createCustomClip(
    ProfileCustomClipRequest request,
  ) async {
    final response = await _client.functions.invoke(
      'profile-goal-clip',
      body: request.toJson(saveToProfile: true),
    );
    return _highlightFromFunctionResponse(response.data);
  }

  @override
  Future<ProfileClipMedia> getCustomClipDownload(
    ProfileCustomClipRequest request,
  ) async {
    final response = await _client.functions.invoke(
      'profile-goal-clip',
      body: request.toJson(saveToProfile: false),
    );
    return _mediaFromFunctionResponse(response.data);
  }

  @override
  Future<ProfileFullGameDownload> prepareFullGameDownload({
    required ProfileHighlightSource sourceType,
    required String matchId,
  }) async {
    final normalizedMatchId = matchId.trim();
    if (normalizedMatchId.isEmpty) throw ArgumentError('A match is required.');
    final response = await _client.functions.invoke(
      'profile-goal-clip',
      body: {
        'action': 'full_game_download',
        'source_type': sourceType.wireValue,
        'match_id': normalizedMatchId,
      },
    );
    final data = response.data;
    if (data is! Map) {
      throw StateError('The full-game download returned an invalid response.');
    }
    return ProfileFullGameDownload.fromJson(Map<String, dynamic>.from(data));
  }

  @override
  Future<ProfileHighlight> refreshHighlight(String highlightId) async {
    final id = highlightId.trim();
    if (id.isEmpty) throw ArgumentError('A clip is required.');
    final response = await _client.functions.invoke(
      'profile-goal-clip',
      body: {'action': 'status', 'highlight_id': id},
    );
    return _highlightFromFunctionResponse(response.data);
  }

  @override
  Future<ProfileHighlight> updateHighlightVisibility({
    required String highlightId,
    required bool isPublic,
  }) async {
    final id = highlightId.trim();
    if (id.isEmpty) throw ArgumentError('A clip is required.');
    final response = await _client.functions.invoke(
      'profile-goal-clip',
      body: {
        'action': 'update_visibility',
        'highlight_id': id,
        'is_public': isPublic,
      },
    );
    return _highlightFromFunctionResponse(response.data);
  }

  @override
  Future<void> deleteHighlight(String highlightId) async {
    final id = highlightId.trim();
    if (id.isEmpty) throw ArgumentError('A clip is required.');
    final response = await _client.functions.invoke(
      'profile-goal-clip',
      body: {'action': 'delete', 'highlight_id': id},
    );
    final data = response.data;
    if (data is! Map || data['deleted'] != true || data['highlight_id'] != id) {
      throw StateError('The clip deletion could not be confirmed.');
    }
  }

  @override
  Future<int> recordHighlightView(String highlightId) async {
    final id = highlightId.trim();
    if (id.isEmpty) throw ArgumentError('A clip is required.');
    final response = await _client.rpc(
      'record_profile_highlight_view',
      params: {'highlight_id_to_use': id},
    );
    if (response is num) return response.toInt();
    if (response is Map) {
      final value = response['views'];
      if (value is num) return value.toInt();
    }
    throw StateError('The clip view could not be recorded.');
  }

  ProfileHighlight _highlightFromFunctionResponse(Object? data) {
    final value = data is Map && data['highlight'] is Map
        ? data['highlight']
        : data;
    if (value is! Map) {
      throw StateError('The clip service returned an invalid response.');
    }
    return ProfileHighlight.fromJson(Map<String, dynamic>.from(value));
  }

  ProfileClipMedia _mediaFromFunctionResponse(Object? data) {
    final value = data is Map && data['media'] is Map ? data['media'] : data;
    if (value is! Map) {
      throw StateError('The clip service returned an invalid response.');
    }
    return ProfileClipMedia.fromJson(Map<String, dynamic>.from(value));
  }

  @override
  Future<PlayerProfile> getCurrentProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AuthException('You need to sign in again.');
    }

    await _ensureProfile(user);

    return _getProfile(user.id);
  }

  @override
  Future<PlayerProfile> getProfile(String profileId) async {
    final id = profileId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(profileId, 'profileId', 'Profile is required.');
    }
    return _getProfile(id);
  }

  Future<PlayerProfile> _getProfile(String profileId) async {
    final results = await Future.wait<dynamic>([
      _loadProfile(profileId),
      _loadCurrentClan(profileId),
      _loadConnectionCounts(profileId),
      _loadHighlights(profileId),
      _loadCareer(profileId),
      _loadPreviousGames(profileId),
      _loadPlayerRating(profileId),
    ]);
    final profile = results[0] as _ProfileRow;
    final clan = results[1] as ProfileClan?;
    final connectionCounts = results[2] as _ConnectionCounts;
    final highlights = results[3] as List<ProfileHighlight>;
    final career = results[4] as List<ProfileCareerEntry>;
    final previousGames = results[5] as List<ProfilePreviousGame>;
    final playerRating = results[6] as ProfilePlayerRating?;
    final stats = clan == null
        ? const _ProfileStats(appearances: 0, goals: 0, assists: 0)
        : await _loadStats(profileId, clan.id);

    return PlayerProfile(
      id: profileId,
      displayName: profile.displayName,
      username: profile.username,
      bio: profile.bio,
      avatarUrl: profile.avatarUrl,
      clan: clan,
      followingCount: connectionCounts.following,
      fansCount: connectionCounts.fans,
      appearances: stats.appearances,
      goals: stats.goals,
      assists: stats.assists,
      highlights: highlights,
      career: career,
      previousGames: previousGames,
      playerRating: playerRating,
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
  Future<List<DevProfileOption>> listProfilesForDevelopment() async {
    if (_client.auth.currentUser == null) {
      throw const AuthException('You need to sign in again.');
    }

    final response = await _client
        .from('profiles')
        .select('id, display_name, username, avatar_url')
        .order('display_name')
        .order('username');
    final rows = [
      for (final row in response as List<dynamic>)
        Map<String, dynamic>.from(row as Map),
    ];
    final profileIds = [for (final row in rows) row['id'] as String];
    final clansByProfileId = await _loadClansForProfiles(profileIds);

    return [
      for (final row in rows)
        DevProfileOption(
          id: row['id'] as String,
          displayName: (row['display_name'] as String? ?? 'Player').trim(),
          username: (row['username'] as String? ?? '').trim(),
          avatarUrl: (row['avatar_url'] as String?)?.trim(),
          clan: clansByProfileId[row['id']],
        ),
    ];
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
        .isFilter('left_at', null)
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
        .inFilter('profile_id', ids)
        .isFilter('left_at', null);
    final rows = response as List<dynamic>;

    return {
      for (final row in rows)
        if (_connectionClanFromRow(Map<String, dynamic>.from(row as Map))
            case final entry?)
          entry.key: entry.value,
    };
  }

  Future<_ProfileStats> _loadStats(String userId, String clanId) async {
    final appearancesResponse = await _client
        .from('fixture_player_appearances')
        .select('fixture_id, fixtures!inner(status)')
        .eq('profile_id', userId)
        .eq('clan_id', clanId)
        .eq('played', true)
        .eq('fixtures.status', 'FINAL');
    final appearanceRows = appearancesResponse as List<dynamic>;
    final fixtureIds = {
      for (final row in appearanceRows)
        (Map<String, dynamic>.from(row as Map)['fixture_id'] as String),
    }.toList(growable: false);

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
          'id, title, thumbnail_url, video_url, duration, views, clan_tag, '
          'download_url, source_type, source_match_id, source_event_id, '
          'is_public, provider_video_id, processing_status, processing_error',
        )
        .eq('profile_id', userId)
        .order('sort_order')
        .order('created_at');
    final rows = response as List<dynamic>;

    final highlights = [
      for (final row in rows)
        ProfileHighlight.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
    return highlights
        .where((highlight) {
          final videoUrl = highlight.videoUrl?.trim();
          return highlight.sourceType != null ||
              (videoUrl != null && videoUrl.isNotEmpty);
        })
        .toList(growable: false);
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
    final response = await _client.rpc(
      'list_profile_career_entries',
      params: {'profile_id_to_use': userId},
    );
    final rows = switch (response) {
      final List value => value,
      final Map value => [value],
      _ => const <dynamic>[],
    };

    return [
      for (final row in rows)
        ProfileCareerEntry.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  Future<List<ProfilePreviousGame>> _loadPreviousGames(String userId) async {
    final response = await _client.rpc(
      'list_profile_previous_games',
      params: {'profile_id_to_use': userId},
    );
    final rows = switch (response) {
      final List value => value,
      final Map value => [value],
      _ => const <dynamic>[],
    };
    return [
      for (final row in rows)
        ProfilePreviousGame.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  Future<ProfilePlayerRating?> _loadPlayerRating(String userId) async {
    final response = await _client.rpc(
      'get_player_rating_history',
      params: {'profile_id_to_use': userId, 'limit_to_use': 50},
    );
    final row = switch (response) {
      final Map value => Map<String, dynamic>.from(value),
      final List value when value.isNotEmpty => Map<String, dynamic>.from(
        value.first as Map,
      ),
      _ => null,
    };
    return row == null ? null : ProfilePlayerRating.fromJson(row);
  }

  Future<void> _ensureProfile(User user) async {
    final existing = await _client
        .from('profiles')
        .select('id')
        .eq('id', user.id)
        .maybeSingle();

    if (existing != null) return;

    throw const AuthException(
      'Finish setting up your account before opening your profile. '
      'Return to onboarding to complete your details.',
    );
  }
}

class _ProfileRow {
  const _ProfileRow({
    required this.displayName,
    required this.username,
    required this.bio,
    this.avatarUrl,
  });

  final String displayName;
  final String username;
  final String bio;
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
