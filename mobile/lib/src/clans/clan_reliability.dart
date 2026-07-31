class ClanReliabilitySummary {
  const ClanReliabilitySummary({
    required this.clanId,
    required this.activeStrikes,
    required this.isMember,
    required this.consequenceSummary,
    required this.incidents,
  });

  final String clanId;
  final int activeStrikes;
  final bool isMember;
  final ClanReliabilityConsequenceSummary consequenceSummary;
  final List<ClanReliabilityIncident> incidents;

  factory ClanReliabilitySummary.fromJson(Map<String, dynamic> json) {
    final rawIncidents = json['incidents'];
    return ClanReliabilitySummary(
      clanId: _string(json['clan_id']),
      activeStrikes: _integer(json['active_strikes']),
      isMember: json['is_member'] == true,
      consequenceSummary: ClanReliabilityConsequenceSummary.fromJson(
        _map(json['consequence_summary']),
      ),
      incidents: rawIncidents is List
          ? [
              for (final rawIncident in rawIncidents)
                if (rawIncident is Map)
                  ClanReliabilityIncident.fromJson(
                    Map<String, dynamic>.from(rawIncident),
                  ),
            ]
          : const [],
    );
  }
}

class ClanReliabilityConsequenceSummary {
  const ClanReliabilityConsequenceSummary({
    required this.depositRequired,
    required this.activeSanctionCount,
  });

  final bool depositRequired;
  final int activeSanctionCount;

  factory ClanReliabilityConsequenceSummary.fromJson(
    Map<String, dynamic> json,
  ) {
    return ClanReliabilityConsequenceSummary(
      depositRequired: json['deposit_required'] == true,
      activeSanctionCount: _activeSanctionCount(json['active_sanctions']),
    );
  }
}

class ClanReliabilityIncident {
  const ClanReliabilityIncident({
    required this.id,
    required this.outcome,
    required this.strikeDelta,
    required this.isActive,
    this.occurredAt,
    this.expiresAt,
    this.reason,
    this.fixtureId,
    this.fixtureLabel,
    this.issuerLabel,
  });

  final String id;
  final String outcome;
  final int strikeDelta;
  final DateTime? occurredAt;
  final DateTime? expiresAt;
  final String? reason;
  final String? fixtureId;
  final String? fixtureLabel;
  final String? issuerLabel;
  final bool isActive;

  String get outcomeLabel {
    return switch (outcome.toUpperCase()) {
      'NO_SHOW' || 'CLAN_NO_SHOW' || 'ENTIRE_CLAN_NO_SHOW' => 'No-show',
      'SHORT_ROSTER' ||
      'PARTIAL_ATTENDANCE' ||
      'PARTIAL_LATE' => 'Short roster',
      'FORFEIT' || 'CLAN_FORFEIT' => 'Forfeit',
      'CANCELLED_EARLY' => 'Early cancellation',
      'CANCELLED_LATE' => 'Late cancellation',
      'CANCELLED_VERY_LATE' => 'Very late cancellation',
      'FIELD_CANCELLED' => 'Field cancellation',
      'ADMIN_REPORTED' => 'Admin decision',
      _ =>
        outcome
            .toLowerCase()
            .split('_')
            .where((part) => part.isNotEmpty)
            .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
            .join(' '),
    };
  }

  factory ClanReliabilityIncident.fromJson(Map<String, dynamic> json) {
    return ClanReliabilityIncident(
      id: _string(json['id']),
      outcome: _string(json['outcome'], fallback: 'RELIABILITY_EVENT'),
      strikeDelta: _integer(json['strike_delta']),
      occurredAt: _date(json['occurred_at']),
      expiresAt: _date(json['expires_at']),
      reason: _nullableString(json['reason']),
      fixtureId: _nullableString(json['fixture_id']),
      fixtureLabel: _nullableString(json['fixture_label']),
      issuerLabel: _nullableString(json['issuer_label']),
      isActive: json['is_active'] == true,
    );
  }
}

int _activeSanctionCount(Object? value) {
  if (value is List) return value.length;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  if (value is Map) {
    return _integer(value['count'] ?? value['active_count']);
  }
  return 0;
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}

String _string(Object? value, {String fallback = ''}) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? fallback : normalized;
}

String? _nullableString(Object? value) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

int _integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}
