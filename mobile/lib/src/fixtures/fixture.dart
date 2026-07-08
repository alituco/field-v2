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

  factory FixtureClan.fromJson(Map<String, dynamic> json) {
    return FixtureClan(
      id: json['id'] as String,
      name: (json['name'] as String? ?? '').trim(),
      tag: (json['tag'] as String? ?? '').trim().toUpperCase(),
      emblem: json['emblem'] as String? ?? '⚽',
      themeId: json['theme_id'] as String? ?? 'pitch',
      patternId: json['pattern_id'] as String? ?? 'solid',
      skillRating: _asInt(json['skill_rating'], fallback: 1500),
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
    this.cancelledAt,
    this.cancellationReason,
    this.createdAt,
    this.updatedAt,
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
  final DateTime? cancelledAt;
  final String? cancellationReason;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isOpen => status == FixtureStatus.open;

  bool get isFinal => status == FixtureStatus.finalResult;

  bool get isLive => status == FixtureStatus.live;

  bool get isCancelled => status == FixtureStatus.cancelled;

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
    if (homeClanId == clanId) return homeScore;
    if (awayClanId == clanId) return awayScore;
    return null;
  }

  int? srChangeFor(String clanId) {
    if (homeClanId == clanId) return homeSrChange;
    if (awayClanId == clanId) return awaySrChange;
    return null;
  }

  factory Fixture.fromJson(Map<String, dynamic> json) {
    final homeClan = _nestedMap(json['home_clan'] ?? json['clans']) ?? const {};
    final awayClan = _nestedMap(json['away_clan']);

    return Fixture(
      id: json['id'] as String,
      status: _fixtureStatusFromWire(json['status'] as String? ?? 'OPEN'),
      homeClanId: json['home_clan_id'] as String,
      awayClanId: json['away_clan_id'] as String?,
      venue: (json['venue'] as String? ?? '').trim(),
      day: json['day'] as String? ?? 'TUESDAY',
      timeSlot: json['time_slot'] as String? ?? FixtureTimeSlot.early.label,
      matchDate: _asDate(json['match_date']) ?? DateTime.now(),
      homeScore: _asNullableInt(json['home_score']),
      awayScore: _asNullableInt(json['away_score']),
      winnerClanId: json['winner_clan_id'] as String?,
      homeSrChange: _asNullableInt(json['home_sr_change']),
      awaySrChange: _asNullableInt(json['away_sr_change']),
      videoUrl: json['video_url'] as String?,
      createdBy: json['created_by'] as String? ?? '',
      homeClan: FixtureClan.fromJson(homeClan),
      awayClan: awayClan == null ? null : FixtureClan.fromJson(awayClan),
      cancelledAt: _asDate(json['cancelled_at']),
      cancellationReason: json['cancellation_reason'] as String?,
      createdAt: _asDate(json['created_at']),
      updatedAt: _asDate(json['updated_at']),
    );
  }
}

class MyClanMembership {
  const MyClanMembership({required this.clan, required this.role});

  final FixtureClan clan;
  final String role;

  bool get isOwner => role == 'owner';
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
