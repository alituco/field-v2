enum OpenQueueRole { goalkeeper, defender, midfielder, attacker }

extension OpenQueueRoleX on OpenQueueRole {
  String get code => switch (this) {
    OpenQueueRole.goalkeeper => 'GK',
    OpenQueueRole.defender => 'DEF',
    OpenQueueRole.midfielder => 'MID',
    OpenQueueRole.attacker => 'ATT',
  };

  String get label => switch (this) {
    OpenQueueRole.goalkeeper => 'Goalkeeper',
    OpenQueueRole.defender => 'Defender',
    OpenQueueRole.midfielder => 'Midfielder',
    OpenQueueRole.attacker => 'Attacker',
  };

  int get matchCapacity => switch (this) {
    OpenQueueRole.goalkeeper || OpenQueueRole.attacker => 2,
    OpenQueueRole.defender || OpenQueueRole.midfielder => 4,
  };

  static OpenQueueRole fromCode(String value) {
    return switch (value.toUpperCase()) {
      'GK' => OpenQueueRole.goalkeeper,
      'DEF' => OpenQueueRole.defender,
      'MID' => OpenQueueRole.midfielder,
      'ATT' => OpenQueueRole.attacker,
      _ => OpenQueueRole.midfielder,
    };
  }
}

class OpenQueueGame {
  const OpenQueueGame({
    required this.id,
    required this.status,
    required this.venue,
    required this.startsAt,
    required this.endsAt,
    required this.timezone,
    required this.priceFils,
    required this.ageLabel,
    required this.capacity,
    required this.confirmedCount,
    required this.spots,
  });

  final String id;
  final String status;
  final String venue;
  final DateTime startsAt;
  final DateTime endsAt;
  final String timezone;
  final int priceFils;
  final String ageLabel;
  final int capacity;
  final int confirmedCount;
  final Map<OpenQueueRole, int> spots;

  bool get isFull => status == 'FULL' || confirmedCount >= capacity;

  int spotsFor(OpenQueueRole role) => spots[role] ?? 0;

  bool canBook(OpenQueueRole role) => !isFull && spotsFor(role) > 0;

  DateTime get bahrainStartsAt =>
      startsAt.toUtc().add(const Duration(hours: 3));

  DateTime get bahrainEndsAt => endsAt.toUtc().add(const Duration(hours: 3));

  String get dateGroup {
    final value = bahrainStartsAt;
    final now = DateTime.now().toUtc().add(const Duration(hours: 3));
    final date = DateTime.utc(value.year, value.month, value.day);
    final today = DateTime.utc(now.year, now.month, now.day);
    if (date == today) return 'TODAY';
    if (date == today.add(const Duration(days: 1))) return 'TOMORROW';
    return '${_weekday(value.weekday)}, ${value.day} ${_month(value.month)}';
  }

  String get timeLabel => '${_clock(bahrainStartsAt)}–${_clock(bahrainEndsAt)}';

  String get startTimeLabel => _clock(bahrainStartsAt);

  String get priceLabel {
    final dinars = priceFils / 1000;
    return dinars == dinars.roundToDouble()
        ? '${dinars.toInt()} BHD'
        : '${dinars.toStringAsFixed(3)} BHD';
  }

  factory OpenQueueGame.fromJson(Map<String, dynamic> json) {
    return OpenQueueGame(
      id: json['id'] as String? ?? '',
      status: (json['status'] as String? ?? 'OPEN').toUpperCase(),
      venue: (json['venue'] as String? ?? '').trim(),
      startsAt: DateTime.parse(json['starts_at'] as String).toLocal(),
      endsAt: DateTime.parse(json['ends_at'] as String).toLocal(),
      timezone: json['timezone'] as String? ?? 'Asia/Bahrain',
      priceFils: _asInt(json['price_fils'], fallback: 3000),
      ageLabel: json['age_label'] as String? ?? 'All ages',
      capacity: _asInt(json['capacity'], fallback: 12),
      confirmedCount: _asInt(json['confirmed_count']),
      spots: {
        OpenQueueRole.goalkeeper: _asInt(json['goalkeeper_spots']),
        OpenQueueRole.defender: _asInt(json['defender_spots']),
        OpenQueueRole.midfielder: _asInt(json['midfielder_spots']),
        OpenQueueRole.attacker: _asInt(json['attacker_spots']),
      },
    );
  }

  factory OpenQueueGame.fromBookingJson(Map<String, dynamic> json) {
    return OpenQueueGame(
      id: json['id'] as String? ?? '',
      status: (json['status'] as String? ?? 'OPEN').toUpperCase(),
      venue: (json['venue'] as String? ?? '').trim(),
      startsAt: DateTime.parse(json['starts_at'] as String).toLocal(),
      endsAt: DateTime.parse(json['ends_at'] as String).toLocal(),
      timezone: json['timezone'] as String? ?? 'Asia/Bahrain',
      priceFils: _asInt(json['price_fils'], fallback: 3000),
      ageLabel: json['age_label'] as String? ?? 'All ages',
      capacity: _asInt(json['capacity'], fallback: 12),
      confirmedCount: 0,
      spots: const {},
    );
  }
}

class OpenQueueBooking {
  const OpenQueueBooking({
    required this.id,
    required this.gameId,
    required this.profileId,
    required this.role,
    required this.status,
    required this.amountPaidFils,
    required this.bookedAt,
    required this.game,
    this.team,
    this.cancelledAt,
    this.refundPercent,
    this.refundAmountFils,
  });

  final String id;
  final String gameId;
  final String profileId;
  final OpenQueueRole role;
  final String status;
  final String? team;
  final int amountPaidFils;
  final DateTime bookedAt;
  final DateTime? cancelledAt;
  final int? refundPercent;
  final int? refundAmountFils;
  final OpenQueueGame game;

  factory OpenQueueBooking.fromJson(Map<String, dynamic> json) {
    final rawGame = json['game'] ?? json['open_queue_games'];
    final gameJson = rawGame is List && rawGame.isNotEmpty
        ? Map<String, dynamic>.from(rawGame.first as Map)
        : Map<String, dynamic>.from(rawGame as Map);
    return OpenQueueBooking(
      id: json['id'] as String? ?? '',
      gameId: json['game_id'] as String? ?? '',
      profileId: json['profile_id'] as String? ?? '',
      role: OpenQueueRoleX.fromCode(json['role'] as String? ?? 'MID'),
      status: (json['status'] as String? ?? 'CONFIRMED').toUpperCase(),
      team: json['team'] as String?,
      amountPaidFils: _asInt(json['amount_paid_fils']),
      bookedAt: DateTime.parse(json['booked_at'] as String).toLocal(),
      cancelledAt: _asDate(json['cancelled_at']),
      refundPercent: _asNullableInt(json['refund_percent']),
      refundAmountFils: _asNullableInt(json['refund_amount_fils']),
      game: OpenQueueGame.fromBookingJson(gameJson),
    );
  }
}

class OpenQueueCancellationPreview {
  const OpenQueueCancellationPreview({
    required this.canCancel,
    required this.refundPercent,
    required this.refundAmountFils,
    required this.refundCutoffAt,
  });

  final bool canCancel;
  final int refundPercent;
  final int refundAmountFils;
  final DateTime refundCutoffAt;

  String get refundLabel {
    if (refundPercent == 0) return 'No refund';
    return '${(refundAmountFils / 1000).toStringAsFixed(3)} BHD refund';
  }

  factory OpenQueueCancellationPreview.fromJson(Map<String, dynamic> json) {
    return OpenQueueCancellationPreview(
      canCancel: json['can_cancel'] == true,
      refundPercent: _asInt(json['refund_percent']),
      refundAmountFils: _asInt(json['refund_amount_fils']),
      refundCutoffAt: DateTime.parse(
        json['refund_cutoff_at'] as String,
      ).toLocal(),
    );
  }
}

int _asInt(Object? value, {int fallback = 0}) {
  return _asNullableInt(value) ?? fallback;
}

int? _asNullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime? _asDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

String _clock(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${value.hour < 12 ? 'AM' : 'PM'}';
}

String _weekday(int value) {
  return const ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'][value - 1];
}

String _month(int value) {
  return const [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ][value - 1];
}
