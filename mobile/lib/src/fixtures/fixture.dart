import '../clans/clan.dart';

enum FixtureStatus { open, scheduled, live, finalResult, cancelled }

enum FixtureTimeSlot {
  early('7:00 PM - 8:00 PM'),
  late('8:30 PM - 9:30 PM');

  const FixtureTimeSlot(this.label);

  final String label;
}

const clanFixtureTimeSlots = <FixtureTimeSlot>[FixtureTimeSlot.early];

bool isFixtureMatchDay(DateTime date) {
  return date.weekday == DateTime.tuesday || date.weekday == DateTime.friday;
}

class FixtureClan {
  const FixtureClan({
    required this.id,
    required this.name,
    required this.tag,
    required this.emblem,
    required this.themeId,
    required this.patternId,
    required this.skillRating,
    this.region = 'bahrain',
    this.regionRank,
  });

  final String id;
  final String name;
  final String tag;
  final String emblem;
  final String themeId;
  final String patternId;
  final int skillRating;
  final String region;
  final int? regionRank;

  ClanRank get rank => rankFromRating(skillRating);

  ClanTheme get theme => clanThemeById(themeId);

  factory FixtureClan.fromJson(Map<String, dynamic> json) {
    return FixtureClan(
      id: json['id'] as String,
      name: (json['name'] as String? ?? '').trim(),
      tag: (json['tag'] as String? ?? '').trim().toUpperCase(),
      emblem: json['emblem'] as String? ?? '⚽',
      themeId: json['theme_id'] as String? ?? 'pitch',
      patternId: json['pattern_id'] as String? ?? 'solid',
      skillRating: _asInt(json['skill_rating'], fallback: 1500),
      region: (json['region'] as String? ?? 'bahrain').trim().toLowerCase(),
      regionRank: _asNullableInt(json['region_rank']),
    );
  }

  FixtureClan copyWith({int? regionRank}) {
    return FixtureClan(
      id: id,
      name: name,
      tag: tag,
      emblem: emblem,
      themeId: themeId,
      patternId: patternId,
      skillRating: skillRating,
      region: region,
      regionRank: regionRank ?? this.regionRank,
    );
  }
}

class FixtureSrScenario {
  const FixtureSrScenario({
    required this.label,
    required this.myChange,
    required this.opponentChange,
  });

  final String label;
  final int myChange;
  final int opponentChange;
}

class FixtureClock {
  const FixtureClock({
    required this.status,
    required this.startedAt,
    required this.accumulatedSeconds,
    required this.durationSeconds,
  });

  final String status;
  final DateTime? startedAt;
  final int accumulatedSeconds;
  final int durationSeconds;

  bool get isRunning => status.toUpperCase() == 'RUNNING' && startedAt != null;

  int elapsedSeconds({DateTime? now}) {
    if (!isRunning) return accumulatedSeconds;
    final elapsed = (now ?? DateTime.now()).difference(startedAt!).inSeconds;
    return (accumulatedSeconds + elapsed).clamp(0, 1 << 31).toInt();
  }

  factory FixtureClock.fromJson(Map<String, dynamic> json) {
    return FixtureClock(
      status: json['status'] as String? ?? 'NOT_STARTED',
      startedAt: _asDate(json['started_at']),
      accumulatedSeconds: _asInt(json['accumulated_seconds']),
      durationSeconds: _asInt(json['duration_seconds'], fallback: 3600),
    );
  }
}

class FixtureBroadcast {
  const FixtureBroadcast({
    required this.status,
    this.liveInputId,
    this.activeVideoId,
    this.hlsUrl,
    this.replayHlsUrl,
    this.streamStartedAt,
    this.streamStoppedAt,
    this.recordingReadyAt,
    this.errorMessage,
  });

  final String status;
  final String? liveInputId;
  final String? activeVideoId;
  final String? hlsUrl;
  final String? replayHlsUrl;
  final DateTime? streamStartedAt;
  final DateTime? streamStoppedAt;
  final DateTime? recordingReadyAt;
  final String? errorMessage;

  bool get isLive => status.toUpperCase() == 'LIVE';

  bool get isStarting => status.toUpperCase() == 'STARTING';

  bool get isProcessing => status.toUpperCase() == 'PROCESSING';

  bool get isStopping => status.toUpperCase() == 'STOPPING';

  bool get isReplayReady => status.toUpperCase() == 'REPLAY_READY';

  bool get shouldPoll => isStarting || isLive || isStopping || isProcessing;

  String? get playbackUrl {
    final replay = replayHlsUrl?.trim();
    if (replay != null && replay.isNotEmpty) return replay;
    final live = hlsUrl?.trim();
    return live == null || live.isEmpty ? null : live;
  }

  factory FixtureBroadcast.fromJson(Map<String, dynamic> json) {
    return FixtureBroadcast(
      status: json['status'] as String? ?? 'NOT_CONFIGURED',
      liveInputId: json['live_input_id'] as String?,
      activeVideoId: json['active_video_id'] as String?,
      hlsUrl: json['hls_url'] as String?,
      replayHlsUrl: json['replay_hls_url'] as String?,
      streamStartedAt: _asDate(json['stream_started_at']),
      streamStoppedAt: _asDate(json['stream_stopped_at']),
      recordingReadyAt: _asDate(json['recording_ready_at']),
      errorMessage: json['error_message'] as String?,
    );
  }
}

class FixtureParticipant {
  const FixtureParticipant({
    required this.id,
    required this.displayName,
    this.username,
  });

  final String id;
  final String displayName;
  final String? username;

  factory FixtureParticipant.fromJson(Map<String, dynamic> json) {
    return FixtureParticipant(
      id: json['id'] as String? ?? '',
      displayName: (json['display_name'] as String? ?? 'Unknown').trim(),
      username: (json['username'] as String?)?.trim(),
    );
  }
}

class FixtureLineupPlayer {
  const FixtureLineupPlayer({
    required this.id,
    required this.displayName,
    required this.role,
    required this.side,
    required this.played,
    required this.isMe,
    this.username,
    this.avatarUrl,
    this.ratingAtTeamAssignment,
    this.ratingAtMatchStart,
    this.ratingChange,
  });

  final String id;
  final String displayName;
  final String? username;
  final String? avatarUrl;
  final String role;
  final String side;
  final bool played;
  final bool isMe;
  final int? ratingAtTeamAssignment;
  final int? ratingAtMatchStart;
  final int? ratingChange;

  int? get displayedRating => ratingAtMatchStart ?? ratingAtTeamAssignment;

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words.take(2).map((word) => word[0]).join().toUpperCase();
  }
}

class FixtureScorer {
  const FixtureScorer({
    required this.id,
    required this.fixtureId,
    required this.clanId,
    required this.profileId,
    required this.minute,
    required this.createdAt,
    this.assistProfileId,
    this.scorer,
    this.assist,
  });

  final String id;
  final String fixtureId;
  final String clanId;
  final String profileId;
  final String? assistProfileId;
  final int minute;
  final DateTime? createdAt;
  final FixtureParticipant? scorer;
  final FixtureParticipant? assist;

  String get scorerName => scorer?.displayName ?? 'Unknown';

  String get assistName => assist?.displayName ?? 'Unknown';

  factory FixtureScorer.fromJson(Map<String, dynamic> json) {
    final scorer = _nestedMap(json['scorer'] ?? json['profiles']);
    final assist = _nestedMap(json['assist']);

    return FixtureScorer(
      id: json['id'] as String,
      fixtureId: json['fixture_id'] as String? ?? '',
      clanId: json['clan_id'] as String? ?? '',
      profileId: json['profile_id'] as String? ?? '',
      assistProfileId: json['assist_profile_id'] as String?,
      minute: _asInt(json['minute'], fallback: 1),
      createdAt: _asDate(json['created_at']),
      scorer: scorer == null ? null : FixtureParticipant.fromJson(scorer),
      assist: assist == null ? null : FixtureParticipant.fromJson(assist),
    );
  }
}

class FixtureTimelineEvent {
  const FixtureTimelineEvent({
    required this.id,
    required this.fixtureId,
    required this.eventType,
    required this.minute,
    required this.second,
    required this.createdAt,
    this.occurredAt,
    this.clanId,
    this.profileId,
    this.assistProfileId,
    this.note,
    this.player,
    this.assist,
  });

  final String id;
  final String fixtureId;
  final String eventType;
  final String? clanId;
  final String? profileId;
  final String? assistProfileId;
  final int minute;
  final int second;
  final String? note;
  final DateTime? createdAt;
  final DateTime? occurredAt;
  final FixtureParticipant? player;
  final FixtureParticipant? assist;

  String get playerName => player?.displayName ?? 'Unknown';

  String get assistName => assist?.displayName ?? 'Unknown';

  DateTime? get highlightTimestamp => occurredAt ?? createdAt;

  factory FixtureTimelineEvent.fromJson(Map<String, dynamic> json) {
    final player = _nestedMap(json['player'] ?? json['profiles']);
    final assist = _nestedMap(json['assist']);

    return FixtureTimelineEvent(
      id: json['id'] as String,
      fixtureId: json['fixture_id'] as String? ?? '',
      eventType: json['event_type'] as String? ?? 'EVENT',
      clanId: json['clan_id'] as String?,
      profileId: json['profile_id'] as String?,
      assistProfileId: json['assist_profile_id'] as String?,
      minute: _asInt(json['minute']),
      second: _asInt(json['second']),
      note: (json['note'] as String?)?.trim(),
      createdAt: _asDate(json['created_at']),
      occurredAt: _asDate(json['occurred_at']),
      player: player == null ? null : FixtureParticipant.fromJson(player),
      assist: assist == null ? null : FixtureParticipant.fromJson(assist),
    );
  }
}

class FixtureHighlightMoment {
  const FixtureHighlightMoment({
    required this.event,
    required this.start,
    required this.end,
  });

  final FixtureTimelineEvent event;
  final Duration start;
  final Duration end;
}

class Fixture {
  const Fixture({
    required this.id,
    required this.status,
    required this.homeClanId,
    required this.venue,
    required this.day,
    required this.timeSlot,
    required this.matchDate,
    required this.createdBy,
    required this.homeClan,
    this.awayClanId,
    this.homeScore,
    this.awayScore,
    this.winnerClanId,
    this.homeSrChange,
    this.awaySrChange,
    this.videoUrl,
    this.awayClan,
    this.homePaidBy,
    this.awayPaidBy,
    this.homePaidAt,
    this.awayPaidAt,
    this.homePayer,
    this.awayPayer,
    this.cancelledAt,
    this.cancellationCode,
    this.cancellationReason,
    this.cancelledBy,
    this.cancellationContext = const {},
    this.cancellationActor,
    this.createdAt,
    this.updatedAt,
    this.clock,
    this.broadcast,
    this.scorers = const [],
    this.timeline = const [],
    this.homeAveragePlayerRating,
    this.awayAveragePlayerRating,
    this.matchAveragePlayerRating,
    this.teamRatingSpread,
    this.teamsAssignedAt,
    this.homeLineup = const [],
    this.awayLineup = const [],
  });

  final String id;
  final FixtureStatus status;
  final String homeClanId;
  final String? awayClanId;
  final String venue;
  final String day;
  final String timeSlot;
  final DateTime matchDate;
  final int? homeScore;
  final int? awayScore;
  final String? winnerClanId;
  final int? homeSrChange;
  final int? awaySrChange;
  final String? videoUrl;
  final String createdBy;
  final FixtureClan homeClan;
  final FixtureClan? awayClan;
  final String? homePaidBy;
  final String? awayPaidBy;
  final DateTime? homePaidAt;
  final DateTime? awayPaidAt;
  final FixtureParticipant? homePayer;
  final FixtureParticipant? awayPayer;
  final DateTime? cancelledAt;
  final String? cancellationCode;
  final String? cancellationReason;
  final String? cancelledBy;
  final Map<String, dynamic> cancellationContext;
  final FixtureParticipant? cancellationActor;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final FixtureClock? clock;
  final FixtureBroadcast? broadcast;
  final List<FixtureScorer> scorers;
  final List<FixtureTimelineEvent> timeline;
  final int? homeAveragePlayerRating;
  final int? awayAveragePlayerRating;
  final int? matchAveragePlayerRating;
  final int? teamRatingSpread;
  final DateTime? teamsAssignedAt;
  final List<FixtureLineupPlayer> homeLineup;
  final List<FixtureLineupPlayer> awayLineup;

  bool get isOpen => status == FixtureStatus.open;

  bool get isFinal => status == FixtureStatus.finalResult;

  bool get isLive => status == FixtureStatus.live;

  bool get isCancelled => status == FixtureStatus.cancelled;

  String? get livePlaybackUrl => _nonEmptyUrl(broadcast?.hlsUrl);

  String? get fullGamePlaybackUrl {
    return _nonEmptyUrl(broadcast?.replayHlsUrl) ?? _nonEmptyUrl(videoUrl);
  }

  /// Goal windows aligned to the recording's wall clock for post-game playback.
  List<FixtureHighlightMoment> get highlightMoments {
    return _highlightMomentsFromOrigin(broadcast?.streamStartedAt);
  }

  /// Goal windows aligned from the finalized replay rather than its delayed
  /// live-status timestamp. Both known recording boundaries are considered
  /// because either boundary can be stale: startup reporting can be delayed,
  /// while a repeated stop request can move the recorded stop time forward.
  List<FixtureHighlightMoment> highlightMomentsForReplay(
    Duration replayDuration,
  ) {
    final startedAtMoments = _highlightMomentsFromOrigin(
      broadcast?.streamStartedAt,
    );
    final streamStoppedAt = broadcast?.streamStoppedAt;
    if (streamStoppedAt == null || replayDuration <= Duration.zero) {
      return startedAtMoments;
    }

    final stoppedAtMoments = _highlightMomentsFromOrigin(
      streamStoppedAt.subtract(replayDuration),
    );
    final stoppedAtUsableGoals = _usableHighlightCount(
      stoppedAtMoments,
      replayDuration,
    );
    final startedAtUsableGoals = _usableHighlightCount(
      startedAtMoments,
      replayDuration,
    );

    // Prefer the stop-derived boundary on a tie. It is the more accurate
    // correction when the live-start notification arrived late, and preserves
    // the existing replay alignment in that case. The start boundary only
    // takes over when it demonstrably recovers more playable goal windows.
    return startedAtUsableGoals > stoppedAtUsableGoals
        ? startedAtMoments
        : stoppedAtMoments;
  }

  int _usableHighlightCount(
    List<FixtureHighlightMoment> moments,
    Duration replayDuration,
  ) {
    return moments.where((moment) => moment.start < replayDuration).length;
  }

  List<FixtureHighlightMoment> _highlightMomentsFromOrigin(
    DateTime? replayOrigin,
  ) {
    if (!isFinal) return const [];

    if (replayOrigin == null) return const [];

    const leadIn = Duration(seconds: 10);
    // Referee events use wall-clock time while the encoded recording can trail
    // that clock. The extra ten seconds absorbs that playback offset and still
    // leaves a full reaction window after the visible goal.
    const followThrough = Duration(seconds: 20);
    final moments = <FixtureHighlightMoment>[];
    final goals =
        timeline.where((event) {
          return event.eventType.toUpperCase() == 'GOAL' &&
              event.highlightTimestamp != null &&
              event.note?.toLowerCase() != 'admin correction';
        }).toList()..sort((left, right) {
          return left.highlightTimestamp!.compareTo(right.highlightTimestamp!);
        });

    for (final goal in goals) {
      final offset = goal.highlightTimestamp!.difference(replayOrigin);
      final end = offset + followThrough;
      if (end <= Duration.zero) continue;

      final start = offset - leadIn;
      moments.add(
        FixtureHighlightMoment(
          event: goal,
          start: start.isNegative ? Duration.zero : start,
          end: end,
        ),
      );
    }

    return moments;
  }

  String get cancellationTitle {
    return switch (cancellationCode) {
      'NO_OPPONENT_24H' => 'No Opponent Joined',
      'CLAN_ARCHIVED' => 'Clan Deleted',
      'SLOT_CONFLICT_MIGRATION' => 'Schedule Conflict',
      'ADMIN_CANCELLED' => 'Cancelled by Admin',
      _ => 'Match Cancelled',
    };
  }

  String get cancellationDisplayReason {
    final reason = cancellationReason?.trim();
    if (reason != null && reason.isNotEmpty) return reason;
    return 'This match was cancelled.';
  }

  String get statusLabel {
    return switch (status) {
      FixtureStatus.open => 'Looking for opponent',
      FixtureStatus.scheduled => 'Scheduled',
      FixtureStatus.live => 'Live Now',
      FixtureStatus.finalResult => 'Final',
      FixtureStatus.cancelled => 'Cancelled',
    };
  }

  String get detailStatusLabel {
    return switch (status) {
      FixtureStatus.open => 'Open',
      FixtureStatus.scheduled => 'Upcoming',
      FixtureStatus.live => 'Live Now',
      FixtureStatus.finalResult => 'Full Time',
      FixtureStatus.cancelled => 'Cancelled',
    };
  }

  String get dateKey {
    final month = matchDate.month.toString().padLeft(2, '0');
    final day = matchDate.day.toString().padLeft(2, '0');
    return '${matchDate.year}-$month-$day';
  }

  String get monthDay => '${_monthShort(matchDate.month)} ${matchDate.day}';

  String get longDate {
    return '${_weekdayName(matchDate.weekday)}, ${_monthName(matchDate.month)} ${matchDate.day}, ${matchDate.year}';
  }

  String get dayShort => day.length >= 3 ? day.substring(0, 3) : day;

  FixtureClan? opponentFor(String clanId) {
    if (homeClanId == clanId) return awayClan;
    if (awayClanId == clanId) return homeClan;
    return null;
  }

  int? scoreFor(String clanId) {
    if (scorers.isNotEmpty) {
      return scorers.where((scorer) => scorer.clanId == clanId).length;
    }
    if (homeClanId == clanId) return homeScore;
    if (awayClanId == clanId) return awayScore;
    return null;
  }

  int? srChangeFor(String clanId) {
    if (homeClanId == clanId) return homeSrChange;
    if (awayClanId == clanId) return awaySrChange;
    return null;
  }

  FixtureParticipant? payerFor(String clanId) {
    if (homeClanId == clanId) return homePayer;
    if (awayClanId == clanId) return awayPayer;
    return null;
  }

  DateTime? paidAtFor(String clanId) {
    if (homeClanId == clanId) return homePaidAt;
    if (awayClanId == clanId) return awayPaidAt;
    return null;
  }

  factory Fixture.fromJson(Map<String, dynamic> json) {
    final homeClan = _nestedMap(json['home_clan'] ?? json['clans']) ?? const {};
    final awayClan = _nestedMap(json['away_clan']);
    final clock = _nestedMap(json['fixture_clock_states']);
    final broadcast = _nestedMap(json['fixture_broadcasts']);
    final homePayer = _nestedMap(json['home_payer']);
    final awayPayer = _nestedMap(json['away_payer']);
    final cancellationActor = _nestedMap(json['cancellation_actor']);
    final homeLineup = _fixtureLineupFromJson(
      json['fixture_player_appearances'],
      'HOME',
    );
    final awayLineup = _fixtureLineupFromJson(
      json['fixture_player_appearances'],
      'AWAY',
    );
    final homeAverage = _lineupAverageRating(homeLineup);
    final awayAverage = _lineupAverageRating(awayLineup);
    final matchAverage = homeAverage == null || awayAverage == null
        ? null
        : ((homeAverage + awayAverage) / 2).round();

    return Fixture(
      id: json['id'] as String,
      status: _fixtureStatusFromWire(json['status'] as String? ?? 'OPEN'),
      homeClanId: json['home_clan_id'] as String,
      awayClanId: json['away_clan_id'] as String?,
      venue: (json['venue'] as String? ?? '').trim(),
      day: json['day'] as String? ?? 'TUESDAY',
      timeSlot: json['time_slot'] as String? ?? FixtureTimeSlot.early.label,
      matchDate: _asDate(json['match_date']) ?? DateTime.now(),
      homeScore: _scoreFromRowsOrValue(
        json['fixture_scorers'],
        json['home_clan_id'] as String?,
        json['home_score'],
      ),
      awayScore: _scoreFromRowsOrValue(
        json['fixture_scorers'],
        json['away_clan_id'] as String?,
        json['away_score'],
      ),
      winnerClanId: json['winner_clan_id'] as String?,
      homeSrChange: _asNullableInt(json['home_sr_change']),
      awaySrChange: _asNullableInt(json['away_sr_change']),
      videoUrl: json['video_url'] as String?,
      createdBy: json['created_by'] as String? ?? '',
      homeClan: FixtureClan.fromJson(homeClan),
      awayClan: awayClan == null ? null : FixtureClan.fromJson(awayClan),
      homePaidBy: json['home_paid_by'] as String?,
      awayPaidBy: json['away_paid_by'] as String?,
      homePaidAt: _asDate(json['home_paid_at']),
      awayPaidAt: _asDate(json['away_paid_at']),
      homePayer: homePayer == null
          ? null
          : FixtureParticipant.fromJson(homePayer),
      awayPayer: awayPayer == null
          ? null
          : FixtureParticipant.fromJson(awayPayer),
      cancelledAt: _asDate(json['cancelled_at']),
      cancellationCode: json['cancellation_code'] as String?,
      cancellationReason: json['cancellation_reason'] as String?,
      cancelledBy: json['cancelled_by'] as String?,
      cancellationContext: _jsonMap(json['cancellation_context']),
      cancellationActor: cancellationActor == null
          ? null
          : FixtureParticipant.fromJson(cancellationActor),
      createdAt: _asDate(json['created_at']),
      updatedAt: _asDate(json['updated_at']),
      clock: clock == null ? null : FixtureClock.fromJson(clock),
      broadcast: broadcast == null
          ? null
          : FixtureBroadcast.fromJson(broadcast),
      scorers: _scorersFromJson(json['fixture_scorers']),
      timeline: _timelineFromJson(json['fixture_events']),
      homeAveragePlayerRating:
          _asNullableInt(json['home_average_player_rating']) ?? homeAverage,
      awayAveragePlayerRating:
          _asNullableInt(json['away_average_player_rating']) ?? awayAverage,
      matchAveragePlayerRating:
          _asNullableInt(json['match_average_player_rating']) ?? matchAverage,
      teamRatingSpread:
          _asNullableInt(json['team_rating_spread']) ??
          (homeAverage == null || awayAverage == null
              ? null
              : (homeAverage - awayAverage).abs()),
      teamsAssignedAt: _asDate(json['teams_assigned_at']),
      homeLineup: homeLineup,
      awayLineup: awayLineup,
    );
  }
}

class MyClanMembership {
  const MyClanMembership({required this.clan, required this.role});

  final FixtureClan clan;
  final String role;

  bool get isOwner => role == 'owner';

  bool get isLeader => role == 'leader';

  bool get canManageMatches => isOwner || isLeader;
}

String fixtureStatusToWire(FixtureStatus status) {
  return switch (status) {
    FixtureStatus.open => 'OPEN',
    FixtureStatus.scheduled => 'SCHEDULED',
    FixtureStatus.live => 'LIVE',
    FixtureStatus.finalResult => 'FINAL',
    FixtureStatus.cancelled => 'CANCELLED',
  };
}

FixtureStatus _fixtureStatusFromWire(String value) {
  return switch (value.toUpperCase()) {
    'SCHEDULED' => FixtureStatus.scheduled,
    'LIVE' => FixtureStatus.live,
    'FINAL' => FixtureStatus.finalResult,
    'CANCELLED' => FixtureStatus.cancelled,
    _ => FixtureStatus.open,
  };
}

Map<String, dynamic>? _nestedMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty) {
    final first = value.first;
    if (first is Map<String, dynamic>) return first;
    if (first is Map) return Map<String, dynamic>.from(first);
  }
  return null;
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}

List<FixtureLineupPlayer> _fixtureLineupFromJson(Object? value, String side) {
  if (value is! List) return const [];
  final players = <FixtureLineupPlayer>[];
  for (final rawRow in value) {
    if (rawRow is! Map) continue;
    final row = Map<String, dynamic>.from(rawRow);
    if ((row['side'] as String? ?? '').toUpperCase() != side) continue;
    final profile = _nestedMap(row['player']);
    if (profile == null) continue;
    players.add(
      FixtureLineupPlayer(
        id: row['profile_id'] as String? ?? profile['id'] as String? ?? '',
        displayName: (profile['display_name'] as String? ?? 'Unknown').trim(),
        username: (profile['username'] as String?)?.trim(),
        avatarUrl: (profile['avatar_url'] as String?)?.trim(),
        role: (row['position'] as String? ?? '').trim(),
        side: side,
        played: row['played'] as bool? ?? false,
        isMe: row['is_me'] as bool? ?? false,
        ratingAtMatchStart: _asNullableInt(row['rating_at_start']),
        ratingChange: _asNullableInt(row['rating_change']),
      ),
    );
  }
  players.sort((left, right) {
    if (left.played != right.played) return left.played ? -1 : 1;
    return left.displayName.compareTo(right.displayName);
  });
  return players;
}

int? _lineupAverageRating(List<FixtureLineupPlayer> players) {
  if (players.isEmpty) return null;
  final played = players.where((player) => player.played).toList();
  final included = played.isEmpty ? players : played;
  final ratings = included
      .map((player) => player.displayedRating)
      .whereType<int>()
      .toList();
  if (ratings.isEmpty) return null;
  return (ratings.reduce((total, rating) => total + rating) / ratings.length)
      .round();
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
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime? _asDate(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

String? _nonEmptyUrl(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

int? _scoreFromRowsOrValue(Object? rows, String? clanId, Object? value) {
  if (clanId == null) return _asNullableInt(value);
  if (rows is List && rows.isNotEmpty) {
    return rows.where((row) => row is Map && row['clan_id'] == clanId).length;
  }
  return _asNullableInt(value);
}

List<FixtureScorer> _scorersFromJson(Object? value) {
  if (value is! List) return const [];
  final scorers = [
    for (final row in value)
      if (row is Map) FixtureScorer.fromJson(Map<String, dynamic>.from(row)),
  ];
  scorers.sort((a, b) => a.minute.compareTo(b.minute));
  return scorers;
}

List<FixtureTimelineEvent> _timelineFromJson(Object? value) {
  if (value is! List) return const [];
  final events = [
    for (final row in value)
      if (row is Map)
        FixtureTimelineEvent.fromJson(Map<String, dynamic>.from(row)),
  ];
  events.sort((a, b) {
    final minute = b.minute.compareTo(a.minute);
    if (minute != 0) return minute;
    return b.second.compareTo(a.second);
  });
  return events;
}

String _monthShort(int month) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return months[(month - 1).clamp(0, 11)];
}

String _monthName(int month) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return months[(month - 1).clamp(0, 11)];
}

String _weekdayName(int weekday) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return weekdays[(weekday - 1).clamp(0, 6)];
}
