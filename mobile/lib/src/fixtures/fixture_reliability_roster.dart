class FixtureReliabilityRosterMember {
  const FixtureReliabilityRosterMember({
    required this.profileId,
    required this.displayName,
    required this.role,
    required this.isSelected,
    required this.isEligible,
    this.username,
    this.avatarUrl,
    this.unavailableReason,
  });

  final String profileId;
  final String displayName;
  final String? username;
  final String? avatarUrl;
  final String role;
  final bool isSelected;
  final bool isEligible;
  final String? unavailableReason;

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first.substring(0, 1).toUpperCase();
    }
    return '${words.first[0]}${words.last[0]}'.toUpperCase();
  }

  factory FixtureReliabilityRosterMember.fromJson(Map<String, dynamic> json) {
    return FixtureReliabilityRosterMember(
      profileId: (json['profile_id'] as String? ?? '').trim(),
      displayName: (json['display_name'] as String? ?? 'Player').trim(),
      username: _nonEmptyRosterString(json['username']),
      avatarUrl: _nonEmptyRosterString(json['avatar_url']),
      role: (json['role'] as String? ?? 'member').trim().toLowerCase(),
      isSelected: json['selected'] as bool? ?? false,
      isEligible: json['eligible'] as bool? ?? false,
      unavailableReason: _nonEmptyRosterString(json['unavailable_reason']),
    );
  }
}

class FixtureReliabilityRoster {
  const FixtureReliabilityRoster({
    required this.fixtureId,
    required this.clanId,
    required this.side,
    required this.requiredCount,
    required this.confirmedCount,
    required this.isComplete,
    required this.locksAt,
    required this.isLocked,
    required this.canManage,
    required this.canEdit,
    required this.members,
  });

  final String fixtureId;
  final String clanId;
  final String side;
  final int requiredCount;
  final int confirmedCount;
  final bool isComplete;
  final DateTime locksAt;
  final bool isLocked;
  final bool canManage;
  final bool canEdit;
  final List<FixtureReliabilityRosterMember> members;

  List<FixtureReliabilityRosterMember> get selectedMembers =>
      members.where((member) => member.isSelected).toList(growable: false);

  int get remainingCount {
    final remaining = requiredCount - confirmedCount;
    return remaining < 0 ? 0 : remaining;
  }

  factory FixtureReliabilityRoster.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['members'];
    final locksAt = DateTime.tryParse(
      (json['locks_at'] as String? ?? '').trim(),
    );
    if (locksAt == null) {
      throw const FormatException('Roster lock time is missing.');
    }
    return FixtureReliabilityRoster(
      fixtureId: (json['fixture_id'] as String? ?? '').trim(),
      clanId: (json['clan_id'] as String? ?? '').trim(),
      side: (json['side'] as String? ?? '').trim().toUpperCase(),
      requiredCount: _rosterInt(json['required_count']),
      confirmedCount: _rosterInt(json['confirmed_count']),
      isComplete: json['is_complete'] as bool? ?? false,
      locksAt: locksAt.toUtc(),
      isLocked: json['locked'] as bool? ?? false,
      canManage: json['can_manage'] as bool? ?? false,
      canEdit: json['can_edit'] as bool? ?? false,
      members: rawMembers is List
          ? [
              for (final rawMember in rawMembers)
                if (rawMember is Map)
                  FixtureReliabilityRosterMember.fromJson(
                    Map<String, dynamic>.from(rawMember),
                  ),
            ]
          : const [],
    );
  }
}

int _rosterInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String? _nonEmptyRosterString(Object? value) {
  final normalized = value?.toString().trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
