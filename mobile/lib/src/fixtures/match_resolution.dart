enum MatchResolutionKind {
  clan('CLAN'),
  solo('SOLO');

  const MatchResolutionKind(this.code);

  final String code;
}

abstract interface class MatchResolutionRepository {
  Future<MatchResolutionCase?> getMatchResolutionCase({
    required MatchResolutionKind matchKind,
    required String matchId,
  });

  Future<void> submitMatchResolutionDispute({
    required String caseId,
    required String reason,
  });
}

class MatchResolutionCase {
  const MatchResolutionCase({
    required this.id,
    required this.matchKind,
    required this.matchId,
    required this.state,
    required this.reasonCode,
    required this.detectedAt,
    required this.highPriorityAt,
    required this.currentRevision,
    required this.resolution,
    required this.refunds,
    required this.myDisputes,
    required this.disputeDueAt,
    required this.canDispute,
    required this.refundsContinueDuringDispute,
  });

  factory MatchResolutionCase.fromJson(Map<String, dynamic> json) {
    final rawResolution = json['resolution'];
    return MatchResolutionCase(
      id: json['id'] as String? ?? '',
      matchKind: _kindFrom(json['match_kind']),
      matchId: json['match_id'] as String? ?? '',
      state: (json['state'] as String? ?? 'OPEN').trim().toUpperCase(),
      reasonCode: (json['reason_code'] as String?)?.trim().toUpperCase(),
      detectedAt: _dateTime(json['detected_at']),
      highPriorityAt: _dateTime(json['high_priority_at']),
      currentRevision: _intValue(json['current_revision']),
      resolution: rawResolution is Map
          ? MatchResolution.fromJson(Map<String, dynamic>.from(rawResolution))
          : null,
      refunds: _mapList(json['refunds'], MatchResolutionRefund.fromJson),
      myDisputes: _mapList(
        json['my_disputes'],
        MatchResolutionDispute.fromJson,
      ),
      disputeDueAt: _dateTime(json['dispute_due_at']),
      canDispute: json['can_dispute'] == true,
      refundsContinueDuringDispute:
          json['refunds_continue_during_dispute'] != false,
    );
  }

  final String id;
  final MatchResolutionKind matchKind;
  final String matchId;
  final String state;
  final String? reasonCode;
  final DateTime? detectedAt;
  final DateTime? highPriorityAt;
  final int currentRevision;
  final MatchResolution? resolution;
  final List<MatchResolutionRefund> refunds;
  final List<MatchResolutionDispute> myDisputes;
  final DateTime? disputeDueAt;
  final bool canDispute;
  final bool refundsContinueDuringDispute;

  MatchResolutionDispute? get latestDispute =>
      myDisputes.isEmpty ? null : myDisputes.first;

  bool get isResolved => resolution != null;

  String get outcomeLabel =>
      resolution?.outcomeLabel ??
      switch (state) {
        'UNDER_REVIEW' => 'Match under review',
        _ => 'Match review pending',
      };

  String get reviewReasonLabel => switch (reasonCode) {
    'RESULT_MISSING' => 'The final result was not recorded.',
    'REFEREE_REPORT_MISSING' => 'The referee report was not completed.',
    'REFUND_FAILED' => 'An approved refund needs attention from Field.',
    'DISPUTED' => 'A participant asked Field to review this decision.',
    _ => 'The match record does not contain enough verified data yet.',
  };
}

class MatchResolution {
  const MatchResolution({
    required this.id,
    required this.revision,
    required this.resolutionType,
    required this.reason,
    required this.consequences,
    required this.createdAt,
  });

  factory MatchResolution.fromJson(Map<String, dynamic> json) {
    final rawConsequences = json['consequences'];
    return MatchResolution(
      id: json['id'] as String? ?? '',
      revision: _intValue(json['revision']),
      resolutionType: (json['resolution_type'] as String? ?? '')
          .trim()
          .toUpperCase(),
      reason: (json['reason'] as String? ?? '').trim(),
      consequences: rawConsequences is Map
          ? Map<String, dynamic>.unmodifiable(
              Map<String, dynamic>.from(rawConsequences),
            )
          : const {},
      createdAt: _dateTime(json['created_at']),
    );
  }

  final String id;
  final int revision;
  final String resolutionType;
  final String reason;
  final Map<String, dynamic> consequences;
  final DateTime? createdAt;

  int? get homeScore => _nullableInt(consequences['home_score']);
  int? get awayScore => _nullableInt(consequences['away_score']);

  String get outcomeLabel => switch (resolutionType) {
    'RECORDED_RESULT' => 'Official result recorded',
    'HOME_NO_SHOW' => 'Home side did not show',
    'AWAY_NO_SHOW' => 'Away side did not show',
    'BOTH_NO_SHOW' => 'Both sides did not show',
    'FIELD_OR_VENUE_CANCELLATION' => 'Cancelled by Field or the venue',
    'MUTUAL_CANCELLATION' => 'Cancelled by agreement',
    'BOTH_AT_FAULT' => 'Both sides held responsible',
    'ADMINISTRATIVE_VOID' => 'Match voided by Field',
    _ => _readableCode(resolutionType, fallback: 'Match reviewed'),
  };

  String? get scoreLabel {
    final home = homeScore;
    final away = awayScore;
    if (home == null || away == null) return null;
    return '$home–$away';
  }
}

class MatchResolutionRefund {
  const MatchResolutionRefund({
    required this.id,
    required this.side,
    required this.amountFils,
    required this.targetAmountFils,
    required this.refundBps,
    required this.destination,
    required this.status,
    required this.failureReason,
    required this.createdAt,
  });

  factory MatchResolutionRefund.fromJson(Map<String, dynamic> json) {
    return MatchResolutionRefund(
      id: json['id'] as String? ?? '',
      side: (json['side'] as String? ?? '').trim().toUpperCase(),
      amountFils: _intValue(json['amount_fils']),
      targetAmountFils: _intValue(json['target_amount_fils']),
      refundBps: _intValue(json['refund_bps']),
      destination: (json['destination'] as String? ?? 'FIELD_WALLET')
          .trim()
          .toUpperCase(),
      status: (json['status'] as String? ?? 'PENDING').trim().toUpperCase(),
      failureReason: (json['failure_reason'] as String?)?.trim(),
      createdAt: _dateTime(json['created_at']),
    );
  }

  final String id;
  final String side;
  final int amountFils;
  final int targetAmountFils;
  final int refundBps;
  final String destination;
  final String status;
  final String? failureReason;
  final DateTime? createdAt;

  int get displayAmountFils =>
      targetAmountFils > 0 ? targetAmountFils : amountFils;

  String get amountLabel {
    final dinars = displayAmountFils / 1000;
    return '${dinars.toStringAsFixed(3)} BHD';
  }

  String get destinationLabel => switch (destination) {
    'FIELD_WALLET' => 'Field Wallet',
    _ => _readableCode(destination, fallback: 'Original payment method'),
  };

  String get statusLabel => switch (status) {
    'COMPLETED' => 'Refund complete',
    'FAILED' => 'Refund needs attention',
    'NOT_DUE' => 'No refund due',
    'PROCESSING' => 'Refund processing',
    'PENDING' => 'Refund pending',
    _ => _readableCode(status, fallback: 'Refund update'),
  };
}

class MatchResolutionDispute {
  const MatchResolutionDispute({
    required this.id,
    required this.revisionId,
    required this.reason,
    required this.status,
    required this.submittedAt,
    required this.resolvedAt,
    required this.resolutionNote,
  });

  factory MatchResolutionDispute.fromJson(Map<String, dynamic> json) {
    return MatchResolutionDispute(
      id: json['id'] as String? ?? '',
      revisionId: json['revision_id'] as String? ?? '',
      reason: (json['reason'] as String? ?? '').trim(),
      status: (json['status'] as String? ?? 'OPEN').trim().toUpperCase(),
      submittedAt: _dateTime(json['submitted_at']),
      resolvedAt: _dateTime(json['resolved_at']),
      resolutionNote: (json['resolution_note'] as String?)?.trim(),
    );
  }

  final String id;
  final String revisionId;
  final String reason;
  final String status;
  final DateTime? submittedAt;
  final DateTime? resolvedAt;
  final String? resolutionNote;

  bool get isOpen => status == 'OPEN';

  String get statusLabel => switch (status) {
    'OPEN' => 'Under review',
    'UPHELD' => 'Decision upheld',
    'OVERTURNED' => 'Decision changed',
    'DISMISSED' => 'Dispute closed',
    _ => _readableCode(status, fallback: 'Dispute updated'),
  };
}

List<T> _mapList<T>(Object? value, T Function(Map<String, dynamic>) parser) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map) parser(Map<String, dynamic>.from(item)),
  ];
}

MatchResolutionKind _kindFrom(Object? value) {
  return switch ((value as String? ?? '').trim().toUpperCase()) {
    'SOLO' => MatchResolutionKind.solo,
    _ => MatchResolutionKind.clan,
  };
}

DateTime? _dateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

int _intValue(Object? value) => _nullableInt(value) ?? 0;

int? _nullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String _readableCode(String value, {required String fallback}) {
  final words = value
      .trim()
      .split('_')
      .where((word) => word.isNotEmpty)
      .map(
        (word) =>
            '${word.substring(0, 1).toUpperCase()}${word.substring(1).toLowerCase()}',
      )
      .toList();
  return words.isEmpty ? fallback : words.join(' ');
}
