import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/field_loading.dart';

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
    this.onViewProfile,
  });
  final OpenQueueRepository repository;
  final OpenQueueGame game;
  final Future<void> Function() onChanged;
  final String? viewerProfileId;
  final Future<void> Function(String profileId)? onViewProfile;
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
      game: widget.game,
      onViewProfile: widget.onViewProfile,
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
    final owner = members.where((member) => member.isOwner).firstOrNull;
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
                party == null || party.isOwner || owner == null
                    ? 'YOUR PARTY'
                    : '${owner.displayName.split(' ').first.toUpperCase()}’S PARTY',
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
            const FieldLoadingContent(
              label: 'Loading party',
              rows: 2,
              compact: true,
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
                            canChange &&
                                data.eligiblePlayers.isNotEmpty &&
                                (party == null || party.isOwner),
                          ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    !data.canUseParties
                        ? 'Party changes are closed. You’re still in the game.'
                        : party != null && !party.isOwner
                        ? 'Only the party lead can invite.'
                        : members.length >= maxSize
                        ? 'Party full. Pending invites reserve no game spots.'
                        : 'Kept on the same side when teams are drawn.',
                    style: _text(11, weight: FontWeight.w600),
                  ),
                ),
                if (party != null && canChange) ...[
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _leave,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: FieldrushAuthTheme.danger,
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 15),
                      side: const BorderSide(color: FieldrushAuthTheme.border),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(
                      party.isOwner ? 'Cancel party' : 'Leave party',
                      style: _text(
                        11.5,
                        color: FieldrushAuthTheme.danger,
                        weight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            for (final invite in data.receivedInvites)
              Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: FieldrushAuthTheme.cream,
                  border: Border.all(color: FieldrushAuthTheme.border),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _avatar(
                          invite.owner.displayName,
                          invite.owner.avatarUrl,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${invite.owner.displayName} invited you',
                                style: _text(13, color: FieldrushAuthTheme.ink),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'PARTY INVITE',
                                style: _text(
                                  9,
                                  color: FieldrushAuthTheme.forest,
                                  weight: FontWeight.w800,
                                ).copyWith(letterSpacing: .8),
                              ),
                            ],
                          ),
                        ),
                      ],
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
                            style: FilledButton.styleFrom(
                              backgroundColor: FieldrushAuthTheme.forest,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(44),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              textStyle: _text(
                                12,
                                color: Colors.white,
                                weight: FontWeight.w800,
                              ),
                            ),
                            child: const Text('Accept'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: canChange
                              ? () => _respond(invite, false)
                              : null,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            side: const BorderSide(
                              color: FieldrushAuthTheme.border,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            backgroundColor: Colors.white,
                            foregroundColor: FieldrushAuthTheme.ink,
                            textStyle: _text(
                              12,
                              color: FieldrushAuthTheme.ink,
                              weight: FontWeight.w800,
                            ),
                          ),
                          child: const Text('Decline'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
          if (_busy)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                liveRegion: true,
                child: const Text('Updating party…'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _slot(OpenQueuePartyMember member, bool canManage) {
    final pending = member.status == OpenQueuePartyMemberStatus.invited;
    final isMe = member.profileId == widget.viewerProfileId;
    final foreground = isMe ? Colors.white : FieldrushAuthTheme.ink;
    return InkWell(
      key: ValueKey('fieldrush-party-member-${member.membershipId}'),
      onTap: pending && canManage
          ? () => _cancelInvite(member)
          : !pending && widget.onViewProfile != null
          ? () => widget.onViewProfile!(member.profileId)
          : null,
      borderRadius: BorderRadius.circular(16),
      child: _PartySlotSurface(
        dashed: pending,
        borderColor: FieldrushAuthTheme.forest,
        color: pending
            ? Colors.white
            : isMe
            ? FieldrushAuthTheme.forest
            : FieldrushAuthTheme.watermark,
        child: SizedBox(
          width: double.infinity,
          child: Stack(
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            children: [
              Column(
                children: [
                  _avatar(
                    member.displayName,
                    member.avatarUrl,
                    isMe: isMe,
                    pending: pending,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isMe ? 'You' : member.displayName.split(' ').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _text(
                      11.5,
                      color: foreground,
                      weight: FontWeight.w800,
                    ).copyWith(height: 1.1),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    pending ? 'Pending' : _roleWord(member.role),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _text(
                      9.5,
                      color: pending
                          ? FieldrushAuthTheme.forest
                          : isMe
                          ? Colors.white.withValues(alpha: .8)
                          : FieldrushAuthTheme.muted,
                    ).copyWith(height: 1, letterSpacing: .285),
                  ),
                ],
              ),
              if (member.isOwner && (_data?.myParty?.acceptedCount ?? 0) > 1)
                Positioned(
                  top: -8,
                  right: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: isMe
                          ? Colors.white.withValues(alpha: .2)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'LEAD',
                      style: _text(
                        7.5,
                        color: isMe ? Colors.white : const Color(0xFF24472C),
                        weight: FontWeight.w800,
                      ).copyWith(height: 1, letterSpacing: .75),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptySlot(bool enabled) => InkWell(
    key: const ValueKey('fieldrush-party-empty-slot'),
    onTap: enabled ? _invite : null,
    borderRadius: BorderRadius.circular(16),
    child: _PartySlotSurface(
      dashed: true,
      borderColor: enabled ? const Color(0xFF9DBB9A) : const Color(0xFFE1DACA),
      color: enabled ? Colors.white : const Color(0xFFFBFAF4),
      child: Column(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled
                  ? const Color(0xFFEFF6E4)
                  : FieldrushAuthTheme.watermark,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.add_rounded,
              size: 26,
              color: enabled
                  ? FieldrushAuthTheme.forest
                  : const Color(0xFFB5AE98),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            enabled ? 'Invite' : 'Open',
            style: _text(
              11.5,
              weight: FontWeight.w800,
              color: enabled
                  ? FieldrushAuthTheme.forest
                  : const Color(0xFFA9A490),
            ).copyWith(height: 1.1),
          ),
          const SizedBox(height: 6),
          Text(
            '·',
            style: _text(9.5, color: Colors.transparent).copyWith(height: 1),
          ),
        ],
      ),
    ),
  );

  Widget _soloSlot() => _PartySlotSurface(
    color: FieldrushAuthTheme.forest,
    child: Column(
      children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .18),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Text(
            'YOU',
            style: _text(
              9,
              color: Colors.white,
              weight: FontWeight.w800,
            ).copyWith(height: 1, letterSpacing: .54),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'You',
          style: _text(
            11.5,
            color: Colors.white,
            weight: FontWeight.w800,
          ).copyWith(height: 1.1),
        ),
        const SizedBox(height: 6),
        Text(
          widget.game.myBookingRole == null
              ? 'Booked'
              : _roleWord(widget.game.myBookingRole!),
          style: _text(
            9.5,
            color: Colors.white.withValues(alpha: .8),
          ).copyWith(height: 1, letterSpacing: .285),
        ),
      ],
    ),
  );

  String _roleWord(OpenQueueRole role) => switch (role) {
    OpenQueueRole.goalkeeper => 'Keeper',
    OpenQueueRole.defender => 'Defender',
    OpenQueueRole.attacker => 'Attacker',
    OpenQueueRole.midfielder => 'Midfielder',
  };

  Widget _avatar(
    String name,
    String? avatarUrl, {
    bool isMe = false,
    bool pending = false,
  }) {
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part.characters.first)
        .join()
        .toUpperCase();
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isMe
            ? Colors.white.withValues(alpha: .18)
            : pending
            ? const Color(0xFFEFF6E4)
            : Colors.white,
        borderRadius: BorderRadius.circular(13),
      ),
      clipBehavior: Clip.antiAlias,
      child: avatarUrl == null
          ? Text(
              isMe
                  ? 'YOU'
                  : initials.isEmpty
                  ? 'F'
                  : initials,
              style: TextStyle(
                fontFamily: isMe ? 'PlusJakartaSans' : 'Outfit',
                fontSize: isMe ? 9 : 13,
                fontWeight: FontWeight.w800,
                color: isMe ? Colors.white : const Color(0xFF3C4A38),
              ),
            )
          : Image.network(
              avatarUrl,
              width: 38,
              height: 38,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Text(
                isMe
                    ? 'YOU'
                    : initials.isEmpty
                    ? 'F'
                    : initials,
                style: _text(
                  13,
                  color: isMe ? Colors.white : FieldrushAuthTheme.ink,
                ),
              ),
            ),
    );
  }
}

class _PartySlotSurface extends StatelessWidget {
  const _PartySlotSurface({
    required this.color,
    required this.child,
    this.dashed = false,
    this.borderColor = FieldrushAuthTheme.border,
  });
  final Color color;
  final Widget child;
  final bool dashed;
  final Color borderColor;
  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: dashed ? _PartySlotDashPainter(borderColor) : null,
    child: Container(
      constraints: const BoxConstraints(minHeight: 100),
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 11),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.topCenter,
      child: child,
    ),
  );
}

class _PartySlotDashPainter extends CustomPainter {
  const _PartySlotDashPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.75),
          const Radius.circular(16),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (var offset = 0.0; offset < metric.length; offset += 8) {
        canvas.drawPath(
          metric.extractPath(offset, (offset + 4).clamp(0, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PartySlotDashPainter oldDelegate) =>
      oldDelegate.color != color;
}
