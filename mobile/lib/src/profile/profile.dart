import '../clans/clan.dart';

class PlayerProfile {
  const PlayerProfile({
    required this.id,
    required this.displayName,
    required this.username,
    required this.bio,
    required this.followingCount,
    required this.fansCount,
    required this.appearances,
    required this.goals,
    required this.assists,
    required this.highlights,
    required this.career,
    this.previousGames = const [],
    this.playerRating,
    this.phone,
    this.avatarUrl,
    this.clan,
  });

  final String id;
  final String displayName;
  final String username;
  final String bio;
  final String? phone;
  final String? avatarUrl;
  final ProfileClan? clan;
  final int followingCount;
  final int fansCount;
  final int appearances;
  final int goals;
  final int assists;
  final List<ProfileHighlight> highlights;
  final List<ProfileCareerEntry> career;
  final List<ProfilePreviousGame> previousGames;
  final ProfilePlayerRating? playerRating;

  PlayerProfile copyWith({
    int? followingCount,
    int? fansCount,
    List<ProfileHighlight>? highlights,
  }) {
    return PlayerProfile(
      id: id,
      displayName: displayName,
      username: username,
      bio: bio,
      phone: phone,
      avatarUrl: avatarUrl,
      clan: clan,
      followingCount: followingCount ?? this.followingCount,
      fansCount: fansCount ?? this.fansCount,
      appearances: appearances,
      goals: goals,
      assists: assists,
      highlights: highlights ?? this.highlights,
      career: career,
      previousGames: previousGames,
      playerRating: playerRating,
    );
  }

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words
        .take(2)
        .map((word) => word.substring(0, 1))
        .join()
        .toUpperCase();
  }
}

class ProfilePlayerRating {
  const ProfilePlayerRating({
    required this.skillRating,
    required this.matchesPlayed,
    required this.wins,
    required this.losses,
    required this.draws,
    required this.lastChange,
    required this.region,
    required this.events,
  });

  final int skillRating;
  final int matchesPlayed;
  final int wins;
  final int losses;
  final int draws;
  final int lastChange;
  final String region;
  final List<ProfileRatingEvent> events;

  String get recordLabel => '${wins}W · ${draws}D · ${losses}L';

  factory ProfilePlayerRating.fromJson(Map<String, dynamic> json) {
    final rawEvents = json['events'];
    return ProfilePlayerRating(
      skillRating: _asInt(json['skill_rating'], fallback: 1200),
      matchesPlayed: _asInt(json['matches_played']),
      wins: _asInt(json['wins']),
      losses: _asInt(json['losses']),
      draws: _asInt(json['draws']),
      lastChange: _asInt(json['last_change']),
      region: (json['region'] as String? ?? 'bahrain').trim().toLowerCase(),
      events: rawEvents is! List
          ? const []
          : [
              for (final rawEvent in rawEvents)
                if (rawEvent is Map)
                  ProfileRatingEvent.fromJson(
                    Map<String, dynamic>.from(rawEvent),
                  ),
            ],
    );
  }
}

class ProfileRatingEvent {
  const ProfileRatingEvent({
    required this.id,
    required this.sourceType,
    required this.sourceId,
    required this.playedAt,
    required this.opponentLabel,
    required this.side,
    required this.result,
    required this.ratingBefore,
    required this.ratingChange,
    required this.ratingAfter,
    this.ratingAtMatchStart,
    this.teamAverageRating,
    this.opponentAverageRating,
    this.expectedScore,
    this.calculationVersion,
    this.scoreMargin,
    this.marginMultiplier,
    this.baseRatingChange,
    this.marginBonusApplied,
  });

  final String id;
  final String sourceType;
  final String sourceId;
  final DateTime playedAt;
  final String opponentLabel;
  final String side;
  final String result;
  final int ratingBefore;
  final int ratingChange;
  final int ratingAfter;
  final int? ratingAtMatchStart;
  final double? teamAverageRating;
  final double? opponentAverageRating;
  final double? expectedScore;
  final String? calculationVersion;
  final int? scoreMargin;
  final double? marginMultiplier;
  final int? baseRatingChange;
  final int? marginBonusApplied;

  bool get isSolo => sourceType == 'OPEN_QUEUE';

  String get sourceLabel => isSolo ? 'SOLO' : 'CLAN';

  factory ProfileRatingEvent.fromJson(Map<String, dynamic> json) {
    return ProfileRatingEvent(
      id: (json['event_id'] ?? json['id'] ?? '').toString(),
      sourceType: (json['source_type'] ?? 'CLAN_FIXTURE')
          .toString()
          .toUpperCase(),
      sourceId: (json['source_id'] ?? '').toString(),
      playedAt: _profileGameDate(json['played_at']),
      opponentLabel: (json['opponent_label'] as String? ?? 'Match').trim(),
      side: (json['side'] as String? ?? '').trim().toUpperCase(),
      result: (json['result'] as String? ?? '').trim().toUpperCase(),
      ratingBefore: _asInt(json['rating_before']),
      ratingChange: _asInt(json['rating_change']),
      ratingAfter: _asInt(json['rating_after']),
      ratingAtMatchStart: _asNullableInt(json['rating_at_match_start']),
      teamAverageRating: _asDouble(json['team_average_rating']),
      opponentAverageRating: _asDouble(json['opponent_average_rating']),
      expectedScore: _asDouble(json['expected_score']),
      calculationVersion: switch (json['calculation_version']) {
        null => null,
        final value => value.toString(),
      },
      scoreMargin: _asNullableInt(json['score_margin']),
      marginMultiplier: _asDouble(json['margin_multiplier']),
      baseRatingChange: _asNullableInt(json['base_rating_change']),
      marginBonusApplied: _asNullableInt(json['margin_bonus_applied']),
    );
  }
}

enum ProfileConnectionTab { following, fans }

class ProfileConnectionCounts {
  const ProfileConnectionCounts({
    required this.followingCount,
    required this.fansCount,
  });

  final int followingCount;
  final int fansCount;
}

class ProfileConnections {
  const ProfileConnections({
    required this.following,
    required this.fans,
    required this.discover,
  });

  final List<ProfileConnection> following;
  final List<ProfileConnection> fans;
  final List<ProfileConnection> discover;
}

class DevProfileOption {
  const DevProfileOption({
    required this.id,
    required this.displayName,
    required this.username,
    this.phone,
    this.avatarUrl,
    this.clan,
  });

  final String id;
  final String displayName;
  final String username;
  final String? phone;
  final String? avatarUrl;
  final ProfileClan? clan;

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words
        .take(2)
        .map((word) => word.substring(0, 1))
        .join()
        .toUpperCase();
  }

  String get searchableText => [
    displayName,
    username,
    phone ?? '',
    clan?.name ?? '',
    clan?.tag ?? '',
  ].join(' ').toLowerCase();
}

class ProfileConnection {
  const ProfileConnection({
    required this.id,
    required this.displayName,
    required this.username,
    required this.isFollowedByMe,
    this.avatarUrl,
    this.clan,
  });

  final String id;
  final String displayName;
  final String username;
  final String? avatarUrl;
  final ProfileClan? clan;
  final bool isFollowedByMe;

  ProfileConnection copyWith({bool? isFollowedByMe}) {
    return ProfileConnection(
      id: id,
      displayName: displayName,
      username: username,
      avatarUrl: avatarUrl,
      clan: clan,
      isFollowedByMe: isFollowedByMe ?? this.isFollowedByMe,
    );
  }

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words
        .take(2)
        .map((word) => word.substring(0, 1))
        .join()
        .toUpperCase();
  }
}

class ProfileUpdate {
  const ProfileUpdate({
    required this.displayName,
    required this.username,
    required this.bio,
    required this.avatarUrl,
  });

  final String displayName;
  final String username;
  final String bio;
  final String avatarUrl;
}

class ProfileClan {
  const ProfileClan({
    required this.id,
    required this.name,
    required this.tag,
    required this.emblem,
    required this.themeId,
    required this.patternId,
    required this.skillRating,
  });

  final String id;
  final String name;
  final String tag;
  final String emblem;
  final String themeId;
  final String patternId;
  final int skillRating;

  ClanRank get rank => rankFromRating(skillRating);

  ClanTheme get theme => clanThemeById(themeId);

  factory ProfileClan.fromJson(Map<String, dynamic> json) {
    return ProfileClan(
      id: json['id'] as String? ?? '',
      name: (json['name'] as String? ?? '').trim(),
      tag: (json['tag'] as String? ?? '').trim().toUpperCase(),
      emblem: json['emblem'] as String? ?? '⚽',
      themeId: json['theme_id'] as String? ?? 'pitch',
      patternId: json['pattern_id'] as String? ?? 'solid',
      skillRating: _asInt(json['skill_rating'], fallback: 1500),
    );
  }
}

enum ProfileHighlightStatus { processing, ready, failed }

extension ProfileHighlightStatusX on ProfileHighlightStatus {
  String get wireValue => switch (this) {
    ProfileHighlightStatus.processing => 'PROCESSING',
    ProfileHighlightStatus.ready => 'READY',
    ProfileHighlightStatus.failed => 'FAILED',
  };

  static ProfileHighlightStatus fromWireValue(Object? value) {
    return switch (value?.toString().trim().toUpperCase()) {
      'PROCESSING' => ProfileHighlightStatus.processing,
      'FAILED' || 'ERROR' => ProfileHighlightStatus.failed,
      _ => ProfileHighlightStatus.ready,
    };
  }
}

enum ProfileHighlightSource { clan, solo }

extension ProfileHighlightSourceX on ProfileHighlightSource {
  String get wireValue => switch (this) {
    ProfileHighlightSource.clan => 'CLAN',
    ProfileHighlightSource.solo => 'SOLO',
  };

  static ProfileHighlightSource? fromWireValue(Object? value) {
    return switch (value?.toString().trim().toUpperCase()) {
      'CLAN' => ProfileHighlightSource.clan,
      'SOLO' || 'OPEN_QUEUE' => ProfileHighlightSource.solo,
      _ => null,
    };
  }
}

class ProfileGoalClipRequest {
  const ProfileGoalClipRequest({
    required this.sourceType,
    required this.matchId,
    required this.eventId,
    required this.title,
  });

  final ProfileHighlightSource sourceType;
  final String matchId;
  final String eventId;
  final String title;

  Map<String, dynamic> toJson() {
    final normalizedMatchId = matchId.trim();
    final normalizedEventId = eventId.trim();
    final normalizedTitle = title.trim();
    if (normalizedMatchId.isEmpty || normalizedEventId.isEmpty) {
      throw ArgumentError('A match and goal are required.');
    }
    if (normalizedTitle.length < 2 || normalizedTitle.length > 80) {
      throw ArgumentError(
        'The clip title must be between 2 and 80 characters.',
      );
    }
    return {
      'action': 'create',
      'source_type': sourceType.wireValue,
      'match_id': normalizedMatchId,
      'event_id': normalizedEventId,
      'title': normalizedTitle,
    };
  }
}

class ProfileCustomClipRequest {
  const ProfileCustomClipRequest({
    required this.sourceType,
    required this.matchId,
    required this.startSeconds,
    required this.endSeconds,
    this.title = 'Match clip',
  });

  final ProfileHighlightSource sourceType;
  final String matchId;
  final double startSeconds;
  final double endSeconds;
  final String title;

  double get durationSeconds => endSeconds - startSeconds;

  Map<String, dynamic> toJson({required bool saveToProfile}) {
    final normalizedMatchId = matchId.trim();
    final normalizedTitle = title.trim();
    if (normalizedMatchId.isEmpty) {
      throw ArgumentError('A match is required.');
    }
    if (!startSeconds.isFinite ||
        !endSeconds.isFinite ||
        startSeconds < 0 ||
        endSeconds <= startSeconds ||
        durationSeconds < 1 ||
        durationSeconds > 60.000001) {
      throw ArgumentError('Choose a clip between 1 and 60 seconds.');
    }
    if (saveToProfile &&
        (normalizedTitle.length < 2 || normalizedTitle.length > 80)) {
      throw ArgumentError(
        'The clip title must be between 2 and 80 characters.',
      );
    }
    return {
      'action': 'custom_clip',
      'source_type': sourceType.wireValue,
      'match_id': normalizedMatchId,
      'start_seconds': startSeconds,
      'end_seconds': endSeconds,
      'save_to_profile': saveToProfile,
      if (normalizedTitle.isNotEmpty) 'title': normalizedTitle,
    };
  }
}

class ProfileClipMedia {
  const ProfileClipMedia({
    required this.videoUrl,
    required this.downloadUrl,
    required this.thumbnailUrl,
    required this.duration,
    required this.startSeconds,
    required this.endSeconds,
  });

  final String videoUrl;
  final String downloadUrl;
  final String thumbnailUrl;
  final String duration;
  final double startSeconds;
  final double endSeconds;

  double get durationSeconds => endSeconds - startSeconds;

  factory ProfileClipMedia.fromJson(Map<String, dynamic> json) {
    final videoUrl = _nonEmptyString(json['video_url']);
    final downloadUrl = _nonEmptyString(json['download_url']);
    if (videoUrl == null || downloadUrl == null) {
      throw const FormatException('Clip media is incomplete.');
    }
    return ProfileClipMedia(
      videoUrl: videoUrl,
      downloadUrl: downloadUrl,
      thumbnailUrl: _nonEmptyString(json['thumbnail_url']) ?? '',
      duration: _nonEmptyString(json['duration']) ?? '0:00',
      startSeconds: _asDouble(json['start_seconds']) ?? 0,
      endSeconds: _asDouble(json['end_seconds']) ?? 0,
    );
  }
}

enum ProfileFullGameDownloadStatus { processing, ready, failed }

class ProfileFullGameDownload {
  const ProfileFullGameDownload({
    required this.status,
    this.downloadUrl,
    this.errorMessage,
  });

  final ProfileFullGameDownloadStatus status;
  final String? downloadUrl;
  final String? errorMessage;

  bool get isReady =>
      status == ProfileFullGameDownloadStatus.ready && downloadUrl != null;

  bool get isProcessing => status == ProfileFullGameDownloadStatus.processing;

  factory ProfileFullGameDownload.fromJson(Map<String, dynamic> json) {
    final status = switch (json['status']?.toString().trim().toUpperCase()) {
      'READY' => ProfileFullGameDownloadStatus.ready,
      'FAILED' || 'ERROR' => ProfileFullGameDownloadStatus.failed,
      _ => ProfileFullGameDownloadStatus.processing,
    };
    return ProfileFullGameDownload(
      status: status,
      downloadUrl: _nonEmptyString(json['download_url']),
      errorMessage: _nonEmptyString(json['error'] ?? json['error_message']),
    );
  }
}

class ProfileHighlight {
  const ProfileHighlight({
    required this.id,
    required this.title,
    required this.thumbnailUrl,
    required this.duration,
    required this.views,
    this.videoUrl,
    this.clanTag,
    this.downloadUrl,
    this.sourceType,
    this.sourceMatchId,
    this.sourceEventId,
    this.providerVideoId,
    this.isPublic = true,
    this.status = ProfileHighlightStatus.ready,
    this.errorMessage,
  });

  final String id;
  final String title;
  final String thumbnailUrl;
  final String duration;
  final int views;
  final String? videoUrl;
  final String? clanTag;
  final String? downloadUrl;
  final ProfileHighlightSource? sourceType;
  final String? sourceMatchId;
  final String? sourceEventId;
  final String? providerVideoId;
  final bool isPublic;
  final ProfileHighlightStatus status;
  final String? errorMessage;

  bool get isReady => status == ProfileHighlightStatus.ready;

  bool get isProcessing => status == ProfileHighlightStatus.processing;

  bool get hasPlayableVideo =>
      isReady && videoUrl != null && videoUrl!.trim().isNotEmpty;

  factory ProfileHighlight.fromJson(Map<String, dynamic> json) {
    return ProfileHighlight(
      id: json['id'] as String? ?? '',
      title: (json['title'] as String? ?? '').trim(),
      thumbnailUrl: json['thumbnail_url'] as String? ?? '',
      videoUrl: json['video_url'] as String?,
      duration: json['duration'] as String? ?? '0:00',
      views: _asInt(json['views']),
      clanTag: (json['clan_tag'] as String?)?.trim().toUpperCase(),
      downloadUrl: _nonEmptyString(json['download_url']),
      sourceType: ProfileHighlightSourceX.fromWireValue(json['source_type']),
      sourceMatchId: _nonEmptyString(json['source_match_id']),
      sourceEventId: _nonEmptyString(json['source_event_id']),
      providerVideoId: _nonEmptyString(
        json['provider_video_id'] ?? json['stream_video_id'],
      ),
      isPublic: json['is_public'] as bool? ?? true,
      status: ProfileHighlightStatusX.fromWireValue(
        json['processing_status'] ?? json['status'],
      ),
      errorMessage: _nonEmptyString(
        json['processing_error'] ?? json['error_message'],
      ),
    );
  }

  ProfileHighlight copyWith({int? views, bool? isPublic}) {
    return ProfileHighlight(
      id: id,
      title: title,
      thumbnailUrl: thumbnailUrl,
      duration: duration,
      views: views ?? this.views,
      videoUrl: videoUrl,
      clanTag: clanTag,
      downloadUrl: downloadUrl,
      sourceType: sourceType,
      sourceMatchId: sourceMatchId,
      sourceEventId: sourceEventId,
      providerVideoId: providerVideoId,
      isPublic: isPublic ?? this.isPublic,
      status: status,
      errorMessage: errorMessage,
    );
  }
}

class ProfileCareerEntry {
  const ProfileCareerEntry({
    required this.id,
    this.clanId,
    required this.clanName,
    required this.tag,
    required this.emblem,
    required this.period,
    required this.apps,
    required this.goals,
    required this.isCurrent,
  });

  final String id;
  final String? clanId;
  final String clanName;
  final String tag;
  final String emblem;
  final String period;
  final int apps;
  final int goals;
  final bool isCurrent;

  factory ProfileCareerEntry.fromJson(Map<String, dynamic> json) {
    final clanId = (json['clan_id'] as String?)?.trim();
    return ProfileCareerEntry(
      id: json['id'] as String? ?? '',
      clanId: clanId == null || clanId.isEmpty ? null : clanId,
      clanName: (json['clan_name'] as String? ?? '').trim(),
      tag: (json['tag'] as String? ?? '').trim().toUpperCase(),
      emblem: json['emblem'] as String? ?? '⚽',
      period: (json['period'] as String? ?? '').trim(),
      apps: _asInt(json['apps']),
      goals: _asInt(json['goals']),
      isCurrent: json['is_current'] as bool? ?? false,
    );
  }
}

enum ProfileGameType { clan, solo }

enum ProfileGameOutcome { win, loss, draw }

extension ProfileGameOutcomeX on ProfileGameOutcome {
  String get label => switch (this) {
    ProfileGameOutcome.win => 'WIN',
    ProfileGameOutcome.loss => 'LOSS',
    ProfileGameOutcome.draw => 'DRAW',
  };
}

class ProfilePreviousGame {
  const ProfilePreviousGame({
    required this.id,
    required this.type,
    required this.playedAt,
    required this.venue,
    required this.homeName,
    required this.homeTag,
    required this.homeEmblem,
    required this.awayName,
    required this.awayTag,
    required this.awayEmblem,
    required this.homeScore,
    required this.awayScore,
    required this.playerSide,
    this.playerRole,
  });

  final String id;
  final ProfileGameType type;
  final DateTime playedAt;
  final String venue;
  final String homeName;
  final String homeTag;
  final String homeEmblem;
  final String awayName;
  final String awayTag;
  final String awayEmblem;
  final int homeScore;
  final int awayScore;
  final String playerSide;
  final String? playerRole;

  bool get isSolo => type == ProfileGameType.solo;

  String get typeLabel => isSolo ? 'SOLO' : 'CLAN';

  ProfileGameOutcome? get outcome {
    final isHomeSide = switch (playerSide.trim().toUpperCase()) {
      'HOME' || 'WHITE' => true,
      'AWAY' || 'BLACK' => false,
      _ => null,
    };
    if (isHomeSide == null) return null;
    if (homeScore == awayScore) return ProfileGameOutcome.draw;

    final playerWon = isHomeSide
        ? homeScore > awayScore
        : awayScore > homeScore;
    return playerWon ? ProfileGameOutcome.win : ProfileGameOutcome.loss;
  }

  factory ProfilePreviousGame.fromJson(Map<String, dynamic> json) {
    final rawType = (json['match_type'] ?? json['source_type'] ?? 'CLAN')
        .toString()
        .toUpperCase();
    final isSolo = rawType == 'SOLO' || rawType == 'OPEN_QUEUE';
    final playedAtValue =
        json['played_at'] ?? json['starts_at'] ?? json['match_date'];
    return ProfilePreviousGame(
      id: (json['match_id'] ?? json['source_id'] ?? json['id'] ?? '')
          .toString(),
      type: isSolo ? ProfileGameType.solo : ProfileGameType.clan,
      playedAt: _profileGameDate(playedAtValue),
      venue: (json['venue'] as String? ?? '').trim(),
      homeName: (json['home_name'] as String? ?? (isSolo ? 'White Team' : ''))
          .trim(),
      homeTag: (json['home_tag'] as String? ?? (isSolo ? 'WHITE' : ''))
          .trim()
          .toUpperCase(),
      homeEmblem: json['home_emblem'] as String? ?? (isSolo ? '⚪' : '⚽'),
      awayName: (json['away_name'] as String? ?? (isSolo ? 'Black Team' : ''))
          .trim(),
      awayTag: (json['away_tag'] as String? ?? (isSolo ? 'BLACK' : ''))
          .trim()
          .toUpperCase(),
      awayEmblem: json['away_emblem'] as String? ?? (isSolo ? '⚫' : '⚽'),
      homeScore: _asInt(json['home_score'] ?? json['white_score']),
      awayScore: _asInt(json['away_score'] ?? json['black_score']),
      playerSide: (json['player_side'] ?? json['side'] ?? '')
          .toString()
          .toUpperCase(),
      playerRole: switch (json['player_role'] ?? json['role']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
    );
  }
}

DateTime _profileGameDate(Object? value) {
  if (value is DateTime) return value.toLocal();
  if (value is String) {
    return DateTime.tryParse(value)?.toLocal() ?? DateTime(0);
  }
  return DateTime(0);
}

String? _nonEmptyString(Object? value) {
  final normalized = value?.toString().trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

int? _asNullableInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return num.tryParse(value)?.round();
  return null;
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
