import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'profile.dart';
import '../core/read_timeout.dart';

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

abstract interface class ProfileClipRecommendationsRepository {
  Future<List<ProfileClipRecommendation>> getClipRecommendations({
    required String highlightId,
    int limit = 8,
  });
}

/// Identity-only snapshot for navigation/Home. Loading an avatar and greeting
/// must not wait for clips, career history, follow counts or rating history.
abstract interface class ProfileSummaryRepository {
  Future<PlayerProfile> getCurrentProfileSummary();
}

/// Public identity can render while optional statistics and clips are loading.
abstract interface class PublicProfileSummaryRepository {
  Future<PlayerProfile> getProfileSummary(String profileId);
}

extension ProfileClipRecommendationsAccess on ProfileRepository {
  Future<List<ProfileClipRecommendation>> getClipRecommendations({
    required String highlightId,
    int limit = 8,
  }) async {
    final repository = this;
    if (repository is ProfileClipRecommendationsRepository) {
      return (repository as ProfileClipRecommendationsRepository)
          .getClipRecommendations(highlightId: highlightId, limit: limit);
    }
    return const [];
  }
}

class SupabaseProfileRepository
    implements
        ProfileRepository,
        ProfileClipRecommendationsRepository,
        ProfileSummaryRepository,
        PublicProfileSummaryRepository {
  SupabaseProfileRepository({SupabaseClient? client})
    : _injectedClient = client;

  static const _avatarBucket = 'profile-avatars';

  final SupabaseClient? _injectedClient;
  SupabaseClient get _client => _injectedClient ?? Supabase.instance.client;

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

  @override
  Future<List<ProfileClipRecommendation>> getClipRecommendations({
    required String highlightId,
    int limit = 8,
  }) async {
    final id = highlightId.trim();
    if (id.isEmpty) throw ArgumentError('A clip is required.');
    if (limit < 1 || limit > 20) {
      throw ArgumentError.value(limit, 'limit', 'Use a limit from 1 to 20.');
    }
    final response = await _client.rpc(
      'get_profile_clip_recommendations',
      params: {'highlight_id_to_use': id, 'limit_to_use': limit},
    );
    if (response is! List) {
      throw StateError('The next clips could not be loaded.');
    }
    final recommendations = [
      for (final row in response)
        if (row is Map)
          ProfileClipRecommendation.fromJson(Map<String, dynamic>.from(row))
        else
          throw StateError('The next clips returned an invalid response.'),
    ];
    // Keep the display boundary private even if an older server returns an
    // overbroad recommendation response during a coordinated rollout.
    return recommendations
        .where(
          (recommendation) =>
              recommendation.highlight.id != id &&
              recommendation.highlight.hasPlayableVideo &&
              (recommendation.highlight.isPublic ||
                  recommendation.profileId == currentUserId),
        )
        .take(limit)
        .toList(growable: false);
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

    await _ensureProfile(user).timeout(fieldReadTimeout);

    return _getProfile(user.id);
  }

  @override
  Future<PlayerProfile> getCurrentProfileSummary() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AuthException('You need to sign in again.');
    }
    return getProfileSummary(user.id);
  }

  @override
  Future<PlayerProfile> getProfileSummary(String profileId) async {
    final id = profileId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(profileId, 'profileId', 'Profile is required.');
    }
    final profile = await _loadProfile(id).timeout(fieldReadTimeout);
    return PlayerProfile(
      id: id,
      displayName: profile.displayName,
      username: profile.username,
      bio: profile.bio,
      avatarUrl: profile.avatarUrl,
      followingCount: 0,
      fansCount: 0,
      appearances: 0,
      goals: 0,
      assists: 0,
      highlights: const [],
      career: const [],
    );
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
    final pending = <String>{};
    Future<T> part<T>(String name, Future<T> request) {
      pending.add(name);
      return request.whenComplete(() => pending.remove(name));
    }

    final results =
        await Future.wait<dynamic>([
          part('identity', _loadProfile(profileId)),
          part('clan', _loadCurrentClan(profileId)),
          part('connections', _loadConnectionCounts(profileId)),
          part('clips', _loadHighlights(profileId)),
          part('career', _loadCareer(profileId)),
          part('history', _loadPreviousGames(profileId)),
          part('rating', _loadPlayerRating(profileId)),
        ]).timeout(
          fieldReadTimeout,
          onTimeout: () => throw TimeoutException(
            'Profile read timed out; pending sections: ${pending.join(', ')}',
            fieldReadTimeout,
          ),
        );
    final profile = results[0] as _ProfileRow;
    final clan = results[1] as ProfileClan?;
    final connectionCounts = results[2] as _ConnectionCounts;
    final highlights = results[3] as List<ProfileHighlight>;
    final career = results[4] as List<ProfileCareerEntry>;
    final previousGames = results[5] as List<ProfilePreviousGame>;
    final playerRating = results[6] as ProfilePlayerRating?;
    final stats = clan == null
        ? const _ProfileStats(appearances: 0, goals: 0, assists: 0)
        : await _loadStats(profileId, clan.id).timeout(fieldReadTimeout);

    return PlayerProfile(
      id: profileId,
      displayName: profile.displayName,
      username: profile.username,
      bio: profile.bio,
      avatarUrl: profile.avatarUrl,
      clan: clan,
      followingCount: connectionCounts.following,
      fansCount: connectionCounts.fans,
      isFollowedByMe: connectionCounts.isFollowedByMe,
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

    final relatedIds = await Future.wait([
      _loadConnectionIds(user.id, following: true),
      _loadConnectionIds(user.id, following: false),
    ]);
    final followingIds = relatedIds[0];
    final fanIds = relatedIds[1];
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
    // Discovery is intentionally one page, but relationships must not depend
    // on that page. Direct profile reads still enforce active-account RLS.
    final profilesById = await _loadConnectionProfiles({
      ...followingIds,
      ...fanIds,
    });
    final clansByProfileId = await _loadClansForProfiles({
      ...profilesById.keys,
      for (final row in profileRows) row['id'] as String,
    });

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

  Future<List<String>> _loadConnectionIds(
    String userId, {
    required bool following,
  }) async {
    const pageSize = 500;
    final relatedColumn = following ? 'following_id' : 'follower_id';
    final ownerColumn = following ? 'follower_id' : 'following_id';
    final ids = <String>{};
    for (var offset = 0; ; offset += pageSize) {
      final rows = await _client
          .from('profile_follows')
          .select(relatedColumn)
          .eq(ownerColumn, userId)
          .order('created_at', ascending: false)
          .order(relatedColumn, ascending: true)
          .range(offset, offset + pageSize - 1)
          .timeout(fieldReadTimeout);
      ids.addAll([for (final row in rows) row[relatedColumn] as String]);
      if (rows.length < pageSize) break;
    }
    return ids.toList(growable: false);
  }

  Future<Map<String, Map<String, dynamic>>> _loadConnectionProfiles(
    Set<String> profileIds,
  ) async {
    final ids = profileIds.toList(growable: false);
    final profiles = <String, Map<String, dynamic>>{};
    for (var offset = 0; offset < ids.length; offset += 100) {
      final end = (offset + 100).clamp(0, ids.length);
      final rows = await _client
          .from('profiles')
          .select('id, display_name, username, avatar_url')
          .inFilter('id', ids.sublist(offset, end));
      for (final row in rows) {
        profiles[row['id'] as String] = Map<String, dynamic>.from(row);
      }
    }
    return profiles;
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

    final clans = <String, ProfileClan>{};
    for (var offset = 0; offset < ids.length; offset += 100) {
      final end = (offset + 100).clamp(0, ids.length);
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
          .inFilter('profile_id', ids.sublist(offset, end))
          .isFilter('left_at', null);
      for (final row in response) {
        final entry = _connectionClanFromRow(Map<String, dynamic>.from(row));
        if (entry != null) clans[entry.key] = entry.value;
      }
    }
    return clans;
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
          'id, profile_id, title, thumbnail_url, video_url, duration, views, clan_tag, '
          'download_url, source_type, source_match_id, source_event_id, '
          'is_public, provider_video_id, processing_status, processing_error, created_at',
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
    final viewerId = currentUserId;
    // Count only relationships whose other profile is visible under RLS, as
    // getConnections does. Exact totals are independent of server page caps.
    final following = await _client
        .from('profile_follows')
        .select(
          'following_id, profile:profiles!profile_follows_following_id_fkey!inner(id)',
        )
        .eq('follower_id', userId)
        .limit(1)
        .count(CountOption.exact);
    final fans = await _client
        .from('profile_follows')
        .select(
          'follower_id, profile:profiles!profile_follows_follower_id_fkey!inner(id)',
        )
        .eq('following_id', userId)
        .limit(1)
        .count(CountOption.exact);
    // List responses can be capped by the server. Check the unique viewer /
    // player pair directly rather than inferring it from a page of fans.
    final viewerFollow = viewerId == null || viewerId == userId
        ? null
        : await _client
              .from('profile_follows')
              .select('follower_id')
              .eq('following_id', userId)
              .eq('follower_id', viewerId)
              .maybeSingle();

    return _ConnectionCounts(
      following: following.count,
      fans: fans.count,
      isFollowedByMe: viewerFollow != null,
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
    // This table-returning RPC is subject to PostgREST's 1,000-row cap.
    // Public lifetime totals must not silently become the most recent page.
    const pageSize = 500;
    final records = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += pageSize) {
      final response = await _client
          .rpc(
            'list_profile_previous_games',
            params: {'profile_id_to_use': userId},
          )
          .range(offset, offset + pageSize - 1)
          .timeout(fieldReadTimeout);
      final rows = switch (response) {
        final List value => value,
        final Map value => [value],
        _ => const <dynamic>[],
      };
      records.addAll([
        for (final row in rows) Map<String, dynamic>.from(row as Map),
      ]);
      if (rows.length < pageSize) break;
    }
    final games = [
      for (final row in records) ProfilePreviousGame.fromJson(row),
    ];
    final soloIds = games
        .where((game) => game.isSolo && game.id.trim().isNotEmpty)
        .map((game) => game.id)
        .toSet()
        .toList();
    final timezones = <String, String>{};
    final actualStarts = <String, DateTime>{};
    // The historical RPC does not return timezone. Fetch only public game
    // metadata in bounded batches, without changing its database signature.
    // Date metadata has one shared budget across all batches. An outage must
    // not spend the full profile deadline on optional enrichment.
    final metadataTimer = Stopwatch()..start();
    for (var start = 0; start < soloIds.length; start += 100) {
      final end = start + 100 < soloIds.length ? start + 100 : soloIds.length;
      final remaining = const Duration(seconds: 4) - metadataTimer.elapsed;
      if (remaining <= Duration.zero) break;
      try {
        final metadata = await _client
            .from('open_queue_games')
            .select('id,timezone,open_queue_events(occurred_at)')
            .inFilter('id', soloIds.sublist(start, end))
            .eq('open_queue_events.event_type', 'MATCH_STARTED')
            .timeout(remaining);
        for (final row in metadata) {
          final timezone = row['timezone'];
          if (timezone is String && timezone.trim().isNotEmpty) {
            timezones[row['id'] as String] = timezone.trim();
          }
          // An early or delayed kickoff is the played time, not its advertised
          // booking slot. Use the first actual start for position tie-breaking.
          final events = row['open_queue_events'];
          if (events is List) {
            for (final event in events.whereType<Map>()) {
              final value = event['occurred_at'];
              final occurredAt = value is String
                  ? DateTime.tryParse(value)
                  : null;
              if (occurredAt == null) continue;
              final id = row['id'] as String;
              final previous = actualStarts[id];
              if (previous == null || occurredAt.isBefore(previous)) {
                actualStarts[id] = occurredAt;
              }
            }
          }
        }
      } catch (_) {
        // The screen labels unknown solo dates rather than guessing a market.
        break;
      }
    }
    return [
      for (var index = 0; index < records.length; index++)
        ProfilePreviousGame.fromJson({
          ...records[index],
          if (games[index].isSolo && actualStarts[games[index].id] != null)
            'played_at': actualStarts[games[index].id]!.toIso8601String(),
          'timezone': games[index].isSolo
              ? timezones[games[index].id]
              : 'Asia/Bahrain',
        }),
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
  const _ConnectionCounts({
    required this.following,
    required this.fans,
    required this.isFollowedByMe,
  });

  final int following;
  final int fans;
  final bool isFollowedByMe;
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
