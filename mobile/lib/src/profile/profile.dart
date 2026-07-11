import '../clans/clan.dart';

class PlayerProfile {
  const PlayerProfile({
    required this.id,
    required this.displayName,
    required this.username,
    required this.bio,
    required this.followingCount,
    required this.fansCount,
    required this.appearances,
    required this.goals,
    required this.assists,
    required this.highlights,
    required this.career,
    this.phone,
    this.avatarUrl,
    this.clan,
  });

  final String id;
  final String displayName;
  final String username;
  final String bio;
  final String? phone;
  final String? avatarUrl;
  final ProfileClan? clan;
  final int followingCount;
  final int fansCount;
  final int appearances;
  final int goals;
  final int assists;
  final List<ProfileHighlight> highlights;
  final List<ProfileCareerEntry> career;

  PlayerProfile copyWith({int? followingCount, int? fansCount}) {
    return PlayerProfile(
      id: id,
      displayName: displayName,
      username: username,
      bio: bio,
      phone: phone,
      avatarUrl: avatarUrl,
      clan: clan,
      followingCount: followingCount ?? this.followingCount,
      fansCount: fansCount ?? this.fansCount,
      appearances: appearances,
      goals: goals,
      assists: assists,
      highlights: highlights,
      career: career,
    );
  }

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words
        .take(2)
        .map((word) => word.substring(0, 1))
        .join()
        .toUpperCase();
  }
}

enum ProfileConnectionTab { following, fans }

class ProfileConnectionCounts {
  const ProfileConnectionCounts({
    required this.followingCount,
    required this.fansCount,
  });

  final int followingCount;
  final int fansCount;
}

class ProfileConnections {
  const ProfileConnections({
    required this.following,
    required this.fans,
    required this.discover,
  });

  final List<ProfileConnection> following;
  final List<ProfileConnection> fans;
  final List<ProfileConnection> discover;
}

class DevProfileOption {
  const DevProfileOption({
    required this.id,
    required this.displayName,
    required this.username,
    this.phone,
    this.avatarUrl,
    this.clan,
  });

  final String id;
  final String displayName;
  final String username;
  final String? phone;
  final String? avatarUrl;
  final ProfileClan? clan;

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words
        .take(2)
        .map((word) => word.substring(0, 1))
        .join()
        .toUpperCase();
  }

  String get searchableText => [
    displayName,
    username,
    phone ?? '',
    clan?.name ?? '',
    clan?.tag ?? '',
  ].join(' ').toLowerCase();
}

class ProfileConnection {
  const ProfileConnection({
    required this.id,
    required this.displayName,
    required this.username,
    required this.isFollowedByMe,
    this.avatarUrl,
    this.clan,
  });

  final String id;
  final String displayName;
  final String username;
  final String? avatarUrl;
  final ProfileClan? clan;
  final bool isFollowedByMe;

  ProfileConnection copyWith({bool? isFollowedByMe}) {
    return ProfileConnection(
      id: id,
      displayName: displayName,
      username: username,
      avatarUrl: avatarUrl,
      clan: clan,
      isFollowedByMe: isFollowedByMe ?? this.isFollowedByMe,
    );
  }

  String get initials {
    final words = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words
        .take(2)
        .map((word) => word.substring(0, 1))
        .join()
        .toUpperCase();
  }
}

class ProfileUpdate {
  const ProfileUpdate({
    required this.displayName,
    required this.username,
    required this.bio,
    required this.avatarUrl,
  });

  final String displayName;
  final String username;
  final String bio;
  final String avatarUrl;
}

class ProfileClan {
  const ProfileClan({
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

  factory ProfileClan.fromJson(Map<String, dynamic> json) {
    return ProfileClan(
      id: json['id'] as String? ?? '',
      name: (json['name'] as String? ?? '').trim(),
      tag: (json['tag'] as String? ?? '').trim().toUpperCase(),
      emblem: json['emblem'] as String? ?? '⚽',
      themeId: json['theme_id'] as String? ?? 'pitch',
      patternId: json['pattern_id'] as String? ?? 'solid',
      skillRating: _asInt(json['skill_rating'], fallback: 1500),
    );
  }
}

class ProfileHighlight {
  const ProfileHighlight({
    required this.id,
    required this.title,
    required this.thumbnailUrl,
    required this.duration,
    required this.views,
    this.videoUrl,
    this.clanTag,
  });

  final String id;
  final String title;
  final String thumbnailUrl;
  final String duration;
  final int views;
  final String? videoUrl;
  final String? clanTag;

  factory ProfileHighlight.fromJson(Map<String, dynamic> json) {
    return ProfileHighlight(
      id: json['id'] as String? ?? '',
      title: (json['title'] as String? ?? '').trim(),
      thumbnailUrl: json['thumbnail_url'] as String? ?? '',
      videoUrl: json['video_url'] as String?,
      duration: json['duration'] as String? ?? '0:00',
      views: _asInt(json['views']),
      clanTag: (json['clan_tag'] as String?)?.trim().toUpperCase(),
    );
  }
}

class ProfileCareerEntry {
  const ProfileCareerEntry({
    required this.id,
    required this.clanName,
    required this.tag,
    required this.emblem,
    required this.period,
    required this.apps,
    required this.goals,
    required this.isCurrent,
  });

  final String id;
  final String clanName;
  final String tag;
  final String emblem;
  final String period;
  final int apps;
  final int goals;
  final bool isCurrent;

  factory ProfileCareerEntry.fromJson(Map<String, dynamic> json) {
    return ProfileCareerEntry(
      id: json['id'] as String? ?? '',
      clanName: (json['clan_name'] as String? ?? '').trim(),
      tag: (json['tag'] as String? ?? '').trim().toUpperCase(),
      emblem: json['emblem'] as String? ?? '⚽',
      period: (json['period'] as String? ?? '').trim(),
      apps: _asInt(json['apps']),
      goals: _asInt(json['goals']),
      isCurrent: json['is_current'] as bool? ?? false,
    );
  }
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}
