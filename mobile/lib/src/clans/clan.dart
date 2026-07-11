import 'dart:ui';

enum ClanTier { silver, gold, diamond, champion }

class ClanRank {
  const ClanRank({required this.tier, this.division});

  final ClanTier tier;
  final int? division;

  String get label {
    final tierName = switch (tier) {
      ClanTier.silver => 'Silver',
      ClanTier.gold => 'Gold',
      ClanTier.diamond => 'Diamond',
      ClanTier.champion => 'Champion',
    };
    final divisionLabel = division == null ? '' : ' $division';
    return '$tierName$divisionLabel';
  }
}

class ClanTheme {
  const ClanTheme({
    required this.id,
    required this.name,
    required this.from,
    required this.to,
    required this.accent,
  });

  final String id;
  final String name;
  final Color from;
  final Color to;
  final Color accent;
}

class ClanPattern {
  const ClanPattern({
    required this.id,
    required this.name,
    required this.description,
  });

  final String id;
  final String name;
  final String description;
}

class ClanMember {
  const ClanMember({
    required this.profileId,
    required this.displayName,
    required this.role,
    this.phone,
    this.joinedAt,
  });

  final String profileId;
  final String displayName;
  final String role;
  final String? phone;
  final DateTime? joinedAt;

  bool get isOwner => role == 'owner';

  bool get isLeader => role == 'leader';

  bool get isManager => isOwner || isLeader;

  String get roleLabel => switch (role) {
    'owner' => 'Owner',
    'leader' => 'Leader',
    _ => 'Member',
  };

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words.take(2).map((word) => word[0]).join().toUpperCase();
  }

  factory ClanMember.fromJson(Map<String, dynamic> json) {
    final profile = _profileFromJson(json['profiles']);
    final displayName = (profile['display_name'] as String? ?? '').trim();

    return ClanMember(
      profileId: json['profile_id'] as String? ?? '',
      displayName: displayName.isEmpty ? 'Player' : displayName,
      role: json['role'] as String? ?? 'member',
      phone: profile['phone'] as String?,
      joinedAt: _asDateTime(json['created_at']),
    );
  }
}

class ClanMembership {
  const ClanMembership({required this.clanId, required this.role});

  final String clanId;
  final String role;

  bool get isOwner => role == 'owner';

  bool get isLeader => role == 'leader';

  bool get isManager => isOwner || isLeader;

  factory ClanMembership.fromJson(Map<String, dynamic> json) {
    return ClanMembership(
      clanId: json['clan_id'] as String? ?? '',
      role: json['role'] as String? ?? 'member',
    );
  }
}

class ClanJoinRequest {
  const ClanJoinRequest({
    required this.id,
    required this.clanId,
    required this.profileId,
    required this.displayName,
    required this.status,
    this.username,
    this.avatarUrl,
    this.requestedAt,
    this.cancellationCode,
    this.cancellationReason,
    this.cancelledAt,
    this.cancelledBy,
  });

  final String id;
  final String clanId;
  final String profileId;
  final String displayName;
  final String status;
  final String? username;
  final String? avatarUrl;
  final DateTime? requestedAt;
  final String? cancellationCode;
  final String? cancellationReason;
  final DateTime? cancelledAt;
  final String? cancelledBy;

  bool get isPending => status == 'PENDING';

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words.take(2).map((word) => word[0]).join().toUpperCase();
  }

  factory ClanJoinRequest.fromJson(Map<String, dynamic> json) {
    final profile = _profileFromJson(json['profiles']);
    final displayName = (profile['display_name'] as String? ?? '').trim();
    return ClanJoinRequest(
      id: json['id'] as String? ?? '',
      clanId: json['clan_id'] as String? ?? '',
      profileId: json['profile_id'] as String? ?? '',
      displayName: displayName.isEmpty ? 'Player' : displayName,
      status: (json['status'] as String? ?? 'PENDING').toUpperCase(),
      username: profile['username'] as String?,
      avatarUrl: profile['avatar_url'] as String?,
      requestedAt: _asDateTime(json['requested_at']),
      cancellationCode: json['cancellation_code'] as String?,
      cancellationReason: json['cancellation_reason'] as String?,
      cancelledAt: _asDateTime(json['cancelled_at']),
      cancelledBy: json['cancelled_by'] as String?,
    );
  }
}

class Clan {
  const Clan({
    required this.id,
    required this.name,
    required this.tag,
    required this.motto,
    required this.emblem,
    required this.themeId,
    required this.patternId,
    required this.skillRating,
    required this.wins,
    required this.losses,
    required this.memberCount,
    required this.createdBy,
    this.region = 'bahrain',
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String tag;
  final String motto;
  final String emblem;
  final String themeId;
  final String patternId;
  final int skillRating;
  final int wins;
  final int losses;
  final int memberCount;
  final String createdBy;
  final String region;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Clan.fromJson(Map<String, dynamic> json) {
    return Clan(
      id: json['id'] as String,
      name: (json['name'] as String).trim(),
      tag: (json['tag'] as String).trim().toUpperCase(),
      motto: (json['motto'] as String? ?? '').trim(),
      emblem: json['emblem'] as String? ?? '⚽',
      themeId: json['theme_id'] as String? ?? 'pitch',
      patternId: json['pattern_id'] as String? ?? 'solid',
      skillRating: _asInt(json['skill_rating'], fallback: 1500),
      wins: _asInt(json['wins']),
      losses: _asInt(json['losses']),
      memberCount: _asInt(json['member_count'], fallback: 1),
      createdBy: json['created_by'] as String? ?? '',
      region: (json['region'] as String? ?? 'bahrain').trim().toLowerCase(),
      createdAt: _asDateTime(json['created_at']),
      updatedAt: _asDateTime(json['updated_at']),
    );
  }

  int get matchesPlayed => wins + losses;

  int get winRate =>
      matchesPlayed == 0 ? 0 : ((wins / matchesPlayed) * 100).round();

  double get ratingProgress => (skillRating / 5000).clamp(0, 1).toDouble();

  ClanRank get rank => rankFromRating(skillRating);

  ClanTheme get theme => clanThemeById(themeId);

  ClanPattern get pattern => clanPatternById(patternId);
}

const clanThemes = [
  ClanTheme(
    id: 'pitch',
    name: 'Pitch Green',
    from: Color(0xFF10B981),
    to: Color(0xFF0369A1),
    accent: Color(0xFFBBF7D0),
  ),
  ClanTheme(
    id: 'electric',
    name: 'Electric Blue',
    from: Color(0xFF22D3EE),
    to: Color(0xFF4F46E5),
    accent: Color(0xFFCFFAFE),
  ),
  ClanTheme(
    id: 'royal',
    name: 'Royal Purple',
    from: Color(0xFFA855F7),
    to: Color(0xFF581C87),
    accent: Color(0xFFF5D0FE),
  ),
  ClanTheme(
    id: 'sunset',
    name: 'Sunset Strike',
    from: Color(0xFFF97316),
    to: Color(0xFFDB2777),
    accent: Color(0xFFFED7AA),
  ),
  ClanTheme(
    id: 'crimson',
    name: 'Crimson Fury',
    from: Color(0xFFEF4444),
    to: Color(0xFF7F1D1D),
    accent: Color(0xFFFECACA),
  ),
  ClanTheme(
    id: 'gold',
    name: 'Golden Age',
    from: Color(0xFFFACC15),
    to: Color(0xFFB45309),
    accent: Color(0xFFFEF3C7),
  ),
  ClanTheme(
    id: 'shadow',
    name: 'Shadow Realm',
    from: Color(0xFF1F2937),
    to: Color(0xFF000000),
    accent: Color(0xFF9CA3AF),
  ),
  ClanTheme(
    id: 'mint',
    name: 'Arctic Mint',
    from: Color(0xFF5EEAD4),
    to: Color(0xFF0D9488),
    accent: Color(0xFFCCFBF1),
  ),
];

const clanPatterns = [
  ClanPattern(id: 'solid', name: 'Solid', description: 'Clean & classic'),
  ClanPattern(id: 'stripes', name: 'Stripes', description: 'Classic kit vibes'),
  ClanPattern(id: 'sash', name: 'Sash', description: 'Old-school crest'),
  ClanPattern(id: 'chevron', name: 'Chevron', description: 'Aggressive arrow'),
  ClanPattern(id: 'pitch', name: 'Pitch', description: 'Live on the field'),
];

const clanEmblems = [
  '⚽',
  '🦁',
  '🐉',
  '🦅',
  '🐺',
  '🦈',
  '🐅',
  '🦏',
  '⚡',
  '🔥',
  '🌪️',
  '❄️',
  '☄️',
  '💥',
  '🌊',
  '🌑',
  '👑',
  '🛡️',
  '⚔️',
  '🏆',
  '💀',
  '🎯',
  '🚀',
  '🪽',
];

ClanTheme clanThemeById(String id) {
  return clanThemes.firstWhere(
    (theme) => theme.id == id,
    orElse: () => clanThemes.first,
  );
}

ClanPattern clanPatternById(String id) {
  return clanPatterns.firstWhere(
    (pattern) => pattern.id == id,
    orElse: () => clanPatterns.first,
  );
}

ClanRank rankFromRating(int rating) {
  if (rating >= 2700) return const ClanRank(tier: ClanTier.champion);

  final tier = rating < 900
      ? ClanTier.silver
      : rating < 1800
      ? ClanTier.gold
      : ClanTier.diamond;

  final minRating = switch (tier) {
    ClanTier.silver => 0,
    ClanTier.gold => 900,
    ClanTier.diamond => 1800,
    ClanTier.champion => 2700,
  };
  final index = ((rating - minRating) / 300).floor().clamp(0, 2);
  return ClanRank(tier: tier, division: 3 - index);
}

Color tierStartColor(ClanTier tier) {
  return switch (tier) {
    ClanTier.silver => const Color(0xFFF1F5F9),
    ClanTier.gold => const Color(0xFFFEF3C7),
    ClanTier.diamond => const Color(0xFFCFFAFE),
    ClanTier.champion => const Color(0xFFFDE68A),
  };
}

Color tierMiddleColor(ClanTier tier) {
  return switch (tier) {
    ClanTier.silver => const Color(0xFF94A3B8),
    ClanTier.gold => const Color(0xFFF59E0B),
    ClanTier.diamond => const Color(0xFF0EA5E9),
    ClanTier.champion => const Color(0xFFEF4444),
  };
}

Color tierEndColor(ClanTier tier) {
  return switch (tier) {
    ClanTier.silver => const Color(0xFF334155),
    ClanTier.gold => const Color(0xFF7C2D12),
    ClanTier.diamond => const Color(0xFF0C2D6B),
    ClanTier.champion => const Color(0xFF581C87),
  };
}

Map<String, dynamic> _profileFromJson(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty) {
    final first = value.first;
    if (first is Map<String, dynamic>) return first;
    if (first is Map) return Map<String, dynamic>.from(first);
  }
  return const {};
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

DateTime? _asDateTime(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  return null;
}
