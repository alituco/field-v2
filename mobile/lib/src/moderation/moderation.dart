enum ModerationSubjectType {
  player('PLAYER', 'player'),
  clan('CLAN', 'clan'),
  fixture('MATCH', 'match'),
  openQueueGame('MATCH', 'solo match');

  const ModerationSubjectType(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

enum ModerationState {
  active,
  warning,
  suspended,
  banned;

  static ModerationState fromWireValue(Object? value) {
    return switch (value?.toString().trim().toUpperCase()) {
      'ACTIVE' => active,
      'WARNING' => warning,
      'SUSPENDED' => suspended,
      'BANNED' => banned,
      _ => throw StateError('The account status could not be confirmed.'),
    };
  }
}

enum ModerationScope {
  none,
  play,
  account;

  static ModerationScope fromWireValue(
    Object? value, {
    required ModerationState state,
  }) {
    return switch (value?.toString().trim().toUpperCase()) {
      null || '' =>
        state == ModerationState.suspended
            ? account
            : state == ModerationState.banned
            ? account
            : none,
      'NONE' => none,
      'PLAY' => play,
      'ACCOUNT' => account,
      _ =>
        state == ModerationState.suspended || state == ModerationState.banned
            ? account
            : none,
    };
  }
}

class ModerationStatus {
  const ModerationStatus({
    required this.state,
    required this.scope,
    required this.message,
    required this.endsAt,
    required this.warningCount,
  });

  const ModerationStatus.active()
    : state = ModerationState.active,
      scope = ModerationScope.none,
      message = '',
      endsAt = null,
      warningCount = 0;

  final ModerationState state;
  final ModerationScope scope;
  final String message;
  final DateTime? endsAt;
  final int warningCount;

  bool get blocksAccount {
    return state == ModerationState.banned ||
        (state == ModerationState.suspended &&
            scope == ModerationScope.account);
  }

  bool get isPlayRestricted {
    return state == ModerationState.suspended && scope == ModerationScope.play;
  }

  factory ModerationStatus.fromRpcResponse(Object? response) {
    final value = switch (response) {
      final Map map => map,
      final List list when list.isNotEmpty && list.first is Map =>
        list.first as Map,
      _ => null,
    };
    if (value == null) {
      throw StateError('The account status could not be confirmed.');
    }

    final state = ModerationState.fromWireValue(value['state']);
    final scope = ModerationScope.fromWireValue(value['scope'], state: state);
    final message = value['message']?.toString().trim() ?? '';
    final rawEnd = value['ends_at']?.toString().trim();
    final warningCount = switch (value['warning_count']) {
      final int count => count,
      final num count => count.toInt(),
      final Object count => int.tryParse(count.toString()) ?? 0,
      null => 0,
    };

    return ModerationStatus(
      state: state,
      scope: scope,
      message: message,
      endsAt: rawEnd == null || rawEnd.isEmpty
          ? null
          : DateTime.tryParse(rawEnd)?.toLocal(),
      warningCount: warningCount < 0 ? 0 : warningCount,
    );
  }
}

enum ModerationReportCategory {
  harassment(
    'HARASSMENT',
    'Harassment',
    'Bullying, repeated abuse, or unwanted behavior',
  ),
  threatsOrViolence(
    'THREATS_OR_VIOLENCE',
    'Threats or violence',
    'Threats, fighting, or violent conduct',
  ),
  discrimination(
    'DISCRIMINATION',
    'Discrimination',
    'Hateful or discriminatory behavior',
  ),
  dangerousPlay(
    'DANGEROUS_PLAY',
    'Dangerous play',
    'Deliberately unsafe or reckless play',
  ),
  cheating('CHEATING', 'Cheating', 'Dishonest or unfair match behavior'),
  noShowOrMatchManipulation(
    'NO_SHOW_OR_MATCH_MANIPULATION',
    'No-show or manipulation',
    'No-showing or trying to manipulate a match',
  ),
  inappropriateContent(
    'INAPPROPRIATE_CONTENT',
    'Inappropriate content',
    'An offensive name, image, bio, or clan identity',
  ),
  safetyOrVenue(
    'SAFETY_OR_VENUE',
    'Safety or venue',
    'A safety, equipment, or venue concern',
  ),
  scoreOrResult(
    'SCORE_OR_RESULT',
    'Score or result',
    'An incorrect score or disputed result',
  ),
  other('OTHER', 'Something else', 'A different issue we should review');

  const ModerationReportCategory(this.wireValue, this.label, this.description);

  final String wireValue;
  final String label;
  final String description;

  static List<ModerationReportCategory> forSubject(
    ModerationSubjectType subjectType,
  ) {
    return switch (subjectType) {
      ModerationSubjectType.player || ModerationSubjectType.clan => const [
        harassment,
        threatsOrViolence,
        discrimination,
        dangerousPlay,
        cheating,
        noShowOrMatchManipulation,
        inappropriateContent,
        other,
      ],
      ModerationSubjectType.fixture ||
      ModerationSubjectType.openQueueGame => values,
    };
  }
}

class ModerationReportDraft {
  const ModerationReportDraft({
    required this.subjectType,
    required this.subjectId,
    required this.category,
    required this.details,
    this.fixtureId,
    this.openQueueGameId,
  });

  final ModerationSubjectType subjectType;
  final String subjectId;
  final ModerationReportCategory category;
  final String details;
  final String? fixtureId;
  final String? openQueueGameId;

  Map<String, dynamic> toRpcParams() {
    return {
      'subject_type_to_use': subjectType.wireValue,
      'subject_id_to_use': subjectId.trim(),
      'category_to_use': category.wireValue,
      'details_to_use': details.trim(),
      'fixture_id_to_use': _trimmedOrNull(fixtureId),
      'open_queue_game_id_to_use': _trimmedOrNull(openQueueGameId),
    };
  }
}

class ModerationReportReceipt {
  const ModerationReportReceipt({required this.id});

  final String id;

  String get shortReference {
    final normalized = id.replaceAll('-', '').toUpperCase();
    if (normalized.length <= 8) return normalized;
    return normalized.substring(0, 8);
  }

  factory ModerationReportReceipt.fromRpcResponse(Object? response) {
    final value = switch (response) {
      final String id => id,
      final Map map => map['report_id'] ?? map['id'],
      final List list when list.isNotEmpty && list.first is Map =>
        (list.first as Map)['report_id'] ?? (list.first as Map)['id'],
      _ => null,
    };
    final id = value?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw StateError('The report could not be confirmed.');
    }
    return ModerationReportReceipt(id: id);
  }
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
