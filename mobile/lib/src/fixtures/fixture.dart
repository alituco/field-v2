import '../clans/clan.dart';

enum FixtureStatus { open, scheduled, live, finalResult, cancelled }

enum FixtureTimeSlot {
  early('7:00 PM - 8:00 PM'),
  late('8:30 PM - 9:30 PM');

  const FixtureTimeSlot(this.label);

  final String label;
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
  final FixtureParticipant? player;
  final FixtureParticipant? assist;

  String get playerName => player?.displayName ?? 'Unknown';

  String get assistName => assist?.displayName ?? 'Unknown';

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
      player: player == null ? null : FixtureParticipant.fromJson(player),
      assist: assist == null ? null : FixtureParticipant.fromJson(assist),
    );
  }
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
    this.scorers = const [],
    this.timeline = const [],
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
  final List<FixtureScorer> scorers;
  final List<FixtureTimelineEvent> timeline;

  bool get isOpen => status == FixtureStatus.open;

  bool get isFinal => status == FixtureStatus.finalResult;

  bool get isLive => status == FixtureStatus.live;

  bool get isCancelled => status == FixtureStatus.cancelled;

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
    final homePayer = _nestedMap(json['home_payer']);
    final awayPayer = _nestedMap(json['away_payer']);
    final cancellationActor = _nestedMap(json['cancellation_actor']);

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
      scorers: _scorersFromJson(json['fixture_scorers']),
      timeline: _timelineFromJson(json['fixture_events']),
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
