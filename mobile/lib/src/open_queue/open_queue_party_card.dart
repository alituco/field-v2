import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import 'open_queue.dart';
import 'open_queue_party.dart';

class OpenQueuePartyCard extends StatelessWidget {
  const OpenQueuePartyCard({
    super.key,
    required this.contextData,
    required this.loading,
    required this.newlyBooked,
    required this.actionKey,
    required this.onRetry,
    required this.onCreate,
    required this.onAcceptInvite,
    required this.onDeclineInvite,
    required this.onInvitePlayers,
    required this.onCancelInvite,
    required this.onLeaveOrDisband,
    this.error,
  });

  final OpenQueuePartyContext? contextData;
  final bool loading;
  final bool newlyBooked;
  final String? actionKey;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onCreate;
  final ValueChanged<OpenQueuePartyInvite> onAcceptInvite;
  final ValueChanged<OpenQueuePartyInvite> onDeclineInvite;
  final VoidCallback onInvitePlayers;
  final ValueChanged<OpenQueuePartyMember> onCancelInvite;
  final VoidCallback onLeaveOrDisband;

  @override
  Widget build(BuildContext context) {
    if (loading && contextData == null) return const _PartyLoadingCard();
    if (contextData == null) {
      return _PartyErrorCard(error: error, onRetry: onRetry);
    }
    final data = contextData!;
    if (data.receivedInvites.isNotEmpty) {
      return _IncomingPartyInviteCard(
        invite: data.receivedInvites.first,
        maxPartySize: data.maxPartySize,
        partyLockLeadLabel: data.partyLockLeadLabel,
        currentParty: data.myParty,
        actionKey: actionKey,
        error: error,
        onAccept: onAcceptInvite,
        onDecline: onDeclineInvite,
      );
    }
    if (data.myParty case final party?) {
      return _ActivePartyCard(
        party: party,
        maxPartySize: data.maxPartySize,
        partyLockLeadLabel: data.partyLockLeadLabel,
        canUseParties: data.canUseParties,
        hasEligiblePlayers: data.eligiblePlayers.isNotEmpty,
        actionKey: actionKey,
        error: error,
        onInvitePlayers: onInvitePlayers,
        onCancelInvite: onCancelInvite,
        onLeaveOrDisband: onLeaveOrDisband,
      );
    }
    if (!data.canUseParties) {
      return _PartyLockedCard(partyLockLeadLabel: data.partyLockLeadLabel);
    }
    return _CreatePartyCard(
      newlyBooked: newlyBooked,
      maxPartySize: data.maxPartySize,
      partyLockLeadLabel: data.partyLockLeadLabel,
      creating: actionKey == 'create',
      error: error,
      onCreate: onCreate,
    );
  }
}

class _CreatePartyCard extends StatelessWidget {
  const _CreatePartyCard({
    required this.newlyBooked,
    required this.maxPartySize,
    required this.partyLockLeadLabel,
    required this.creating,
    required this.onCreate,
    this.error,
  });

  final bool newlyBooked;
  final int maxPartySize;
  final String partyLockLeadLabel;
  final bool creating;
  final String? error;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('open-queue-party-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF111827), Color(0xFF073F35)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2610B981),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.group_add_rounded,
                  color: Color(0xFF6EE7B7),
                  size: 23,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  newlyBooked ? 'SPOT SECURED · NEXT' : 'PLAY TOGETHER',
                  style: const TextStyle(
                    color: Color(0xFF6EE7B7),
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'MAX $maxPartySize',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .6,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            newlyBooked
                ? 'Bring your people.'
                : 'Want your friends beside you?',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              height: 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: -.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a party of up to $maxPartySize confirmed players. Once they accept, you will be assigned to the same team.',
            style: const TextStyle(
              color: Color(0xFFD1D5DB),
              fontSize: 12,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 9),
          _RebalanceNote(dark: true, partyLockLeadLabel: partyLockLeadLabel),
          if (error != null) ...[
            const SizedBox(height: 11),
            _InlinePartyError(message: error!, dark: true),
          ],
          const SizedBox(height: 17),
          FilledButton.icon(
            key: const ValueKey('create-open-queue-party'),
            onPressed: creating ? null : onCreate,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: Colors.white,
              foregroundColor: fieldGray900,
              disabledBackgroundColor: Colors.white.withValues(alpha: 0.7),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: Text(
              creating ? 'Creating party…' : 'Create a party',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _IncomingPartyInviteCard extends StatefulWidget {
  const _IncomingPartyInviteCard({
    required this.invite,
    required this.maxPartySize,
    required this.partyLockLeadLabel,
    required this.currentParty,
    required this.actionKey,
    required this.onAccept,
    required this.onDecline,
    this.error,
  });

  final OpenQueuePartyInvite invite;
  final int maxPartySize;
  final String partyLockLeadLabel;
  final OpenQueueParty? currentParty;
  final String? actionKey;
  final String? error;
  final ValueChanged<OpenQueuePartyInvite> onAccept;
  final ValueChanged<OpenQueuePartyInvite> onDecline;

  @override
  State<_IncomingPartyInviteCard> createState() =>
      _IncomingPartyInviteCardState();
}

class _IncomingPartyInviteCardState extends State<_IncomingPartyInviteCard> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _IncomingPartyInviteCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error != null && oldWidget.error != widget.error) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final invite = widget.invite;
    final switchingParties = widget.currentParty != null;
    final accepting = widget.actionKey == 'accept-${invite.membershipId}';
    final declining = widget.actionKey == 'decline-${invite.membershipId}';
    final busy = accepting || declining;
    return Container(
      key: const ValueKey('open-queue-party-invite'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldEmerald200, width: 1.4),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1710B981),
            blurRadius: 22,
            offset: Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('open-queue-party-invite-indicator'),
              onTap: busy ? null : () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.all(17),
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _PartyAvatar(
                          displayName: invite.owner.displayName,
                          avatarUrl: invite.owner.avatarUrl,
                          size: 48,
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: fieldEmerald600,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: const Icon(
                              Icons.group_add_rounded,
                              color: Colors.white,
                              size: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'PARTY INVITE · ACTION NEEDED',
                            style: TextStyle(
                              color: fieldEmerald700,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                              letterSpacing: .9,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${invite.owner.displayName} invited you to play together',
                            style: const TextStyle(
                              color: fieldGray900,
                              fontSize: 15,
                              height: 1.2,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${invite.acceptedCount}/${widget.maxPartySize} together · Tap to ${_expanded
                                ? 'close'
                                : switchingParties
                                ? 'switch or decline'
                                : 'respond'}',
                            style: const TextStyle(
                              color: fieldGray500,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? .5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: fieldEmerald50,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: fieldEmerald700,
                          size: 22,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: _expanded
                ? Container(
                    key: const ValueKey(
                      'open-queue-party-invite-response-flow',
                    ),
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(17, 15, 17, 17),
                    decoration: const BoxDecoration(
                      color: Color(0xFFFAFFFD),
                      border: Border(top: BorderSide(color: fieldEmerald100)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _MemberAvatarStack(
                              members: invite.members,
                              fallbackOwner: invite.owner,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${invite.acceptedCount} of ${widget.maxPartySize} already together',
                                style: const TextStyle(
                                  color: fieldGray600,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 13),
                        const Text(
                          'Accept and your party will be assigned to the same team.',
                          style: TextStyle(
                            color: fieldGray700,
                            fontSize: 12,
                            height: 1.4,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _RebalanceNote(
                          partyLockLeadLabel: widget.partyLockLeadLabel,
                        ),
                        if (switchingParties) ...[
                          const SizedBox(height: 11),
                          _PartySwitchWarning(
                            inviteOwnerName: invite.owner.displayName,
                            currentUserIsOwner:
                                widget.currentParty?.isOwner ?? false,
                          ),
                        ],
                        if (widget.error != null) ...[
                          const SizedBox(height: 11),
                          _InlinePartyError(message: widget.error!),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                key: const ValueKey(
                                  'decline-open-queue-party-invite',
                                ),
                                onPressed: busy
                                    ? null
                                    : () => widget.onDecline(invite),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48),
                                  foregroundColor: fieldGray600,
                                  side: const BorderSide(color: fieldGray200),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                ),
                                child: Text(
                                  declining ? 'Declining…' : 'Decline',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              flex: 2,
                              child: FilledButton.icon(
                                key: const ValueKey(
                                  'accept-open-queue-party-invite',
                                ),
                                onPressed: busy
                                    ? null
                                    : () => widget.onAccept(invite),
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48),
                                  backgroundColor: fieldEmerald600,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                ),
                                icon: accepting
                                    ? const SizedBox(
                                        width: 17,
                                        height: 17,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.group_add_rounded,
                                        size: 19,
                                      ),
                                label: Text(
                                  accepting
                                      ? 'Joining…'
                                      : switchingParties
                                      ? 'Switch & join'
                                      : 'Join party',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _PartySwitchWarning extends StatelessWidget {
  const _PartySwitchWarning({
    required this.inviteOwnerName,
    required this.currentUserIsOwner,
  });

  final String inviteOwnerName;
  final bool currentUserIsOwner;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('open-queue-party-switch-warning'),
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        border: Border.all(color: const Color(0xFFFDE68A)),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.swap_horiz_rounded,
            color: Color(0xFFD97706),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              currentUserIsOwner
                  ? 'Joining $inviteOwnerName will cancel the party you lead, then move you into this one. Everyone keeps their individual booking.'
                  : 'Joining $inviteOwnerName will move you out of your current party and into this one. Your individual booking stays confirmed.',
              style: const TextStyle(
                color: Color(0xFF92400E),
                fontSize: 10,
                height: 1.4,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivePartyCard extends StatelessWidget {
  const _ActivePartyCard({
    required this.party,
    required this.maxPartySize,
    required this.partyLockLeadLabel,
    required this.canUseParties,
    required this.hasEligiblePlayers,
    required this.actionKey,
    required this.onInvitePlayers,
    required this.onCancelInvite,
    required this.onLeaveOrDisband,
    this.error,
  });

  final OpenQueueParty party;
  final int maxPartySize;
  final String partyLockLeadLabel;
  final bool canUseParties;
  final bool hasEligiblePlayers;
  final String? actionKey;
  final String? error;
  final VoidCallback onInvitePlayers;
  final ValueChanged<OpenQueuePartyMember> onCancelInvite;
  final VoidCallback onLeaveOrDisband;

  @override
  Widget build(BuildContext context) {
    final canInvite =
        canUseParties &&
        party.isOwner &&
        party.members.length < maxPartySize &&
        hasEligiblePlayers;
    final leaving =
        actionKey == 'leave-${party.id}' || actionKey == 'disband-${party.id}';
    return Container(
      key: const ValueKey('open-queue-party-card'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldEmerald200, width: 1.3),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1010B981),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 17, 18, 14),
            color: fieldEmerald50,
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.groups_2_rounded,
                    color: fieldEmerald700,
                    size: 23,
                  ),
                ),
                const SizedBox(width: 11),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'YOUR PARTY',
                        style: TextStyle(
                          color: fieldEmerald700,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.1,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'You are playing together',
                        style: TextStyle(
                          color: fieldGray900,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  key: const ValueKey('open-queue-party-count'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${party.acceptedCount}/$maxPartySize',
                    style: const TextStyle(
                      color: fieldEmerald800,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 15, 18, 17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Accepted party members are assigned to the same team.',
                  style: TextStyle(
                    color: fieldGray700,
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 7),
                _RebalanceNote(partyLockLeadLabel: partyLockLeadLabel),
                if (!canUseParties) ...[
                  const SizedBox(height: 12),
                  _PartyMutationLockNotice(
                    partyLockLeadLabel: partyLockLeadLabel,
                  ),
                ],
                const SizedBox(height: 15),
                for (var index = 0; index < party.members.length; index++) ...[
                  _PartyMemberRow(
                    member: party.members[index],
                    cancelling:
                        actionKey ==
                        'cancel-${party.members[index].membershipId}',
                    canCancel:
                        canUseParties &&
                        party.isOwner &&
                        party.members[index].status ==
                            OpenQueuePartyMemberStatus.invited,
                    onCancel: onCancelInvite,
                  ),
                  if (index != party.members.length - 1)
                    const Divider(height: 15, color: fieldGray100),
                ],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  _InlinePartyError(message: error!),
                ],
                const SizedBox(height: 16),
                if (party.isOwner)
                  FilledButton.icon(
                    key: const ValueKey('invite-open-queue-party-player'),
                    onPressed: canInvite ? onInvitePlayers : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: fieldEmerald600,
                      disabledBackgroundColor: fieldGray100,
                      disabledForegroundColor: fieldGray400,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                    icon: Icon(
                      !canUseParties
                          ? Icons.lock_rounded
                          : party.members.length >= maxPartySize
                          ? Icons.check_circle_rounded
                          : Icons.person_add_alt_1_rounded,
                      size: 19,
                    ),
                    label: Text(
                      !canUseParties
                          ? 'Party changes closed'
                          : party.members.length >= maxPartySize
                          ? 'Party list full'
                          : hasEligiblePlayers
                          ? 'Invite a confirmed player'
                          : 'No players available to invite',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                const SizedBox(height: 7),
                Center(
                  child: TextButton(
                    key: ValueKey(
                      party.isOwner
                          ? 'disband-open-queue-party'
                          : 'leave-open-queue-party',
                    ),
                    onPressed: leaving || !canUseParties
                        ? null
                        : onLeaveOrDisband,
                    child: Text(
                      !canUseParties
                          ? 'Party locked for this match'
                          : leaving
                          ? 'Updating party…'
                          : party.isOwner
                          ? 'Cancel party'
                          : 'Leave party',
                      style: const TextStyle(
                        color: fieldGray500,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PartyMutationLockNotice extends StatelessWidget {
  const _PartyMutationLockNotice({required this.partyLockLeadLabel});

  final String partyLockLeadLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('open-queue-party-mutations-locked'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      decoration: BoxDecoration(
        color: fieldGray100,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_clock_rounded, color: fieldGray500, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Party changes close $partyLockLeadLabel. Your confirmed group stays together, but no one can be invited, removed, or leave now.',
              style: const TextStyle(
                color: fieldGray600,
                fontSize: 10,
                height: 1.4,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PartyMemberRow extends StatelessWidget {
  const _PartyMemberRow({
    required this.member,
    required this.cancelling,
    required this.canCancel,
    required this.onCancel,
  });

  final OpenQueuePartyMember member;
  final bool cancelling;
  final bool canCancel;
  final ValueChanged<OpenQueuePartyMember> onCancel;

  @override
  Widget build(BuildContext context) {
    final accepted = member.status == OpenQueuePartyMemberStatus.accepted;
    return Row(
      children: [
        _PartyAvatar(
          displayName: member.displayName,
          avatarUrl: member.avatarUrl,
          size: 40,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      member.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (member.isOwner) ...[
                    const SizedBox(width: 5),
                    const Icon(
                      Icons.star_rounded,
                      color: Color(0xFFF59E0B),
                      size: 15,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                member.username == null
                    ? member.role.label
                    : '@${member.username!.replaceFirst('@', '')} · ${member.role.label}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: accepted ? fieldEmerald50 : const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                accepted ? Icons.check_rounded : Icons.schedule_rounded,
                color: accepted ? fieldEmerald700 : const Color(0xFFD97706),
                size: 12,
              ),
              const SizedBox(width: 3),
              Text(
                accepted ? 'IN' : 'INVITED',
                style: TextStyle(
                  color: accepted ? fieldEmerald700 : const Color(0xFFB45309),
                  fontSize: 8,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .4,
                ),
              ),
            ],
          ),
        ),
        if (canCancel) ...[
          const SizedBox(width: 3),
          IconButton(
            key: ValueKey('cancel-party-invite-${member.membershipId}'),
            tooltip: 'Cancel invitation',
            visualDensity: VisualDensity.compact,
            onPressed: cancelling ? null : () => onCancel(member),
            icon: cancelling
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ],
    );
  }
}

class _PartyLockedCard extends StatelessWidget {
  const _PartyLockedCard({required this.partyLockLeadLabel});

  final String partyLockLeadLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('open-queue-party-locked'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_clock_rounded, color: fieldGray400),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Party changes are closed',
                  style: TextStyle(
                    color: fieldGray900,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Parties close $partyLockLeadLabel so teams and kits can be finalized.',
                  style: const TextStyle(
                    color: fieldGray500,
                    fontSize: 11,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PartyLoadingCard extends StatelessWidget {
  const _PartyLoadingCard();

  @override
  Widget build(BuildContext context) {
    return const FieldSkeletonCard(
      key: ValueKey('open-queue-party-loading'),
      height: 205,
      borderRadius: 24,
      children: [
        FieldSkeletonBox(width: 110, height: 12),
        SizedBox(height: 15),
        FieldSkeletonBox(height: 24),
        SizedBox(height: 11),
        FieldSkeletonBox(height: 42),
        SizedBox(height: 13),
        FieldSkeletonBox(height: 46),
      ],
    );
  }
}

class _PartyErrorCard extends StatelessWidget {
  const _PartyErrorCard({required this.error, required this.onRetry});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('open-queue-party-error'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        border: Border.all(color: const Color(0xFFFDE68A)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_off_rounded, color: Color(0xFFD97706)),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Party details did not load',
                  style: TextStyle(
                    color: fieldGray900,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  error ??
                      'Your booking is safe. Try loading party details again.',
                  style: const TextStyle(
                    color: fieldGray600,
                    fontSize: 11,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _RebalanceNote extends StatelessWidget {
  const _RebalanceNote({required this.partyLockLeadLabel, this.dark = false});

  final String partyLockLeadLabel;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.balance_rounded,
          color: dark ? const Color(0xFF6EE7B7) : fieldEmerald600,
          size: 14,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Party changes close $partyLockLeadLabel.',
            style: TextStyle(
              color: dark ? const Color(0xFFA7F3D0) : fieldGray500,
              fontSize: 10,
              height: 1.35,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _InlinePartyError extends StatelessWidget {
  const _InlinePartyError({required this.message, this.dark = false});

  final String message;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: dark
            ? Colors.redAccent.withValues(alpha: 0.16)
            : const Color(0xFFFFF1F2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: dark ? const Color(0xFFFECACA) : const Color(0xFF9F1239),
          fontSize: 10,
          height: 1.35,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MemberAvatarStack extends StatelessWidget {
  const _MemberAvatarStack({
    required this.members,
    required this.fallbackOwner,
  });

  final List<OpenQueuePartyMember> members;
  final OpenQueuePartyPlayer fallbackOwner;

  @override
  Widget build(BuildContext context) {
    final visible = members.take(3).toList(growable: false);
    return SizedBox(
      width: 32 + (visible.isEmpty ? 0 : (visible.length - 1) * 22),
      height: 34,
      child: Stack(
        children: [
          if (visible.isEmpty)
            _PartyAvatar(
              displayName: fallbackOwner.displayName,
              avatarUrl: fallbackOwner.avatarUrl,
              size: 34,
            ),
          for (var index = 0; index < visible.length; index++)
            Positioned(
              left: index * 22,
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                padding: const EdgeInsets.all(1.5),
                child: _PartyAvatar(
                  displayName: visible[index].displayName,
                  avatarUrl: visible[index].avatarUrl,
                  size: 31,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PartyAvatar extends StatelessWidget {
  const _PartyAvatar({
    required this.displayName,
    required this.avatarUrl,
    required this.size,
  });

  final String displayName;
  final String? avatarUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = displayName.trim().isEmpty
        ? 'F'
        : displayName.trim().substring(0, 1).toUpperCase();
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: fieldEmerald100,
      foregroundImage: avatarUrl == null ? null : NetworkImage(avatarUrl!),
      child: Text(
        initial,
        style: TextStyle(
          color: fieldEmerald800,
          fontSize: size * .37,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

Future<void> showOpenQueuePartyInviteSheet({
  required BuildContext context,
  required OpenQueuePartyContext partyContext,
  required Future<String?> Function(OpenQueuePartyPlayer player) onInvite,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        _PartyInviteSheet(partyContext: partyContext, onInvite: onInvite),
  );
}

class _PartyInviteSheet extends StatefulWidget {
  const _PartyInviteSheet({required this.partyContext, required this.onInvite});

  final OpenQueuePartyContext partyContext;
  final Future<String?> Function(OpenQueuePartyPlayer player) onInvite;

  @override
  State<_PartyInviteSheet> createState() => _PartyInviteSheetState();
}

class _PartyInviteSheetState extends State<_PartyInviteSheet> {
  final Set<String> _sent = {};
  String? _sending;
  String? _error;

  Future<void> _invite(OpenQueuePartyPlayer player) async {
    if (_sending != null) return;
    setState(() {
      _sending = player.profileId;
      _error = null;
    });
    final error = await widget.onInvite(player);
    if (!mounted) return;
    setState(() {
      _sending = null;
      _error = error;
      if (error == null) _sent.add(player.profileId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final party = widget.partyContext.myParty!;
    final openSlots =
        (widget.partyContext.maxPartySize - party.members.length - _sent.length)
            .clamp(0, widget.partyContext.maxPartySize);
    final players = widget.partyContext.eligiblePlayers;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .82,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 42,
            height: 5,
            decoration: BoxDecoration(
              color: fieldGray200,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 14, 14),
            child: Row(
              children: [
                Container(
                  width: 43,
                  height: 43,
                  decoration: BoxDecoration(
                    color: fieldEmerald50,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.person_add_alt_1_rounded,
                    color: fieldEmerald700,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Invite confirmed players',
                        style: TextStyle(
                          color: fieldGray900,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$openSlots party spot${openSlots == 1 ? '' : 's'} available · this game only',
                        style: const TextStyle(
                          color: fieldGray500,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: fieldGray100),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: _InlinePartyError(message: _error!),
            ),
          Flexible(
            child: players.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(30),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.group_off_rounded,
                          color: fieldGray300,
                          size: 38,
                        ),
                        SizedBox(height: 10),
                        Text(
                          'No one is available to invite',
                          style: TextStyle(
                            color: fieldGray900,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'No other confirmed player is available to invite for this game.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: fieldGray500,
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                    itemCount: players.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: fieldGray100),
                    itemBuilder: (context, index) {
                      final player = players[index];
                      final sent = _sent.contains(player.profileId);
                      final sending = _sending == player.profileId;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            _PartyAvatar(
                              displayName: player.displayName,
                              avatarUrl: player.avatarUrl,
                              size: 43,
                            ),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    player.displayName,
                                    style: const TextStyle(
                                      color: fieldGray900,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    player.isInParty
                                        ? '${player.role.label} · IN A PARTY · ${player.currentPartySize}/4${player.isCurrentPartyOwner ? ' · LEADER' : ''}'
                                        : '${player.role.label}${player.username == null ? '' : ' · @${player.username!.replaceFirst('@', '')}'}',
                                    style: TextStyle(
                                      color: player.isInParty
                                          ? const Color(0xFFD97706)
                                          : fieldGray500,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 78,
                              child: FilledButton(
                                key: ValueKey(
                                  'invite-party-player-${player.profileId}',
                                ),
                                onPressed: sent || sending || openSlots <= 0
                                    ? null
                                    : () => _invite(player),
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(38),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                  ),
                                  backgroundColor: fieldEmerald600,
                                  disabledBackgroundColor: sent
                                      ? fieldEmerald50
                                      : fieldGray100,
                                  disabledForegroundColor: sent
                                      ? fieldEmerald700
                                      : fieldGray400,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: sending
                                    ? const SizedBox(
                                        width: 15,
                                        height: 15,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Text(
                                        sent ? 'Sent' : 'Invite',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
            decoration: const BoxDecoration(
              color: fieldBackground,
              border: Border(top: BorderSide(color: fieldGray100)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: fieldGray500, size: 16),
                SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Players already in a party can still be invited. If they accept, they switch to yours before teams are assigned.',
                    style: TextStyle(
                      color: fieldGray500,
                      fontSize: 10,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
