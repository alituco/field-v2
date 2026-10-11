import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/field_confirmation_dialog.dart';
import '../core/user_facing_error.dart';
import 'open_queue.dart';
import 'open_queue_party.dart';
import 'open_queue_party_card.dart';
import 'open_queue_party_repository.dart';
import 'open_queue_repository.dart';

/// Party membership is server-owned. Displayed cutoffs and button availability
/// come from the context response; the prototype's fixed times are not policy.
class FieldrushGameDetailParty extends StatefulWidget {
  const FieldrushGameDetailParty({
    super.key,
    required this.repository,
    required this.game,
    required this.onChanged,
    this.viewerProfileId,
  });
  final OpenQueueRepository repository;
  final OpenQueueGame game;
  final Future<void> Function() onChanged;
  final String? viewerProfileId;
  @override
  State<FieldrushGameDetailParty> createState() =>
      _FieldrushGameDetailPartyState();
}

class _FieldrushGameDetailPartyState extends State<FieldrushGameDetailParty> {
  OpenQueuePartyContext? _data;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  int _loadGeneration = 0;
  OpenQueuePartyRepository? get _repository =>
      widget.repository is OpenQueuePartyRepository
      ? widget.repository as OpenQueuePartyRepository
      : null;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant FieldrushGameDetailParty oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.game, widget.game) && !_busy) unawaited(_load());
  }

  Future<bool> _load() async {
    final generation = ++_loadGeneration;
    final repository = _repository;
    if (repository == null) {
      if (mounted) setState(() => _loading = false);
      return false;
    }
    try {
      final data = await repository.getPartyContext(widget.game.id);
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _data = data;
          _error = null;
        });
        return true;
      }
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(
          () => _error = userFacingError(
            error,
            fallback:
                'Party details could not be loaded. Your game booking is safe.',
          ),
        );
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
    return false;
  }

  Future<String?> _run(
    Future<void> Function(OpenQueuePartyRepository) action,
  ) async {
    final repository = _repository;
    if (repository == null || _busy) return 'Please wait and try again.';
    // A context response started before a membership mutation is stale even
    // when it arrives after the mutation's post-action refresh.
    _loadGeneration++;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(repository);
      if (!mounted) return null;
      setState(() {
        _data = null;
        _loading = true;
      });
      await _load();
      if (mounted) await widget.onChanged();
      return null;
    } catch (error) {
      final message = userFacingError(
        error,
        fallback: 'We could not update your party. Please try again.',
      );
      if (mounted) setState(() => _error = message);
      return message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _invite() async {
    var data = _data;
    if (data == null || !data.canUseParties) return;
    if (data.myParty == null) {
      final error = await _run((repository) async {
        await repository.createParty(widget.game.id);
      });
      if (error != null || !mounted) return;
      data = _data;
    }
    final party = data?.myParty;
    if (data == null || party == null || !party.isOwner || !mounted) return;
    await showOpenQueuePartyInviteSheet(
      context: context,
      partyContext: data,
      onInvite: (player) => _run((repository) async {
        await repository.invitePartyMember(
          partyId: party.id,
          profileId: player.profileId,
        );
      }),
    );
  }

  Future<void> _leave() async {
    final party = _data?.myParty;
    if (party == null) return;
    final confirmed = await showFieldConfirmDialog(
      context: context,
      icon: Icons.group_off_outlined,
      eyebrow: 'Your party',
      title: party.isOwner ? 'Cancel this party?' : 'Leave this party?',
      message: party.isOwner
          ? 'The party will close for all members and pending invitations.'
          : 'You will no longer be assigned together with this party.',
      detail: 'Everyone keeps their individual game booking.',
      cancelLabel: 'Keep party',
      confirmLabel: party.isOwner ? 'Cancel party' : 'Leave party',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      (repository) => party.isOwner
          ? repository.disbandParty(party.id)
          : repository.leaveParty(party.id),
    );
  }

  Future<void> _cancelInvite(OpenQueuePartyMember member) async {
    final confirmed = await showFieldConfirmDialog(
      context: context,
      icon: Icons.person_remove_outlined,
      eyebrow: 'Party invitation',
      title: 'Cancel ${member.displayName}’s invite?',
      message: 'They will no longer be able to accept this invitation.',
      detail: 'Their game booking will not change.',
      cancelLabel: 'Keep invite',
      confirmLabel: 'Cancel invite',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      (repository) => repository.cancelPartyInvite(member.membershipId),
    );
  }

  Future<void> _respond(OpenQueuePartyInvite invite, bool accept) async {
    if (_busy) return;
    if (accept) {
      // Accepting can leave an existing party, or disband it for everyone when
      // this player owns it. Re-read the server context before disclosure.
      if (!await _load() || !mounted) return;
      final previous = _data?.myParty;
      if (previous != null && previous.id != invite.partyId) {
        final confirmed = await showFieldConfirmDialog(
          context: context,
          icon: Icons.group_off_outlined,
          eyebrow: 'Switch parties',
          title: previous.isOwner
              ? 'Cancel your party and switch?'
              : 'Leave your party and switch?',
          message: previous.isOwner
              ? 'Joining ${invite.owner.displayName} will cancel your current party for all members and cancel its pending invitations.'
              : 'Joining ${invite.owner.displayName} means leaving your current party. You will be assigned with the new party instead.',
          detail: 'Everyone keeps their individual game booking.',
          cancelLabel: 'Keep current party',
          confirmLabel: 'Switch parties',
          destructive: true,
        );
        if (!confirmed || !mounted) return;
      }
    } else {
      final confirmed = await showFieldConfirmDialog(
        context: context,
        icon: Icons.group_off_outlined,
        eyebrow: 'Party invitation',
        title: 'Decline this invite?',
        message: '${invite.owner.displayName} invited you to play together.',
        detail: 'Your game booking will not change.',
        cancelLabel: 'Keep invite',
        confirmLabel: 'Decline invite',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    await _run(
      (repository) => repository.respondToPartyInvite(
        membershipId: invite.membershipId,
        accept: accept,
      ),
    );
  }

  TextStyle _text(
    double size, {
    Color color = FieldrushAuthTheme.muted,
    FontWeight weight = FontWeight.w700,
  }) => TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: size,
    color: color,
    fontWeight: weight,
    height: 1.35,
  );

  @override
  Widget build(BuildContext context) {
    if (_repository == null) return const SizedBox.shrink();
    final data = _data;
    final party = data?.myParty;
    final canChange = data?.canUseParties == true && !_busy;
    final members = party?.members ?? const <OpenQueuePartyMember>[];
    final maxSize = data?.maxPartySize ?? widget.game.maxPartySize ?? 4;
    final lock = data?.partyLockAt;
    final localLock = lock == null ? null : widget.game.localDateTime(lock);
    final cutoff = localLock == null
        ? null
        : '${localLock.hour % 12 == 0 ? 12 : localLock.hour % 12}:${localLock.minute.toString().padLeft(2, '0')} ${localLock.hour < 12 ? 'AM' : 'PM'}';
    return Container(
      key: const ValueKey('fieldrush-game-party'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: FieldrushAuthTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                party == null ? 'PLAY TOGETHER' : 'YOUR PARTY',
                style: _text(
                  11,
                  color: const Color(0xFF24472C),
                  weight: FontWeight.w800,
                ).copyWith(letterSpacing: 1.2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cutoff == null
                      ? 'Up to $maxSize players'
                      : 'Invites close $cutoff',
                  style: _text(10),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _error!,
                    style: _text(11, color: FieldrushAuthTheme.danger),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _load,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          if (data != null) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < maxSize; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: party == null && i == 0
                        ? _soloSlot()
                        : i < members.length
                        ? _slot(members[i], canChange && party?.isOwner == true)
                        : _emptySlot(
                            canChange && (party == null || party.isOwner),
                          ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(
              !data.canUseParties
                  ? 'Party changes are closed for this game. Your confirmed booking is unchanged.'
                  : party == null
                  ? 'Invite players already booked into this game. A party keeps you on the same team.'
                  : 'Your accepted party members will be assigned together. Pending invites reserve no game spots.',
              style: _text(11, weight: FontWeight.w600),
            ),
            if (party != null && canChange)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _leave,
                  child: Text(
                    party.isOwner ? 'Cancel party' : 'Leave party',
                    style: _text(11.5, color: FieldrushAuthTheme.danger),
                  ),
                ),
              ),
            for (final invite in data.receivedInvites)
              Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2EFE3),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${invite.owner.displayName} invited you',
                      style: _text(12, color: FieldrushAuthTheme.ink),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Join their party to be assigned together.',
                      style: _text(11, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: canChange
                                ? () => _respond(invite, true)
                                : null,
                            child: const Text('Accept'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: canChange
                              ? () => _respond(invite, false)
                              : null,
                          child: const Text('Decline'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }

  Widget _slot(OpenQueuePartyMember member, bool canManage) {
    final pending = member.status == OpenQueuePartyMemberStatus.invited;
    final isMe = member.profileId == widget.viewerProfileId;
    final initials = member.displayName
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part.characters.first)
        .join();
    return InkWell(
      onTap: pending && canManage ? () => _cancelInvite(member) : null,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFF2EFE3),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Text(
              member.isOwner
                  ? 'OWNER'
                  : pending
                  ? 'INVITED'
                  : 'IN',
              style: _text(
                8,
                color: pending
                    ? const Color(0xFF926B27)
                    : FieldrushAuthTheme.forest,
                weight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isMe ? FieldrushAuthTheme.forest : Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                initials.toUpperCase(),
                style: _text(
                  11,
                  color: isMe ? Colors.white : FieldrushAuthTheme.ink,
                  weight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              isMe ? 'You' : member.displayName.split(' ').first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _text(10, color: FieldrushAuthTheme.ink),
            ),
            const SizedBox(height: 4),
            Text(
              pending && canManage ? 'Tap to cancel' : member.role.code,
              style: _text(8),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptySlot(bool enabled) => InkWell(
    onTap: enabled ? _invite : null,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 3),
      decoration: BoxDecoration(
        border: Border.all(color: FieldrushAuthTheme.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Icon(
            enabled ? Icons.add_rounded : Icons.lock_outline_rounded,
            size: 30,
            color: FieldrushAuthTheme.muted,
          ),
          const SizedBox(height: 10),
          Text(enabled ? 'Invite' : 'Open', style: _text(10)),
          const SizedBox(height: 11),
        ],
      ),
    ),
  );

  Widget _soloSlot() => Container(
    padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 3),
    decoration: BoxDecoration(
      color: FieldrushAuthTheme.forest,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      children: [
        const SizedBox(height: 8),
        const Icon(Icons.person_outline_rounded, size: 30, color: Colors.white),
        const SizedBox(height: 10),
        Text('You', style: _text(10, color: Colors.white)),
        const SizedBox(height: 4),
        Text(
          widget.game.myBookingRole?.code ?? 'IN',
          style: _text(8, color: Colors.white70),
        ),
      ],
    ),
  );
}
