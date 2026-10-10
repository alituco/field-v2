import 'open_queue.dart';

class OpenQueuePartyContext {
  const OpenQueuePartyContext({
    required this.gameId,
    required this.gameStatus,
    required this.canUseParties,
    required this.maxPartySize,
    required this.receivedInvites,
    required this.eligiblePlayers,
    this.policyVersionId,
    this.serverNow,
    this.teamAssignmentAt,
    this.partyLockAt,
    this.teamAssignmentLeadMinutes,
    this.partyLockLeadMinutes,
    this.myParty,
  });

  final String gameId;
  final String gameStatus;
  final bool canUseParties;
  final int maxPartySize;
  final String? policyVersionId;
  final DateTime? serverNow;
  final DateTime? teamAssignmentAt;
  final DateTime? partyLockAt;
  final int? teamAssignmentLeadMinutes;
  final int? partyLockLeadMinutes;
  final OpenQueueParty? myParty;
  final List<OpenQueuePartyInvite> receivedInvites;
  final List<OpenQueuePartyPlayer> eligiblePlayers;

  factory OpenQueuePartyContext.fromJson(Map<String, dynamic> json) {
    return OpenQueuePartyContext(
      gameId: _string(json['game_id']),
      gameStatus: _string(json['game_status'], fallback: 'OPEN').toUpperCase(),
      canUseParties: json['can_use_parties'] == true,
      maxPartySize: _integer(json['max_party_size'], fallback: 4).clamp(1, 4),
      policyVersionId: _nullableString(json['policy_version_id']),
      serverNow: _date(json['server_now']),
      teamAssignmentAt: _date(json['team_assignment_at']),
      partyLockAt: _date(json['party_lock_at']),
      teamAssignmentLeadMinutes: _nullableInteger(
        json['team_assignment_lead_minutes'],
      ),
      partyLockLeadMinutes: _nullableInteger(json['party_lock_lead_minutes']),
      myParty: switch (json['my_party']) {
        final Map value => OpenQueueParty.fromJson(
          Map<String, dynamic>.from(value),
        ),
        _ => null,
      },
      receivedInvites: _maps(
        json['received_invites'],
      ).map(OpenQueuePartyInvite.fromJson).toList(growable: false),
      eligiblePlayers: _maps(
        json['eligible_players'],
      ).map(OpenQueuePartyPlayer.fromJson).toList(growable: false),
    );
  }

  String get teamAssignmentLeadLabel =>
      openQueueLeadTimeLabel(teamAssignmentLeadMinutes);

  String get partyLockLeadLabel => openQueueLeadTimeLabel(partyLockLeadMinutes);
}

class OpenQueueParty {
  const OpenQueueParty({
    required this.id,
    required this.ownerProfileId,
    required this.isOwner,
    required this.acceptedCount,
    required this.members,
  });

  final String id;
  final String ownerProfileId;
  final bool isOwner;
  final int acceptedCount;
  final List<OpenQueuePartyMember> members;

  List<OpenQueuePartyMember> get acceptedMembers => members
      .where((member) => member.status == OpenQueuePartyMemberStatus.accepted)
      .toList(growable: false);

  List<OpenQueuePartyMember> get pendingMembers => members
      .where((member) => member.status == OpenQueuePartyMemberStatus.invited)
      .toList(growable: false);

  factory OpenQueueParty.fromJson(Map<String, dynamic> json) {
    return OpenQueueParty(
      id: _string(json['id']),
      ownerProfileId: _string(json['owner_profile_id']),
      isOwner: json['is_owner'] == true,
      acceptedCount: _integer(json['accepted_count'], fallback: 1),
      members: _maps(
        json['members'],
      ).map(OpenQueuePartyMember.fromJson).toList(growable: false),
    );
  }
}

enum OpenQueuePartyMemberStatus { invited, accepted }

class OpenQueuePartyMember {
  const OpenQueuePartyMember({
    required this.membershipId,
    required this.profileId,
    required this.displayName,
    required this.role,
    required this.status,
    required this.isOwner,
    required this.invitedAt,
    this.username,
    this.avatarUrl,
  });

  final String membershipId;
  final String profileId;
  final String displayName;
  final String? username;
  final String? avatarUrl;
  final OpenQueueRole role;
  final OpenQueuePartyMemberStatus status;
  final bool isOwner;
  final DateTime? invitedAt;

  factory OpenQueuePartyMember.fromJson(Map<String, dynamic> json) {
    return OpenQueuePartyMember(
      membershipId: _string(json['membership_id']),
      profileId: _string(json['profile_id']),
      displayName: _string(json['display_name'], fallback: 'Field player'),
      username: _nullableString(json['username']),
      avatarUrl: _nullableString(json['avatar_url']),
      role: OpenQueueRoleX.fromCode(_string(json['role'], fallback: 'MID')),
      status: _string(json['status']).toUpperCase() == 'INVITED'
          ? OpenQueuePartyMemberStatus.invited
          : OpenQueuePartyMemberStatus.accepted,
      isOwner: json['is_owner'] == true,
      invitedAt: _date(json['invited_at']),
    );
  }
}

class OpenQueuePartyInvite {
  const OpenQueuePartyInvite({
    required this.membershipId,
    required this.partyId,
    required this.invitedAt,
    required this.owner,
    required this.acceptedCount,
    required this.members,
  });

  final String membershipId;
  final String partyId;
  final DateTime? invitedAt;
  final OpenQueuePartyPlayer owner;
  final int acceptedCount;
  final List<OpenQueuePartyMember> members;

  factory OpenQueuePartyInvite.fromJson(Map<String, dynamic> json) {
    final owner = switch (json['owner']) {
      final Map value => Map<String, dynamic>.from(value),
      _ => <String, dynamic>{},
    };
    return OpenQueuePartyInvite(
      membershipId: _string(json['membership_id']),
      partyId: _string(json['party_id']),
      invitedAt: _date(json['invited_at']),
      owner: OpenQueuePartyPlayer.fromJson(owner),
      acceptedCount: _integer(json['accepted_count'], fallback: 1),
      members: _maps(
        json['members'],
      ).map(OpenQueuePartyMember.fromJson).toList(growable: false),
    );
  }
}

class OpenQueuePartyPlayer {
  const OpenQueuePartyPlayer({
    required this.profileId,
    required this.displayName,
    required this.role,
    this.username,
    this.avatarUrl,
    this.isInParty = false,
    this.currentPartyId,
    this.isCurrentPartyOwner = false,
    this.currentPartySize = 0,
  });

  final String profileId;
  final String displayName;
  final String? username;
  final String? avatarUrl;
  final OpenQueueRole role;
  final bool isInParty;
  final String? currentPartyId;
  final bool isCurrentPartyOwner;
  final int currentPartySize;

  factory OpenQueuePartyPlayer.fromJson(Map<String, dynamic> json) {
    return OpenQueuePartyPlayer(
      profileId: _string(json['profile_id']),
      displayName: _string(json['display_name'], fallback: 'Field player'),
      username: _nullableString(json['username']),
      avatarUrl: _nullableString(json['avatar_url']),
      role: OpenQueueRoleX.fromCode(_string(json['role'], fallback: 'MID')),
      isInParty: json['is_in_party'] == true,
      currentPartyId: _nullableString(json['current_party_id']),
      isCurrentPartyOwner: json['is_current_party_owner'] == true,
      currentPartySize: _integer(
        json['current_party_size'],
        fallback: 0,
      ).clamp(0, 4),
    );
  }
}

class OpenQueuePartyInviteNotification {
  const OpenQueuePartyInviteNotification({
    required this.id,
    required this.gameId,
    required this.partyId,
    required this.membershipId,
    required this.createdAt,
    required this.isRead,
    required this.inviter,
    required this.gameStartsAt,
    required this.venue,
    required this.gameStatus,
    this.readAt,
    this.policyVersionId,
    this.partyLockAt,
  });

  final String id;
  final String gameId;
  final String partyId;
  final String membershipId;
  final DateTime? createdAt;
  final DateTime? readAt;
  final bool isRead;
  final OpenQueuePartyNotificationInviter inviter;
  final DateTime? gameStartsAt;
  final String venue;
  final String gameStatus;
  final String? policyVersionId;
  final DateTime? partyLockAt;

  factory OpenQueuePartyInviteNotification.fromJson(Map<String, dynamic> json) {
    final inviter = switch (json['inviter']) {
      final Map value => Map<String, dynamic>.from(value),
      _ => <String, dynamic>{},
    };
    final game = switch (json['game']) {
      final Map value => Map<String, dynamic>.from(value),
      _ => <String, dynamic>{},
    };
    return OpenQueuePartyInviteNotification(
      id: _string(json['notification_id']),
      gameId: _string(json['game_id']),
      partyId: _string(json['party_id']),
      membershipId: _string(json['membership_id']),
      createdAt: _date(json['created_at']),
      readAt: _date(json['read_at']),
      isRead: json['is_read'] == true,
      inviter: OpenQueuePartyNotificationInviter.fromJson(inviter),
      gameStartsAt: _date(game['starts_at']),
      venue: _string(game['venue'], fallback: 'Venue to be confirmed'),
      gameStatus: _string(game['status'], fallback: 'OPEN').toUpperCase(),
      policyVersionId: _nullableString(game['policy_version_id']),
      partyLockAt: _date(game['party_lock_at']),
    );
  }
}

class OpenQueuePartyNotificationInviter {
  const OpenQueuePartyNotificationInviter({
    required this.profileId,
    required this.displayName,
    this.username,
    this.avatarUrl,
  });

  final String profileId;
  final String displayName;
  final String? username;
  final String? avatarUrl;

  factory OpenQueuePartyNotificationInviter.fromJson(
    Map<String, dynamic> json,
  ) {
    return OpenQueuePartyNotificationInviter(
      profileId: _string(json['profile_id']),
      displayName: _string(json['display_name'], fallback: 'A player'),
      username: _nullableString(json['username']),
      avatarUrl: _nullableString(json['avatar_url']),
    );
  }
}

List<Map<String, dynamic>> _maps(dynamic value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

String _string(dynamic value, {String fallback = ''}) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? fallback : normalized;
}

String? _nullableString(dynamic value) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

int _integer(dynamic value, {required int fallback}) {
  return switch (value) {
    final num number => number.round(),
    final String text => int.tryParse(text) ?? fallback,
    _ => fallback,
  };
}

int? _nullableInteger(dynamic value) {
  return switch (value) {
    final num number => number.round(),
    final String text => int.tryParse(text),
    _ => null,
  };
}

DateTime? _date(dynamic value) {
  final text = _nullableString(value);
  return text == null ? null : DateTime.tryParse(text)?.toLocal();
}
