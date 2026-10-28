class MatchReliabilityContext {
  const MatchReliabilityContext({
    required this.serverNow,
    required this.policyVersionId,
    required this.kickoffAt,
    required this.checkInDeadlineAt,
    required this.noShowCutoffAt,
    required this.canCheckIn,
    required this.canFinalizeAttendance,
    required this.attendanceFinalized,
  });

  final DateTime? serverNow;
  final String? policyVersionId;
  final DateTime? kickoffAt;
  final DateTime? checkInDeadlineAt;
  final DateTime? noShowCutoffAt;
  final bool canCheckIn;
  final bool canFinalizeAttendance;
  final bool attendanceFinalized;

  factory MatchReliabilityContext.fromJson(Map<String, dynamic> json) {
    return MatchReliabilityContext(
      serverNow: _date(json['server_now']),
      policyVersionId: _string(json['policy_version_id']),
      kickoffAt: _date(json['kickoff_at']),
      checkInDeadlineAt: _date(
        json['check_in_deadline_at'] ?? json['checkin_deadline_at'],
      ),
      noShowCutoffAt: _date(json['no_show_cutoff_at']),
      canCheckIn: _bool(json['can_check_in']),
      canFinalizeAttendance: _bool(
        json['can_finalize_attendance'] ?? json['can_finalize'],
      ),
      attendanceFinalized: _bool(
        json['attendance_finalized'] ?? json['is_finalized'],
      ),
    );
  }
}

class ReliabilityStatus {
  const ReliabilityStatus({
    required this.serverNow,
    required this.policyVersionId,
    required this.activeStrikes,
    required this.depositRequired,
    required this.depositBps,
    required this.bookingRestrictedUntil,
    required this.participationSuspendedUntil,
    required this.indefiniteSuspension,
    required this.message,
    required this.incidents,
    required this.allowedAppealCategories,
    this.walletBalanceFils = 0,
    this.walletCurrency = 'BHD',
    this.walletBalances = const [],
    this.policyDisplay,
    this.timezone = 'UTC',
  });

  final DateTime? serverNow;
  final String? policyVersionId;
  final int activeStrikes;
  final bool depositRequired;
  final int depositBps;
  final DateTime? bookingRestrictedUntil;
  final DateTime? participationSuspendedUntil;
  final bool indefiniteSuspension;
  final String? message;
  final List<ReliabilityIncident> incidents;
  final List<ReliabilityAppealCategory> allowedAppealCategories;
  final int walletBalanceFils;
  final String walletCurrency;
  final List<FieldWalletBalance> walletBalances;
  final ReliabilityPolicyDisplay? policyDisplay;
  final String timezone;

  String get walletBalanceLabel => FieldWalletBalance(
    currency: walletCurrency,
    balanceFils: walletBalanceFils,
  ).label;

  List<FieldWalletBalance> get visibleWalletBalances {
    final balances = <String, FieldWalletBalance>{
      walletCurrency: FieldWalletBalance(
        currency: walletCurrency,
        balanceFils: walletBalanceFils,
      ),
      for (final balance in walletBalances) balance.currency: balance,
    };
    return balances.values.where((balance) => balance.balanceFils > 0).toList();
  }

  bool get isGoodStanding =>
      activeStrikes == 0 &&
      !depositRequired &&
      bookingRestrictedUntil == null &&
      participationSuspendedUntil == null &&
      !indefiniteSuspension;

  String get headline {
    if (indefiniteSuspension) return 'Indefinite suspension';
    if (participationSuspendedUntil != null) return 'Participation suspended';
    if (bookingRestrictedUntil != null) return 'New bookings restricted';
    if (depositRequired) return 'Reliability deposit required';
    if (activeStrikes == 1) return '1 active strike';
    if (activeStrikes > 1) return '$activeStrikes active strikes';
    return 'Good standing';
  }

  String get supportingText {
    final supplied = message?.trim();
    if (supplied != null && supplied.isNotEmpty) return supplied;
    if (indefiniteSuspension) {
      return 'Your attendance history is pending appeal and manual review.';
    }
    if (participationSuspendedUntil case final until?) {
      return 'You cannot participate until ${_shortDate(until)}.';
    }
    if (bookingRestrictedUntil case final until?) {
      return 'Existing bookings stay active. New bookings reopen ${_shortDate(until)}.';
    }
    if (depositRequired) {
      final percent = depositBps / 100;
      return '${_percent(percent)} refundable deposit on future solo bookings. Returned as Field credit after the referee records an on-time arrival.';
    }
    if (activeStrikes == 1) {
      return 'Arrive by the deadline shown on each booking. The referee records attendance. This strike expires separately.';
    }
    return 'No active attendance strikes.';
  }

  factory ReliabilityStatus.fromJson(Map<String, dynamic> json) {
    final sanction = _map(json['sanction'] ?? json['active_sanction']);
    final wallet = _map(json['wallet']);
    final rawIncidents =
        json['incidents'] ??
        json['attendance_history'] ??
        json['recent_incidents'] ??
        const [];
    final allowedAppealCategories = _appealCategories(
      json['allowed_appeal_categories'],
    );
    return ReliabilityStatus(
      serverNow: _date(json['server_now']),
      policyVersionId: _string(json['policy_version_id']),
      activeStrikes: _int(
        json['active_strikes'] ?? json['active_strike_count'],
      ),
      depositRequired: _bool(
        json['deposit_required'] ?? json['reliability_deposit_required'],
      ),
      depositBps: _int(json['deposit_bps'] ?? json['reliability_deposit_bps']),
      bookingRestrictedUntil: _date(
        json['booking_restricted_until'] ??
            sanction?['booking_restricted_until'],
      ),
      participationSuspendedUntil: _date(
        json['participation_suspended_until'] ??
            json['suspended_until'] ??
            sanction?['ends_at'],
      ),
      indefiniteSuspension: _bool(
        json['indefinite_suspension'] ??
            json['is_indefinitely_suspended'] ??
            sanction?['indefinite'],
      ),
      message: _string(json['message'] ?? json['status_message']),
      walletBalanceFils: _int(
        wallet?['balance_fils'] ?? json['wallet_balance_fils'],
      ),
      walletCurrency:
          _string(wallet?['currency'] ?? json['wallet_currency']) ?? 'BHD',
      walletBalances: [
        if (wallet?['balances'] case final List balances)
          for (final value in balances)
            if (_map(value) case final row?)
              if (_string(row['currency']) case final currency?)
                FieldWalletBalance(
                  currency: currency.toUpperCase(),
                  balanceFils: _int(row['balance_fils']),
                ),
      ],
      allowedAppealCategories: allowedAppealCategories,
      policyDisplay: ReliabilityPolicyDisplay.fromJson(json['policy_display']),
      timezone: _string(json['timezone']) ?? 'UTC',
      incidents: [
        if (rawIncidents is List)
          for (final raw in rawIncidents)
            if (_map(raw) case final row?)
              ReliabilityIncident.fromJson(
                row,
                fallbackAppealCategories: allowedAppealCategories,
                fallbackTimezone: _string(json['timezone']) ?? 'UTC',
              ),
      ],
    );
  }
}

/// Read-only presentation of the currently published solo attendance rules.
/// Existing bookings retain their own policy snapshots on the server.
class ReliabilityPolicyDisplay {
  const ReliabilityPolicyDisplay({
    required this.strikeLifetimeDays,
    required this.lateStrikes,
    required this.noShowStrikes,
    required this.cancellationRules,
    required this.sanctions,
    required this.depositThreshold,
    required this.depositBps,
  });

  final int strikeLifetimeDays;
  final int lateStrikes;
  final int noShowStrikes;
  final List<ReliabilityCancellationRule> cancellationRules;
  final List<ReliabilitySanctionRule> sanctions;
  final int depositThreshold;
  final int depositBps;

  static ReliabilityPolicyDisplay? fromJson(Object? value) {
    final row = _map(value);
    if (row == null || row['sanctions'] is! List) return null;
    final cancellations = _map(row['cancellations']);
    final deposit = _map(row['deposit']);
    return ReliabilityPolicyDisplay(
      strikeLifetimeDays: _int(row['strike_lifetime_days']),
      lateStrikes: _int(row['late_strikes']),
      noShowStrikes: _int(row['no_show_strikes']),
      cancellationRules: [
        for (final key in ['late', 'veryLate', 'afterKickoff'])
          if (_map(cancellations?[key]) case final rule?)
            if (_int(rule['strikes']) > 0)
              ReliabilityCancellationRule(
                code: key,
                strikes: _int(rule['strikes']),
                minimumHoursBeforeKickoff:
                    rule['minimumHoursBeforeKickoff'] == null
                    ? null
                    : _int(rule['minimumHoursBeforeKickoff']),
                maximumHoursBeforeKickoff: switch (key) {
                  'late' => _int(
                    _map(cancellations?['early'])?['minimumHoursBeforeKickoff'],
                  ),
                  'veryLate' => _int(
                    _map(cancellations?['late'])?['minimumHoursBeforeKickoff'],
                  ),
                  _ => null,
                },
              ),
      ],
      sanctions: [
        for (final value in row['sanctions'] as List)
          if (_map(value) case final rule?)
            ReliabilitySanctionRule(
              threshold: _int(rule['threshold']),
              kind: _string(rule['kind']) ?? '',
              durationDays: rule['durationDays'] == null
                  ? null
                  : _int(rule['durationDays']),
              releaseFutureBookings: _bool(rule['releaseFutureBookings']),
            ),
      ]..sort((a, b) => a.threshold.compareTo(b.threshold)),
      depositThreshold: _int(deposit?['activeStrikeThreshold']),
      depositBps: _int(deposit?['depositBps']),
    );
  }
}

class ReliabilityCancellationRule {
  const ReliabilityCancellationRule({
    required this.code,
    required this.strikes,
    required this.minimumHoursBeforeKickoff,
    required this.maximumHoursBeforeKickoff,
  });
  final String code;
  final int strikes;
  final int? minimumHoursBeforeKickoff;
  final int? maximumHoursBeforeKickoff;
}

class ReliabilitySanctionRule {
  const ReliabilitySanctionRule({
    required this.threshold,
    required this.kind,
    required this.durationDays,
    required this.releaseFutureBookings,
  });
  final int threshold;
  final String kind;
  final int? durationDays;
  final bool releaseFutureBookings;
}

class FieldWalletBalance {
  const FieldWalletBalance({required this.currency, required this.balanceFils});

  final String currency;
  final int balanceFils;

  // Refund policy calculations retain their exact thousandths in the ledger.
  // Show any fractional cent rather than rounding away money that is recorded.
  String get label => currency.toUpperCase() == 'USD'
      ? '\$${(balanceFils / 1000).toStringAsFixed(balanceFils % 10 == 0 ? 2 : 3)}'
      : '${(balanceFils / 1000).toStringAsFixed(3)} $currency';
}

class ReliabilityIncident {
  const ReliabilityIncident({
    required this.attendanceRecordId,
    required this.outcome,
    required this.strikeDelta,
    required this.occurredAt,
    required this.checkedInAt,
    required this.checkInDeadlineAt,
    required this.appealDeadlineAt,
    required this.strikeExpiresAt,
    required this.appealStatus,
    required this.canAppeal,
    required this.matchLabel,
    required this.allowedAppealCategories,
    this.timezone = 'UTC',
    this.strikeActive,
    this.originalOutcome,
    this.originalStrikeDelta,
    this.appealSubmittedAt,
    this.appealReviewedAt,
    this.appealResolutionNote,
  });

  final String attendanceRecordId;
  final String outcome;
  final int strikeDelta;
  final DateTime? occurredAt;
  final DateTime? checkedInAt;
  final DateTime? checkInDeadlineAt;
  final DateTime? appealDeadlineAt;
  final DateTime? strikeExpiresAt;
  final String? appealStatus;
  final bool canAppeal;
  final String? matchLabel;
  final List<ReliabilityAppealCategory> allowedAppealCategories;
  final String timezone;
  final bool? strikeActive;
  final String? originalOutcome;
  final int? originalStrikeDelta;
  final DateTime? appealSubmittedAt;
  final DateTime? appealReviewedAt;
  final String? appealResolutionNote;

  bool get appealPending =>
      ['OPEN', 'REVIEWING'].contains(appealStatus?.toUpperCase());
  bool get excused =>
      outcome.toUpperCase() == 'EXCUSED' ||
      appealStatus?.toUpperCase() == 'OVERTURNED';

  bool isActiveAt(DateTime now) =>
      !excused &&
      (strikeActive ??
          (strikeDelta > 0 &&
              (strikeExpiresAt == null || strikeExpiresAt!.isAfter(now))));

  String get outcomeLabel => switch (outcome.toUpperCase()) {
    'ON_TIME' => 'On time',
    'LATE' => 'Late',
    'CANCELLED_EARLY' => 'Early cancellation',
    'CANCELLED_LATE' => 'Late cancellation',
    'CANCELLED_VERY_LATE' => 'Very late cancellation',
    'NO_SHOW' => 'No-show',
    'EXCUSED' => 'Excused',
    'FIELD_CANCELLED' => 'Field cancellation',
    _ => outcome.toLowerCase().split('_').map(_capitalize).join(' '),
  };

  factory ReliabilityIncident.fromJson(
    Map<String, dynamic> json, {
    List<ReliabilityAppealCategory> fallbackAppealCategories = const [],
    String fallbackTimezone = 'UTC',
  }) {
    final allowedAppealCategories =
        json.containsKey('allowed_appeal_categories')
        ? _appealCategories(json['allowed_appeal_categories'])
        : fallbackAppealCategories;
    return ReliabilityIncident(
      attendanceRecordId:
          _string(
            json['attendance_record_id'] ?? json['record_id'] ?? json['id'],
          ) ??
          '',
      outcome:
          _string(
            json['attendance_outcome'] ??
                json['outcome_code'] ??
                json['outcome'],
          ) ??
          'PENDING',
      strikeDelta: _int(json['strike_delta']),
      occurredAt: _date(
        json['occurred_at'] ?? json['finalized_at'] ?? json['created_at'],
      ),
      checkedInAt: _date(json['checked_in_at']),
      checkInDeadlineAt: _date(json['check_in_deadline_at']),
      appealDeadlineAt: _date(json['appeal_deadline_at'] ?? json['appeal_by']),
      strikeExpiresAt: _date(json['strike_expires_at'] ?? json['expires_at']),
      appealStatus: _string(json['appeal_status'] ?? json['review_status']),
      canAppeal:
          _bool(json['can_appeal']) && allowedAppealCategories.isNotEmpty,
      matchLabel: _string(json['match_label'] ?? json['fixture_label']),
      allowedAppealCategories: allowedAppealCategories,
      timezone: _string(json['timezone']) ?? fallbackTimezone,
      strikeActive: json['strike_active'] is bool
          ? json['strike_active'] as bool
          : null,
      originalOutcome: _string(json['original_outcome']),
      originalStrikeDelta: json['original_strike_delta'] == null
          ? null
          : _int(json['original_strike_delta']),
      appealSubmittedAt: _date(json['appeal_submitted_at']),
      appealReviewedAt: _date(json['appeal_reviewed_at']),
      appealResolutionNote: _string(json['appeal_resolution_note']),
    );
  }
}

enum ReliabilityAppealCategory {
  incorrectVenueInformation,
  venueAccessBlocked,
  medicalEmergency,
  seriousEmergency,
  wrongPlayerCheckedIn,
  appOrOperatorError,
  otherDocumentedException,
}

extension ReliabilityAppealCategoryX on ReliabilityAppealCategory {
  String get code => switch (this) {
    ReliabilityAppealCategory.incorrectVenueInformation =>
      'FIELD_OR_VENUE_ERROR',
    ReliabilityAppealCategory.venueAccessBlocked => 'VENUE_ACCESS_BLOCKED',
    ReliabilityAppealCategory.medicalEmergency => 'VERIFIED_MEDICAL_EMERGENCY',
    ReliabilityAppealCategory.seriousEmergency =>
      'SERIOUS_ACCIDENT_OR_EMERGENCY',
    ReliabilityAppealCategory.wrongPlayerCheckedIn => 'WRONG_PLAYER_CHECKED_IN',
    ReliabilityAppealCategory.appOrOperatorError => 'APP_OR_OPERATOR_ERROR',
    ReliabilityAppealCategory.otherDocumentedException => 'OTHER',
  };

  String get label => switch (this) {
    ReliabilityAppealCategory.incorrectVenueInformation =>
      'Incorrect venue information',
    ReliabilityAppealCategory.venueAccessBlocked => 'Venue access was blocked',
    ReliabilityAppealCategory.medicalEmergency => 'Medical emergency',
    ReliabilityAppealCategory.seriousEmergency =>
      'Serious accident or emergency',
    ReliabilityAppealCategory.wrongPlayerCheckedIn =>
      'Wrong player was checked in',
    ReliabilityAppealCategory.appOrOperatorError => 'App or operator error',
    ReliabilityAppealCategory.otherDocumentedException =>
      'Other documented exception',
  };
}

List<ReliabilityAppealCategory> _appealCategories(Object? value) {
  if (value is! List) return const [];
  final byCode = {
    for (final category in ReliabilityAppealCategory.values)
      category.code: category,
  };
  return [
    for (final raw in value)
      if (byCode[_string(raw)] case final category?) category,
  ];
}

Map<String, dynamic>? _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty) return _map(value.first);
  return null;
}

String? _string(Object? value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

int _int(Object? value) {
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool _bool(Object? value) {
  if (value is bool) return value;
  return value?.toString().toLowerCase() == 'true';
}

DateTime? _date(Object? value) {
  final raw = _string(value);
  return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
}

String _capitalize(String value) {
  if (value.isEmpty) return value;
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

String _shortDate(DateTime value) {
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
  final bahrain = value.toUtc().add(const Duration(hours: 3));
  return '${months[bahrain.month - 1]} ${bahrain.day}';
}

String _percent(double value) {
  return value == value.roundToDouble()
      ? '${value.toInt()}%'
      : '${value.toStringAsFixed(2)}%';
}
