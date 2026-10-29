import 'package:supabase_flutter/supabase_flutter.dart';
import '../profile/viewer_safe_identities.dart';

import 'open_queue_party.dart';

abstract interface class OpenQueuePartyRepository {
  Future<OpenQueuePartyContext> getPartyContext(String gameId);

  Future<String> createParty(String gameId);

  Future<String> invitePartyMember({
    required String partyId,
    required String profileId,
  });

  Future<void> respondToPartyInvite({
    required String membershipId,
    required bool accept,
  });

  Future<void> cancelPartyInvite(String membershipId);

  Future<void> leaveParty(String partyId);

  Future<void> disbandParty(String partyId);
}

abstract interface class OpenQueuePartyNotificationRepository {
  Future<List<OpenQueuePartyInviteNotification>> listPartyInviteNotifications();

  Future<void> markPartyInviteNotificationRead(String notificationId);

  Stream<void> watchPartyInviteNotifications();
}

mixin SupabaseOpenQueuePartyRepository
    implements OpenQueuePartyRepository, OpenQueuePartyNotificationRepository {
  SupabaseClient get partyClient;

  @override
  Future<OpenQueuePartyContext> getPartyContext(String gameId) async {
    final response = await partyClient.rpc(
      'get_open_queue_party_context',
      params: {'game_id_to_use': gameId},
    );
    final json = switch (response) {
      final Map value => Map<String, dynamic>.from(value),
      final List value when value.isNotEmpty && value.first is Map =>
        Map<String, dynamic>.from(value.first as Map),
      _ => throw StateError('Party details are unavailable.'),
    };
    final safe = await viewerSafeIdentityPayload(partyClient, json);
    if (safe['eligible_players'] is List) {
      safe['eligible_players'] = [
        for (final row in safe['eligible_players'] as List)
          if (row is Map && row['content_hidden'] != true) row,
      ];
    }
    if (safe['received_invites'] is List) {
      safe['received_invites'] = [
        for (final row in safe['received_invites'] as List)
          if (row is Map &&
              row['owner'] is Map &&
              row['owner']['content_hidden'] != true)
            row,
      ];
    }
    return OpenQueuePartyContext.fromJson(safe);
  }

  @override
  Future<String> createParty(String gameId) async {
    final response = await partyClient.rpc(
      'create_open_queue_party',
      params: {'game_id_to_use': gameId},
    );
    return _rpcId(response, fallback: 'The party could not be created.');
  }

  @override
  Future<String> invitePartyMember({
    required String partyId,
    required String profileId,
  }) async {
    final response = await partyClient.rpc(
      'invite_open_queue_party_member',
      params: {
        'party_id_to_use': partyId,
        'target_profile_id_to_use': profileId,
      },
    );
    return _rpcId(response, fallback: 'The invitation could not be sent.');
  }

  @override
  Future<void> respondToPartyInvite({
    required String membershipId,
    required bool accept,
  }) async {
    await partyClient.rpc(
      'respond_open_queue_party_invitation',
      params: {'membership_id_to_use': membershipId, 'accept_to_use': accept},
    );
  }

  @override
  Future<void> cancelPartyInvite(String membershipId) async {
    await partyClient.rpc(
      'cancel_open_queue_party_invitation',
      params: {'membership_id_to_use': membershipId},
    );
  }

  @override
  Future<void> leaveParty(String partyId) async {
    await partyClient.rpc(
      'leave_open_queue_party',
      params: {'party_id_to_use': partyId},
    );
  }

  @override
  Future<void> disbandParty(String partyId) async {
    await partyClient.rpc(
      'disband_open_queue_party',
      params: {'party_id_to_use': partyId},
    );
  }

  @override
  Future<List<OpenQueuePartyInviteNotification>>
  listPartyInviteNotifications() async {
    final response = await partyClient.rpc(
      'list_my_open_queue_party_invite_notifications',
    );
    final rows = switch (response) {
      final List value => value,
      final Map value => [value],
      _ => const <dynamic>[],
    };
    return [
      for (final row in await viewerSafeIdentityRows(partyClient, rows))
        if (row is Map &&
            row['inviter'] is Map &&
            row['inviter']['content_hidden'] != true)
          OpenQueuePartyInviteNotification.fromJson(
            Map<String, dynamic>.from(row),
          ),
    ];
  }

  @override
  Future<void> markPartyInviteNotificationRead(String notificationId) async {
    await partyClient.rpc(
      'mark_my_open_queue_party_invite_notification_read',
      params: {'notification_id_to_use': notificationId},
    );
  }

  @override
  Stream<void> watchPartyInviteNotifications() {
    final profileId = partyClient.auth.currentUser?.id;
    if (profileId == null) return const Stream<void>.empty();
    return partyClient
        .from('notifications')
        .stream(primaryKey: ['id'])
        .eq('recipient_profile_id', profileId)
        .map((_) {});
  }
}

String _rpcId(dynamic value, {required String fallback}) {
  final id = switch (value) {
    final String text => text,
    final Map map =>
      map['id']?.toString() ??
          map['party_id']?.toString() ??
          map['membership_id']?.toString(),
    _ => null,
  };
  if (id == null || id.trim().isEmpty) throw StateError(fallback);
  return id.trim();
}
