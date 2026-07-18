import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import 'fixture_reliability_roster.dart';

class FixtureReliabilityRosterCard extends StatelessWidget {
  const FixtureReliabilityRosterCard({
    super.key,
    required this.roster,
    required this.onOpen,
  });

  final FixtureReliabilityRoster roster;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final selected = roster.selectedMembers;
    final names = selected
        .take(2)
        .map((member) => member.displayName)
        .join(', ');
    final extra = selected.length - 2;
    final summary = selected.isEmpty
        ? 'No players confirmed yet'
        : '$names${extra > 0 ? ' +$extra' : ''}';
    final needsAttention = !roster.isComplete;

    return Material(
      key: const ValueKey('fixture-reliability-roster-card'),
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: needsAttention ? const Color(0xFFF5D48A) : fieldGray200,
            ),
            boxShadow: [
              BoxShadow(
                color: fieldGray900.withValues(alpha: 0.05),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: needsAttention
                          ? const Color(0xFFFFF7E2)
                          : fieldEmerald50,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      needsAttention
                          ? Icons.groups_2_outlined
                          : Icons.task_alt_rounded,
                      color: needsAttention
                          ? const Color(0xFFB66800)
                          : fieldEmerald600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PLANNED MATCHDAY ROSTER',
                          style: TextStyle(
                            color: fieldGray500,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          roster.isComplete
                              ? '${roster.requiredCount} players confirmed'
                              : '${roster.remainingCount} ${roster.remainingCount == 1 ? 'player' : 'players'} still needed',
                          style: const TextStyle(
                            color: fieldGray900,
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _RosterCountPill(roster: roster),
                ],
              ),
              const SizedBox(height: 15),
              Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray700,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                roster.isLocked
                    ? 'Planned roster locked. The referee still records final attendance.'
                    : 'Plan who expects to play. The referee records actual attendance at the venue. Locks ${_rosterLockLabel(roster.locksAt)}.',
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    roster.canEdit ? 'Edit roster' : 'View roster',
                    style: const TextStyle(
                      color: fieldEmerald700,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: fieldEmerald700,
                    size: 18,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FixtureReliabilityRosterLoadingCard extends StatelessWidget {
  const FixtureReliabilityRosterLoadingCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('fixture-reliability-roster-loading'),
      height: 124,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: fieldGray200),
      ),
      child: const Row(
        children: [
          SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: fieldEmerald600,
            ),
          ),
          SizedBox(width: 14),
          Expanded(
            child: Text(
              'Loading your matchday roster…',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fieldGray700,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FixtureReliabilityRosterErrorCard extends StatelessWidget {
  const FixtureReliabilityRosterErrorCard({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('fixture-reliability-roster-error'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF5D48A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.sync_problem_rounded, color: Color(0xFFB66800)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Roster unavailable',
                  style: TextStyle(
                    color: fieldGray900,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(color: fieldGray600, height: 1.35),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: fieldEmerald700,
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text(
                    'Try again',
                    style: TextStyle(fontWeight: FontWeight.w900),
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

Future<List<String>?> showFixtureReliabilityRosterSheet({
  required BuildContext context,
  required FixtureReliabilityRoster roster,
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _FixtureReliabilityRosterSheet(roster: roster),
  );
}

class _FixtureReliabilityRosterSheet extends StatefulWidget {
  const _FixtureReliabilityRosterSheet({required this.roster});

  final FixtureReliabilityRoster roster;

  @override
  State<_FixtureReliabilityRosterSheet> createState() =>
      _FixtureReliabilityRosterSheetState();
}

class _FixtureReliabilityRosterSheetState
    extends State<_FixtureReliabilityRosterSheet> {
  late final Set<String> _selected = {
    for (final member in widget.roster.selectedMembers) member.profileId,
  };
  String? _selectionHint;

  bool get _selectionIsValid {
    if (_selected.length != widget.roster.requiredCount) return false;
    return widget.roster.members
        .where((member) => _selected.contains(member.profileId))
        .every((member) => member.isEligible);
  }

  void _toggle(FixtureReliabilityRosterMember member) {
    if (!widget.roster.canEdit) return;
    if (_selected.contains(member.profileId)) {
      setState(() {
        _selected.remove(member.profileId);
        _selectionHint = null;
      });
      return;
    }
    if (!member.isEligible) return;
    if (_selected.length >= widget.roster.requiredCount) {
      setState(
        () => _selectionHint = 'Remove one player before adding another.',
      );
      return;
    }
    setState(() {
      _selected.add(member.profileId);
      _selectionHint = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final editable = widget.roster.canEdit;
    final members = editable
        ? widget.roster.members
        : widget.roster.selectedMembers;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 18 + bottomInset),
      decoration: const BoxDecoration(
        color: fieldBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 5,
            decoration: BoxDecoration(
              color: fieldGray300,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: fieldEmerald50,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.groups_2_rounded,
                  color: fieldEmerald600,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      editable ? 'Confirm matchday roster' : 'Matchday roster',
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      editable
                          ? 'Choose exactly ${widget.roster.requiredCount} planned players. The referee records final attendance and can add another eligible clan member at the venue.'
                          : 'These are the ${widget.roster.confirmedCount} planned players. Final attendance is recorded by the referee.',
                      style: const TextStyle(
                        color: fieldGray600,
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
                color: fieldGray600,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: fieldGray200),
            ),
            child: Row(
              children: [
                Icon(
                  widget.roster.isLocked
                      ? Icons.lock_rounded
                      : Icons.schedule_rounded,
                  size: 19,
                  color: fieldGray500,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    widget.roster.isLocked
                        ? 'Roster changes are now locked.'
                        : 'Changes lock ${_rosterLockLabel(widget.roster.locksAt)}.',
                    style: const TextStyle(
                      color: fieldGray700,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${_selected.length}/${widget.roster.requiredCount}',
                  style: const TextStyle(
                    color: fieldGray900,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (members.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Text(
                'No players have been confirmed yet.',
                style: TextStyle(
                  color: fieldGray500,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: members.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final member = members[index];
                  final selected = _selected.contains(member.profileId);
                  return _RosterMemberTile(
                    member: member,
                    selected: selected,
                    editable: editable,
                    onTap: () => _toggle(member),
                  );
                },
              ),
            ),
          if (_selectionHint != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _selectionHint!,
                style: const TextStyle(
                  color: Color(0xFFB66800),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: editable
                ? FilledButton(
                    key: const ValueKey('save-fixture-reliability-roster'),
                    onPressed: _selectionIsValid
                        ? () => Navigator.of(
                            context,
                          ).pop(_selected.toList(growable: false))
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: fieldEmerald600,
                      disabledBackgroundColor: fieldGray200,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(17),
                      ),
                    ),
                    child: Text(
                      _selected.length == widget.roster.requiredCount
                          ? 'Confirm ${widget.roster.requiredCount} players'
                          : 'Choose ${widget.roster.requiredCount - _selected.length} more',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  )
                : OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: fieldGray900,
                      side: const BorderSide(color: fieldGray300),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(17),
                      ),
                    ),
                    child: const Text(
                      'Done',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _RosterMemberTile extends StatelessWidget {
  const _RosterMemberTile({
    required this.member,
    required this.selected,
    required this.editable,
    required this.onTap,
  });

  final FixtureReliabilityRosterMember member;
  final bool selected;
  final bool editable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final canToggle = editable && (selected || member.isEligible);
    return Material(
      color: selected ? fieldEmerald50 : Colors.white,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        key: ValueKey('fixture-roster-member-${member.profileId}'),
        onTap: canToggle ? onTap : null,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: selected ? fieldEmerald200 : fieldGray200,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 21,
                backgroundColor: selected ? fieldEmerald600 : fieldGray100,
                child: Text(
                  member.initials,
                  style: TextStyle(
                    color: selected ? Colors.white : fieldGray700,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      member.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      member.unavailableReason ??
                          (member.username == null
                              ? _rosterRoleLabel(member.role)
                              : '@${member.username} · ${_rosterRoleLabel(member.role)}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: member.isEligible
                            ? fieldGray500
                            : const Color(0xFFB66800),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (editable || selected)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 27,
                  height: 27,
                  decoration: BoxDecoration(
                    color: selected ? fieldEmerald600 : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? fieldEmerald600 : fieldGray300,
                      width: 2,
                    ),
                  ),
                  child: selected
                      ? const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 18,
                        )
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RosterCountPill extends StatelessWidget {
  const _RosterCountPill({required this.roster});

  final FixtureReliabilityRoster roster;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: roster.isComplete ? fieldEmerald50 : const Color(0xFFFFF7E2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '${roster.confirmedCount}/${roster.requiredCount}',
        style: TextStyle(
          color: roster.isComplete ? fieldEmerald700 : const Color(0xFF9A5700),
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

String _rosterLockLabel(DateTime value) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final bahrainTime = value.toUtc().add(const Duration(hours: 3));
  final hour = bahrainTime.hour % 12 == 0 ? 12 : bahrainTime.hour % 12;
  final minute = bahrainTime.minute.toString().padLeft(2, '0');
  final period = bahrainTime.hour >= 12 ? 'PM' : 'AM';
  return '${weekdays[bahrainTime.weekday - 1]} at $hour:$minute $period Bahrain time';
}

String _rosterRoleLabel(String role) {
  return switch (role) {
    'owner' => 'Clan owner',
    'leader' => 'Clan leader',
    'former_member' => 'Former member',
    _ => 'Clan member',
  };
}
