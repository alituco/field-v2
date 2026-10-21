import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/field_confirmation_dialog.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture_repository.dart';
import '../moderation/moderation.dart';
import '../moderation/moderation_repository.dart';
import '../moderation/report_issue_sheet.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import '../ui/fieldrush_toast.dart';
import 'clan.dart';
import 'clan_reliability.dart';
import 'clan_repository.dart';
import 'customize_clan_screen.dart';
import 'fieldrush_clan_widgets.dart';

// Keep the clan reliability panel hidden for now.
const _clanReliabilityVisible = false;

class ClanDetailScreen extends StatefulWidget {
  const ClanDetailScreen({
    super.key,
    required this.clan,
    required this.clanRepository,
    required this.fixtureRepository,
    this.currentMembership,
    this.moderationRepository,
    this.embedded = false,
    this.onMembershipChanged,
    this.activationTick = 0,
  });
  final Clan clan;
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final ClanMembership? currentMembership;
  final ModerationRepository? moderationRepository;
  final bool embedded;
  final Future<void> Function()? onMembershipChanged;
  final int activationTick;
  @override
  State<ClanDetailScreen> createState() => _ClanDetailScreenState();
}

class _ClanDetailScreenState extends State<ClanDetailScreen> {
  late Clan _clan;
  ClanMembership? _membership;
  List<ClanMember> _members = [];
  List<ClanJoinRequest> _requests = [];
  ClanJoinRequest? _myRequest;
  ClanReliabilitySummary? _reliability;
  bool _loading = true,
      _reliabilityLoading = true,
      _reliabilityOpen = false,
      _working = false;
  String? _error, _reliabilityError, _workingRequest;
  int _generation = 0;
  String? get _profileId {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  bool get _mine => _membership?.clanId == _clan.id;
  bool get _manager => _mine && (_membership?.isManager ?? false);
  bool get _owner => _mine && (_membership?.isOwner ?? false);
  @override
  void initState() {
    super.initState();
    _clan = widget.clan;
    _membership = widget.currentMembership;
    _load();
  }

  @override
  void didUpdateWidget(covariant ClanDetailScreen old) {
    super.didUpdateWidget(old);
    if (widget.activationTick != old.activationTick) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (_clanReliabilityVisible) unawaited(_loadReliability());
    try {
      final results = await Future.wait<dynamic>([
        widget.clanRepository.getMyClanMembership(),
        widget.clanRepository.listClanMembers(_clan.id),
        widget.clanRepository.listClans(),
        widget.clanRepository.listPendingJoinRequests(_clan.id),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _membership = results[0] as ClanMembership?;
        _members = results[1] as List<ClanMember>;
        _clan =
            (results[2] as List<Clan>)
                .where((c) => c.id == _clan.id)
                .firstOrNull ??
            _clan;
        final requests = results[3] as List<ClanJoinRequest>;
        _requests = _manager ? requests : [];
        _myRequest = requests
            .where((r) => r.profileId == _profileId)
            .firstOrNull;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = userFacingError(
            error,
            fallback: 'Could not load this clan. Try again.',
          );
        });
      }
    }
  }

  Future<void> _loadReliability() async {
    final repository = widget.clanRepository;
    if (repository is! ClanReliabilityRepository) {
      if (mounted) setState(() => _reliabilityLoading = false);
      return;
    }
    try {
      final summary = await (repository as ClanReliabilityRepository)
          .getClanReliabilitySummary(_clan.id);
      if (summary.clanId.isNotEmpty && summary.clanId != _clan.id) {
        throw StateError('Clan reliability details do not match.');
      }
      if (mounted) {
        setState(() {
          _reliability = summary;
          _reliabilityLoading = false;
          _reliabilityError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _reliabilityLoading = false;
          _reliabilityError = userFacingError(
            error,
            fallback: 'Reliability unavailable',
          );
        });
      }
    }
  }

  void _showError(Object error) => showFieldrushToast(
    context,
    userFacingError(
      error,
      fallback: 'Could not complete that action. Try again.',
    ),
  );
  Future<bool> _confirm(
    String title,
    String message,
    String label, {
    bool destructive = false,
  }) => showFieldConfirmDialog(
    context: context,
    title: title,
    message: message,
    confirmLabel: label,
    cancelLabel: 'Cancel',
    destructive: destructive,
    icon: destructive ? Icons.warning_amber_rounded : Icons.shield_outlined,
    eyebrow: 'Clan action',
  );
  Future<void> _join() async {
    if (_working || _membership != null || _loading) return;
    final previous = _myRequest;
    if (previous != null &&
        !await _confirm(
          'Cancel join request?',
          '${_clan.name} will no longer see your request.',
          'Cancel request',
          destructive: true,
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _working = true);
    try {
      if (previous == null) {
        await widget.clanRepository.requestToJoinClan(_clan.id);
      } else {
        await widget.clanRepository.cancelJoinRequest(previous.id);
      }
      await _load();
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _review(
    ClanJoinRequest request,
    bool approve,
    StateSetter updateSheet,
    BuildContext sheetContext,
  ) async {
    if (_workingRequest != null) return;
    setState(() => _workingRequest = request.id);
    updateSheet(() {});
    try {
      await widget.clanRepository.reviewJoinRequest(
        requestId: request.id,
        approve: approve,
      );
      await _load();
      await widget.onMembershipChanged?.call();
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) {
        setState(() => _workingRequest = null);
        if (sheetContext.mounted) updateSheet(() {});
      }
    }
  }

  Future<void> _openRequests() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Theme(
          data: FieldrushAuthTheme.theme(context),
          child: Scaffold(
            backgroundColor: FieldrushAuthTheme.cream,
            body: SafeArea(
              child: StatefulBuilder(
                builder: (context, update) => Column(
                  children: [
                    const FieldrushClanHeader(
                      title: 'Join requests',
                      back: true,
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
                        children: [
                          if (_requests.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 24,
                              ),
                              child: Text(
                                'No requests yet. Players can find your clan in Browse and ask to join.',
                                textAlign: TextAlign.center,
                                style: clanText(
                                  12.5,
                                  color: FieldrushAuthTheme.muted,
                                  height: 1.5,
                                ),
                              ),
                            )
                          else
                            FieldrushClanCard(
                              child: Column(
                                children: [
                                  for (var i = 0; i < _requests.length; i++)
                                    _requestRow(
                                      _requests[i],
                                      i > 0,
                                      update,
                                      context,
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _requestRow(
    ClanJoinRequest request,
    bool divider,
    StateSetter update,
    BuildContext sheetContext,
  ) => Container(
    decoration: BoxDecoration(
      border: divider
          ? const Border(top: BorderSide(color: Color(0xFFF0ECE0)))
          : null,
    ),
    padding: const EdgeInsets.all(14),
    child: Column(
      children: [
        Row(
          children: [
            FieldrushClanCrest(tag: request.initials, size: 36),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(request.displayName, style: clanText(13.5)),
                  const SizedBox(height: 4),
                  Text(
                    '@${request.username ?? 'player'}',
                    style: clanText(10.5, color: FieldrushAuthTheme.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: ValueKey('clan-decline-${request.id}'),
                onPressed: _workingRequest != null
                    ? null
                    : () => _review(request, false, update, sheetContext),
                style: clanButtonStyle(outlined: true, height: 36),
                child: const Text('Decline'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                key: ValueKey('clan-approve-${request.id}'),
                onPressed: _workingRequest != null
                    ? null
                    : () => _review(request, true, update, sheetContext),
                style: clanButtonStyle(height: 36),
                child: Text(
                  _workingRequest == request.id ? 'Updating…' : 'Accept',
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  Future<void> _openPlayer(ClanMember member) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: FieldrushAuthTheme.cream,
            body: ProfileScreen(
              profileId: member.profileId,
              profileRepository: SupabaseProfileRepository(),
              clanRepository: widget.clanRepository,
              fixtureRepository: widget.fixtureRepository,
              moderationRepository: widget.moderationRepository,
            ),
          ),
        ),
      );
  Future<void> _showMemberActions(ClanMember member) async {
    if (_working || !_manager || member.isOwner) return;
    final action = await showFieldrushModal<String>(
      context: context,
      builder: (sheetContext) => FieldrushModal(
        key: ValueKey('clan-member-actions-${member.profileId}'),
        title: 'Manage ${member.displayName}',
        description: 'Member of ${_clan.name}',
        actions: [
          if (_owner)
            OutlinedButton(
              key: const ValueKey('clan-member-action-role'),
              onPressed: () => Navigator.of(
                sheetContext,
              ).pop(member.isLeader ? 'demote' : 'promote'),
              style: FieldrushModal.secondaryButtonStyle(),
              child: Text(
                member.isLeader ? 'Remove captain role' : 'Make captain',
              ),
            ),
          if (_owner)
            OutlinedButton(
              key: const ValueKey('clan-member-action-transfer'),
              onPressed: () => Navigator.of(sheetContext).pop('transfer'),
              style: FieldrushModal.secondaryButtonStyle(),
              child: const Text('Transfer ownership'),
            ),
          if (_owner || !member.isLeader)
            OutlinedButton(
              key: const ValueKey('clan-member-action-remove'),
              onPressed: () => Navigator.of(sheetContext).pop('remove'),
              style: FieldrushModal.secondaryButtonStyle(destructive: true),
              child: const Text('Remove from clan'),
            ),
          OutlinedButton(
            onPressed: () => Navigator.of(sheetContext).pop(),
            style: FieldrushModal.secondaryButtonStyle(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (action != null && mounted) await _memberAction(member, action);
  }

  Future<void> _memberAction(ClanMember member, String action) async {
    if (_working) return;
    if ((action == 'remove' || action == 'transfer') &&
        !await _confirm(
          action == 'remove'
              ? 'Remove ${member.displayName}?'
              : 'Transfer ownership?',
          action == 'remove'
              ? 'They will lose access to this clan.'
              : '${member.displayName} will become the captain. You will stay as a leader.',
          action == 'remove' ? 'Remove' : 'Transfer',
          destructive: action == 'remove',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _working = true);
    try {
      switch (action) {
        case 'remove':
          await widget.clanRepository.kickClanMember(
            clanId: _clan.id,
            profileId: member.profileId,
          );
        case 'transfer':
          await widget.clanRepository.transferClanOwnership(
            clanId: _clan.id,
            newOwnerProfileId: member.profileId,
          );
        default:
          await widget.clanRepository.setClanMemberLeader(
            clanId: _clan.id,
            profileId: member.profileId,
            makeLeader: action == 'promote',
          );
      }
      await _load();
      await widget.onMembershipChanged?.call();
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _leave({bool archive = false}) async {
    if (_working) return;
    final successor = _members
        .where((m) => m.profileId != _profileId)
        .firstOrNull;
    final message = archive
        ? 'This clan will be archived. Existing game and payment records are kept.'
        : _owner
        ? successor == null
              ? 'A clan needs a captain. Archive it instead, or add another member before leaving.'
              : '${successor.displayName} will become the captain.'
        : 'You will leave this clan.';
    if (!await _confirm(
      archive ? 'Archive ${_clan.name}?' : 'Leave ${_clan.name}?',
      message,
      archive ? 'Archive clan' : 'Leave clan',
      destructive: true,
    )) {
      return;
    }
    if (!mounted || (!archive && _owner && successor == null)) return;
    setState(() => _working = true);
    try {
      if (archive) {
        await widget.clanRepository.archiveClan(_clan.id);
      } else {
        await widget.clanRepository.leaveClan(_clan.id);
      }
      if (widget.embedded) {
        await widget.onMembershipChanged?.call();
      } else if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _edit() async {
    final clan = await Navigator.of(context).push<Clan>(
      MaterialPageRoute(
        builder: (_) => CustomizeClanScreen(
          clan: _clan,
          clanRepository: widget.clanRepository,
        ),
      ),
    );
    if (mounted && clan != null) {
      setState(() => _clan = clan);
      await widget.onMembershipChanged?.call();
    }
  }

  Future<void> _report() async {
    await showReportIssueSheet(
      context: context,
      repository: widget.moderationRepository ?? SupabaseModerationRepository(),
      subjectType: ModerationSubjectType.clan,
      subjectId: _clan.id,
      subjectName: _clan.name,
    );
  }

  Widget _menu() => SizedBox(
    width: 34,
    height: 34,
    child: PopupMenuButton<String>(
      key: const ValueKey('clan-options-menu'),
      padding: EdgeInsets.zero,
      tooltip: 'Clan options',
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 220),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: FieldrushAuthTheme.border),
      ),
      onSelected: (action) {
        if (action == 'edit') {
          _edit();
        } else if (action == 'archive') {
          _leave(archive: true);
        } else {
          _report();
        }
      },
      itemBuilder: (_) => [
        if (_manager) _menuAction('edit', 'Edit clan', Icons.edit_outlined),
        if (_owner)
          _menuAction('archive', 'Archive clan', Icons.archive_outlined),
        if (_manager || _owner) const PopupMenuDivider(height: 9),
        _menuAction('report', 'Report clan', Icons.flag_outlined, danger: true),
      ],
      icon: const Icon(Icons.more_horiz, color: FieldrushAuthTheme.muted),
    ),
  );

  PopupMenuItem<String> _menuAction(
    String value,
    String label,
    IconData icon, {
    bool danger = false,
  }) {
    final color = danger
        ? FieldrushAuthTheme.danger
        : FieldrushAuthTheme.forest;
    return PopupMenuItem<String>(
      value: value,
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: clanText(
              12.5,
              weight: FontWeight.w800,
              color: danger ? color : FieldrushAuthTheme.ink,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      body: SafeArea(
        top: !widget.embedded,
        bottom: false,
        child: Column(
          children: [
            if (!widget.embedded)
              FieldrushClanHeader(
                title: _clan.name,
                back: true,
                action: _menu(),
              ),
            Expanded(
              child: FieldRefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    16,
                    16,
                    widget.embedded ? 132 : 40,
                  ),
                  children: [
                    _identity(),
                    const SizedBox(height: 12),
                    const ClanGamesComingSoon(),
                    if (_clanReliabilityVisible &&
                        widget.clanRepository is ClanReliabilityRepository) ...[
                      const SizedBox(height: 12),
                      _reliabilityCard(),
                    ],
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _mine
                                ? 'MEMBERS · ${_members.isEmpty ? _clan.memberCount : _members.length}'
                                : 'TOP RATED',
                            style: clanText(
                              11,
                              weight: FontWeight.w800,
                              color: FieldrushAuthTheme.muted,
                            ).copyWith(letterSpacing: 1.54),
                          ),
                        ),
                        if (widget.embedded) _menu(),
                      ],
                    ),
                    const SizedBox(height: 11),
                    if (_loading)
                      const FieldLoadingContent(
                        label: 'Loading clan members',
                        rows: 3,
                      )
                    else if (_error != null)
                      FieldrushClanCard(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Text(
                              _error!,
                              style: clanText(
                                12,
                                color: FieldrushAuthTheme.danger,
                              ),
                            ),
                            TextButton(
                              onPressed: _load,
                              child: const Text('Try again'),
                            ),
                          ],
                        ),
                      )
                    else if (_members.isNotEmpty)
                      _memberList()
                    else
                      FieldrushClanCard(
                        padding: const EdgeInsets.all(18),
                        child: Text(
                          'No members to show yet.',
                          style: clanText(12, color: FieldrushAuthTheme.muted),
                        ),
                      ),
                    if (_manager) ...[
                      const SizedBox(height: 12),
                      FieldrushClanCard(
                        child: InkWell(
                          key: const ValueKey('clan-join-requests'),
                          onTap: _openRequests,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 16,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Join requests',
                                    style: clanText(13.5),
                                  ),
                                ),
                                Text(
                                  '${_requests.length}',
                                  style: clanText(
                                    12,
                                    color: FieldrushAuthTheme.forest,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: FieldrushAuthTheme.muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_mine) ...[
                      const SizedBox(height: 14),
                      OutlinedButton(
                        key: const ValueKey('clan-leave'),
                        onPressed: _working ? null : _leave,
                        style: clanButtonStyle(outlined: true, danger: true),
                        child: const Text('Leave clan'),
                      ),
                    ] else if (_membership == null) ...[
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const ValueKey('clan-request-join'),
                        onPressed: _working || _loading || _error != null
                            ? null
                            : _join,
                        style: clanButtonStyle(height: 50),
                        child: Text(
                          _working
                              ? 'Updating…'
                              : _myRequest == null
                              ? 'Request to join'
                              : 'Cancel join request',
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 16),
                      Text(
                        'You’re already in a clan.',
                        textAlign: TextAlign.center,
                        style: clanText(12, color: FieldrushAuthTheme.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _identity() {
    if (widget.embedded) {
      return FieldrushClanCard(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            FieldrushClanCrest(tag: _clan.tag, themeId: _clan.themeId),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _clan.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: clanTitle(18),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_clan.memberCount} ${_clan.memberCount == 1 ? 'member' : 'members'} · ${_owner
                        ? 'you’re the captain'
                        : _manager
                        ? 'you’re a captain'
                        : '${_members.where((m) => m.isOwner).firstOrNull?.displayName ?? 'Your captain'} is captain'}',
                    style: clanText(
                      11.5,
                      weight: FontWeight.w600,
                      color: FieldrushAuthTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 19),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A6A43), Color(0xFF26492F)],
        ),
      ),
      child: Row(
        children: [
          FieldrushClanCrest(tag: _clan.tag, size: 58, soft: true),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CLAN',
                  style: clanText(
                    9.5,
                    weight: FontWeight.w800,
                    color: const Color(0xFFC7DD9B),
                  ).copyWith(letterSpacing: 1.71),
                ),
                const SizedBox(height: 9),
                Text(_clan.name, style: clanTitle(19, color: Colors.white)),
                const SizedBox(height: 7),
                Text(
                  '${_clan.memberCount} members${_clan.cityName == null ? '' : ' · ${_clan.cityName}'}',
                  style: clanText(11, color: const Color(0xFFE4F0D5)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _memberList() {
    final members = _mine
        ? _members
        : ([..._members]..sort((a, b) {
                final rating = (b.skillRating ?? -1).compareTo(
                  a.skillRating ?? -1,
                );
                return rating != 0
                    ? rating
                    : a.displayName.compareTo(b.displayName);
              }))
              .take(3)
              .toList();
    return FieldrushClanCard(
      child: Column(
        children: [
          for (var i = 0; i < members.length; i++)
            _memberRow(members[i], i > 0),
        ],
      ),
    );
  }

  Widget _memberRow(ClanMember member, bool divider) {
    final me = member.profileId == _profileId;
    final placed = member.ratingVisible;
    final meta = [
      if (member.username != null) '@${member.username}',
      placed ? divisionFromRating(member.skillRating!).label : 'Placement',
    ].join(' · ');
    return Container(
      decoration: BoxDecoration(
        border: divider
            ? const Border(top: BorderSide(color: Color(0xFFF0ECE0)))
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: ValueKey('clan-member-${member.profileId}'),
              onTap: () => _openPlayer(member),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: me
                          ? FieldrushAuthTheme.forest
                          : const Color(0xFFF2EFE3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: member.avatarUrl == null
                        ? Text(
                            me ? 'YOU' : member.initials,
                            style: clanTitle(
                              me ? 10 : 13,
                              color: me
                                  ? Colors.white
                                  : const Color(0xFF3C4A38),
                            ),
                          )
                        : Image.network(
                            member.avatarUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Center(
                              child: Text(
                                member.initials,
                                style: clanTitle(
                                  13,
                                  color: const Color(0xFF3C4A38),
                                ),
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                member.displayName,
                                style: clanText(13.5),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (member.isManager) ...[
                              const SizedBox(width: 7),
                              Text(
                                'CAPTAIN',
                                style: clanText(
                                  8,
                                  weight: FontWeight.w800,
                                  color: FieldrushAuthTheme.forest,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          meta,
                          style: clanText(
                            10.5,
                            weight: FontWeight.w600,
                            color: FieldrushAuthTheme.muted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_manager && !member.isOwner && !me)
            IconButton(
              tooltip: 'Manage ${member.displayName}',
              onPressed: _working ? null : () => _showMemberActions(member),
              icon: const Icon(
                Icons.more_horiz,
                size: 20,
                color: FieldrushAuthTheme.muted,
              ),
            )
          else if (!_mine)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                placed ? '${member.skillRating}' : '????',
                style: clanTitle(13),
              ),
            ),
        ],
      ),
    );
  }

  String _date(DateTime date) =>
      '${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][date.month - 1]} ${date.day}, ${date.year}';

  Widget _reliabilityCard() {
    final summary = _reliability;
    return FieldrushClanCard(
      key: const ValueKey('clan-reliability-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('clan-reliability-toggle'),
            onTap: () => setState(() => _reliabilityOpen = !_reliabilityOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              child: Row(
                children: [
                  Expanded(child: Text('Reliability', style: clanText(12.5))),
                  if (_reliabilityLoading)
                    const SizedBox(
                      width: 65,
                      height: 12,
                      child: FieldSkeleton(),
                    )
                  else
                    Text(
                      summary == null
                          ? 'Unavailable'
                          : '${summary.activeStrikes} ACTIVE',
                      key: const ValueKey('clan-active-strikes'),
                      style: clanText(
                        10.5,
                        color: summary != null && summary.activeStrikes > 0
                            ? FieldrushAuthTheme.danger
                            : FieldrushAuthTheme.muted,
                      ),
                    ),
                  const SizedBox(width: 8),
                  Icon(
                    _reliabilityOpen ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: FieldrushAuthTheme.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_reliabilityError != null)
            Padding(
              key: const ValueKey('clan-reliability-error'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reliability unavailable',
                    style: clanText(12, color: FieldrushAuthTheme.danger),
                  ),
                  TextButton(
                    key: const ValueKey('retry-clan-reliability'),
                    onPressed: _loadReliability,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          if (_reliabilityOpen && summary != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 15),
              child: summary.isMember
                  ? Column(
                      key: const ValueKey('clan-reliability-private-history'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (summary.consequenceSummary.depositRequired)
                          Text(
                            'Deposit required',
                            style: clanText(
                              12,
                              color: FieldrushAuthTheme.danger,
                            ),
                          ),
                        if (summary.consequenceSummary.activeSanctionCount > 0)
                          Text(
                            '${summary.consequenceSummary.activeSanctionCount} active sanction${summary.consequenceSummary.activeSanctionCount == 1 ? '' : 's'}',
                            style: clanText(
                              11.5,
                              color: FieldrushAuthTheme.muted,
                            ),
                          ),
                        for (final incident in summary.incidents)
                          Padding(
                            key: ValueKey(
                              'clan-reliability-incident-${incident.id}',
                            ),
                            padding: const EdgeInsets.only(top: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  incident.outcomeLabel,
                                  style: clanText(
                                    12.5,
                                    weight: FontWeight.w800,
                                  ),
                                ),
                                if (incident.reason?.isNotEmpty == true)
                                  Text(
                                    incident.reason!,
                                    style: clanText(
                                      11.5,
                                      color: FieldrushAuthTheme.muted,
                                      height: 1.5,
                                    ),
                                  ),
                                Text(
                                  '${incident.strikeDelta} strikes${incident.expiresAt == null ? '' : ' · Expires ${_date(incident.expiresAt!)}'}',
                                  style: clanText(
                                    10.5,
                                    color: FieldrushAuthTheme.muted,
                                    height: 1.5,
                                  ),
                                ),
                                if (incident.issuerLabel != null)
                                  Text(
                                    'Issued by ${incident.issuerLabel}',
                                    style: clanText(
                                      10.5,
                                      color: FieldrushAuthTheme.muted,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        if (summary.incidents.isEmpty)
                          Text(
                            'No reliability incidents.',
                            style: clanText(
                              11.5,
                              color: FieldrushAuthTheme.muted,
                            ),
                          ),
                      ],
                    )
                  : Text(
                      'Only clan members can see the incident history.',
                      key: const ValueKey('clan-reliability-private-note'),
                      style: clanText(
                        11.5,
                        color: FieldrushAuthTheme.muted,
                        height: 1.5,
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
