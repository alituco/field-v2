import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/field_confirmation_dialog.dart';
import '../core/user_facing_error.dart';
import '../fixtures/create_fixture_screen.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_detail_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../moderation/moderation.dart';
import '../moderation/moderation_repository.dart';
import '../moderation/report_issue_sheet.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import 'clan.dart';
import 'clan_repository.dart';
import 'clan_widgets.dart';
import 'customize_clan_screen.dart';

enum _MemberAction { makeLeader, removeLeader, transferOwnership, remove }

enum _ClanHeaderAction { edit, archive, report }

class ClanDetailScreen extends StatefulWidget {
  const ClanDetailScreen({
    super.key,
    required this.clan,
    required this.clanRepository,
    required this.fixtureRepository,
    this.currentMembership,
    this.moderationRepository,
  });

  final Clan clan;
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final ClanMembership? currentMembership;
  final ModerationRepository? moderationRepository;

  @override
  State<ClanDetailScreen> createState() => _ClanDetailScreenState();
}

class _ClanDetailScreenState extends State<ClanDetailScreen> {
  final ProfileRepository _profileRepository = SupabaseProfileRepository();
  late final ModerationRepository _moderationRepository;
  int _tabIndex = 0;
  late Clan _clan;
  List<ClanMember> _members = const [];
  List<ClanJoinRequest> _pendingRequests = const [];
  List<Fixture> _fixtures = const [];
  ClanMembership? _currentMembership;
  ClanJoinRequest? _myJoinRequest;
  bool _isLoadingMembers = true;
  bool _isLoadingRequests = true;
  bool _isSubmittingJoinRequest = false;
  bool _isArchiving = false;
  String? _activeMemberAction;
  String? _activeJoinRequest;
  String? _membersErrorText;

  Clan get clan => _clan;

  bool get _isCurrentClan => _currentMembership?.clanId == clan.id;

  bool get _hasClan => _currentMembership != null;

  bool get _isOwner => _isCurrentClan && (_currentMembership?.isOwner ?? false);

  bool get _canManageClan =>
      _isCurrentClan && (_currentMembership?.isManager ?? false);

  String? get _currentUserId => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _clan = widget.clan;
    _currentMembership = widget.currentMembership;
    _moderationRepository =
        widget.moderationRepository ?? SupabaseModerationRepository();
    _loadClanData();
  }

  Future<void> _openCustomize() async {
    final updated = await Navigator.of(context).push<Clan>(
      MaterialPageRoute(
        builder: (context) => CustomizeClanScreen(
          clan: clan,
          clanRepository: widget.clanRepository,
        ),
      ),
    );
    if (updated == null || !mounted) return;
    setState(() => _clan = updated);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Clan identity updated.')));
  }

  Future<void> _openMemberProfile(ClanMember member) async {
    if (member.profileId.trim().isEmpty) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: fieldBackground,
          body: ProfileScreen(
            profileRepository: _profileRepository,
            clanRepository: widget.clanRepository,
            fixtureRepository: widget.fixtureRepository,
            moderationRepository: _moderationRepository,
            profileId: member.profileId,
          ),
        ),
      ),
    );
  }

  Future<void> _openFixtureFlow() async {
    if (!_canManageClan) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            !_hasClan
                ? 'Clan join requests are coming next.'
                : 'Only clan owners and leaders can schedule matches.',
          ),
        ),
      );
      return;
    }

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => CreateFixtureScreen(
          fixtureRepository: widget.fixtureRepository,
          myClanMembership: MyClanMembership(
            clan: FixtureClan(
              id: clan.id,
              name: clan.name,
              tag: clan.tag,
              emblem: clan.emblem,
              themeId: clan.themeId,
              patternId: clan.patternId,
              skillRating: clan.skillRating,
            ),
            role: _currentMembership?.clanId == clan.id
                ? _currentMembership!.role
                : 'owner',
          ),
        ),
      ),
    );

    if (changed == true && mounted) {
      await _loadClanData();
    }
  }

  MyClanMembership? _fixtureMembership() {
    final membership = _currentMembership;
    if (membership == null || membership.clanId != clan.id) return null;

    return MyClanMembership(
      clan: FixtureClan(
        id: clan.id,
        name: clan.name,
        tag: clan.tag,
        emblem: clan.emblem,
        themeId: clan.themeId,
        patternId: clan.patternId,
        skillRating: clan.skillRating,
      ),
      role: membership.role,
    );
  }

  Future<void> _openFixtureDetail(Fixture fixture) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => FixtureDetailScreen(
          fixture: fixture,
          fixtureRepository: widget.fixtureRepository,
          clanRepository: widget.clanRepository,
          myClanMembership: _fixtureMembership(),
        ),
      ),
    );

    if (changed == true && mounted) {
      await _loadClanData();
    }
  }

  Future<void> _openFixtureClan(FixtureClan fixtureClan) async {
    if (fixtureClan.id == clan.id) return;

    try {
      final clans = await widget.clanRepository.listClans();
      final target = clans.firstWhere(
        (candidate) => candidate.id == fixtureClan.id,
      );
      if (!mounted) return;

      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (context) => ClanDetailScreen(
            clan: target,
            clanRepository: widget.clanRepository,
            fixtureRepository: widget.fixtureRepository,
            currentMembership: _currentMembership,
            moderationRepository: _moderationRepository,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not open that clan. Try again.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _loadClanData() async {
    setState(() {
      _isLoadingMembers = true;
      _isLoadingRequests = true;
      _membersErrorText = null;
    });

    try {
      final membership = await widget.clanRepository.getMyClanMembership();
      final results = await Future.wait<dynamic>([
        widget.clanRepository.listClanMembers(clan.id),
        widget.clanRepository.listClanFixtures(clan.id),
        widget.clanRepository.listClans(),
        widget.clanRepository.listPendingJoinRequests(clan.id),
      ]);
      final members = results[0] as List<ClanMember>;
      final fixtures = results[1] as List<Fixture>;
      final clans = results[2] as List<Clan>;
      final visibleRequests = results[3] as List<ClanJoinRequest>;
      final isManager = membership?.clanId == clan.id && membership!.isManager;
      final refreshedClan = clans
          .where((item) => item.id == clan.id)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _members = members;
        _fixtures = fixtures;
        _currentMembership = membership;
        _pendingRequests = isManager ? visibleRequests : const [];
        _myJoinRequest = isManager
            ? null
            : visibleRequests
                  .where((request) => request.profileId == _currentUserId)
                  .firstOrNull;
        if (refreshedClan != null) _clan = refreshedClan;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _membersErrorText = userFacingError(
          error,
          fallback: 'We could not load this clan. Try again.',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingMembers = false;
          _isLoadingRequests = false;
        });
      }
    }
  }

  Future<void> _requestToJoin() async {
    if (_hasClan || _isSubmittingJoinRequest) return;
    setState(() => _isSubmittingJoinRequest = true);
    try {
      await widget.clanRepository.requestToJoinClan(clan.id);
      await _loadClanData();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Request sent to ${clan.name}.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not send that request. Try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmittingJoinRequest = false);
    }
  }

  Future<void> _cancelJoinRequest() async {
    final request = _myJoinRequest;
    if (request == null || _isSubmittingJoinRequest) return;
    final confirmed = await _confirmClanAction(
      title: 'Cancel join request?',
      message: '${clan.name} will no longer see your pending request.',
      confirmLabel: 'Cancel Request',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _isSubmittingJoinRequest = true);
    try {
      await widget.clanRepository.cancelJoinRequest(request.id);
      await _loadClanData();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not cancel that request. Try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmittingJoinRequest = false);
    }
  }

  Future<void> _reviewJoinRequest(
    ClanJoinRequest request, {
    required bool approve,
  }) async {
    if (_activeJoinRequest != null) return;
    if (!approve) {
      final confirmed = await _confirmClanAction(
        title: 'Decline ${request.displayName}?',
        message: 'Their request will be removed from the pending list.',
        confirmLabel: 'Decline',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }

    setState(() => _activeJoinRequest = request.id);
    try {
      await widget.clanRepository.reviewJoinRequest(
        requestId: request.id,
        approve: approve,
      );
      await _loadClanData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approve
                ? '${request.displayName} joined the clan.'
                : '${request.displayName}\'s request was declined.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not review that request. Try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _activeJoinRequest = null);
    }
  }

  Future<void> _archiveClan() async {
    if (!_isOwner || _isArchiving) return;
    final confirmed = await _confirmClanAction(
      title: 'Delete ${clan.name}?',
      message:
          'The clan will disappear from Field and upcoming matches will be cancelled. Its roster, payments, and match history will stay stored.',
      confirmLabel: 'Delete Clan',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _isArchiving = true);
    try {
      await widget.clanRepository.archiveClan(clan.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not delete this clan. Try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isArchiving = false);
    }
  }

  Future<void> _handlePrimaryAction() async {
    if (_canManageClan) {
      await _openFixtureFlow();
      return;
    }
    if (_hasClan) return;
    if (_myJoinRequest != null) {
      await _cancelJoinRequest();
      return;
    }
    await _requestToJoin();
  }

  Future<void> _handleMemberAction(
    ClanMember member,
    _MemberAction action,
  ) async {
    if (_activeMemberAction != null) return;

    final confirmed = switch (action) {
      _MemberAction.transferOwnership => await _confirmClanAction(
        title: 'Transfer ownership?',
        message:
            '${member.displayName} will become the owner. You will stay as a clan leader.',
        confirmLabel: 'Transfer',
      ),
      _MemberAction.remove => await _confirmClanAction(
        title: 'Remove ${member.displayName}?',
        message: 'They will lose access to this clan and its team controls.',
        confirmLabel: 'Remove',
        destructive: true,
      ),
      _ => true,
    };
    if (!confirmed || !mounted) return;

    setState(() => _activeMemberAction = member.profileId);
    try {
      switch (action) {
        case _MemberAction.makeLeader:
          await widget.clanRepository.setClanMemberLeader(
            clanId: clan.id,
            profileId: member.profileId,
            makeLeader: true,
          );
        case _MemberAction.removeLeader:
          await widget.clanRepository.setClanMemberLeader(
            clanId: clan.id,
            profileId: member.profileId,
            makeLeader: false,
          );
        case _MemberAction.transferOwnership:
          await widget.clanRepository.transferClanOwnership(
            clanId: clan.id,
            newOwnerProfileId: member.profileId,
          );
        case _MemberAction.remove:
          await widget.clanRepository.kickClanMember(
            clanId: clan.id,
            profileId: member.profileId,
          );
      }
      await _loadClanData();
      if (!mounted) return;
      final message = switch (action) {
        _MemberAction.makeLeader => '${member.displayName} is now a leader.',
        _MemberAction.removeLeader =>
          '${member.displayName} is now a regular member.',
        _MemberAction.transferOwnership =>
          '${member.displayName} now owns the clan.',
        _MemberAction.remove => '${member.displayName} was removed.',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not update that player. Try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _activeMemberAction = null);
    }
  }

  Future<void> _leaveClan() async {
    if (!_isCurrentClan || _activeMemberAction != null) return;

    final successor = _isOwner
        ? _members
              .where((member) => member.profileId != _currentUserId)
              .firstOrNull
        : null;
    final message = _isOwner
        ? successor == null
              ? 'Add another player before leaving. A clan must always have an owner.'
              : '${successor.displayName}, the earliest-joined remaining player, will become the owner.'
        : 'You will lose access to this clan and its team controls.';
    final confirmed = await _confirmClanAction(
      title: 'Leave ${clan.name}?',
      message: message,
      confirmLabel: 'Leave Clan',
      destructive: true,
    );
    if (!confirmed || !mounted || (_isOwner && successor == null)) return;

    setState(() => _activeMemberAction = _currentUserId ?? 'leave');
    try {
      await widget.clanRepository.leaveClan(clan.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not leave this clan. Try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _activeMemberAction = null);
    }
  }

  Future<bool> _confirmClanAction({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    return showFieldConfirmDialog(
      context: context,
      icon: destructive
          ? Icons.warning_amber_rounded
          : Icons.admin_panel_settings_outlined,
      eyebrow: destructive ? 'Please confirm' : 'Clan action',
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: 'Cancel',
      destructive: destructive,
    );
  }

  Future<void> _reportClan() async {
    final receipt = await showReportIssueSheet(
      context: context,
      repository: _moderationRepository,
      subjectType: ModerationSubjectType.clan,
      subjectId: clan.id,
      subjectName: clan.name,
    );
    if (!mounted || receipt == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Report sent privately · reference ${receipt.shortReference}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _ClanDetailData.fromClan(
      clan,
      members: _members,
      fixtures: _fixtures,
    );

    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: FieldPageHeader(
          title: clan.name,
          showBack: true,
          rightAction: _ClanHeaderMenu(
            enabled: !_isArchiving,
            canEdit: _canManageClan,
            canArchive: _isOwner,
            onSelected: (action) {
              switch (action) {
                case _ClanHeaderAction.edit:
                  _openCustomize();
                case _ClanHeaderAction.archive:
                  _archiveClan();
                case _ClanHeaderAction.report:
                  _reportClan();
              }
            },
          ),
        ),
        child: ListView(
          padding: fieldHeaderAwarePadding(context, bottom: 116),
          children: [
            _ClanHero(clan: clan, detail: detail),
            const SizedBox(height: 24),
            _SegmentedTabs(
              selectedIndex: _tabIndex,
              pendingCount: _canManageClan ? _pendingRequests.length : 0,
              onChanged: (index) => setState(() => _tabIndex = index),
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.03),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: switch (_tabIndex) {
                0 => _OverviewTab(
                  key: const ValueKey('overview'),
                  clan: clan,
                  detail: detail,
                ),
                1 => _MatchesTab(
                  key: const ValueKey('matches'),
                  clan: clan,
                  detail: detail,
                  onOpenFixture: _openFixtureDetail,
                  onOpenClan: _openFixtureClan,
                ),
                _ => _MembersTab(
                  key: const ValueKey('members'),
                  members: detail.members,
                  expectedCount: clan.memberCount,
                  pendingRequests: _pendingRequests,
                  isManager: _canManageClan,
                  isLoadingMembers: _isLoadingMembers,
                  isLoadingRequests: _isLoadingRequests,
                  errorText: _membersErrorText,
                  currentProfileId: _currentUserId,
                  currentRole: _isCurrentClan ? _currentMembership?.role : null,
                  activeMemberAction: _activeMemberAction,
                  activeJoinRequest: _activeJoinRequest,
                  onRetry: _loadClanData,
                  onOpenMember: _openMemberProfile,
                  onMemberAction: _handleMemberAction,
                  onReviewRequest: _reviewJoinRequest,
                  onLeaveClan: _isCurrentClan ? _leaveClan : null,
                ),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: _ClanActionBar(
        canManageMatches: _canManageClan,
        isCurrentClan: _isCurrentClan,
        hasClan: _hasClan,
        hasPendingRequest: _myJoinRequest != null,
        isWorking: _isSubmittingJoinRequest,
        onPressed: _handlePrimaryAction,
      ),
    );
  }
}

class _ClanHero extends StatelessWidget {
  const _ClanHero({required this.clan, required this.detail});

  final Clan clan;
  final _ClanDetailData detail;

  @override
  Widget build(BuildContext context) {
    final rank = clan.rank;
    final theme = clan.theme;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [theme.from, theme.to],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: theme.from.withValues(alpha: 0.34),
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: PatternPainter(
                pattern: clan.patternId,
                color: theme.accent,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.20),
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.16),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          clan.emblem,
                          style: const TextStyle(fontSize: 38),
                        ),
                      ),
                    ),
                    TierBadge(rank: rank),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        clan.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          height: 1.05,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.20),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        clan.tag,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.group_rounded,
                      color: Color(0xFFD1FAE5),
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${clan.memberCount} ${clan.memberCount == 1 ? 'member' : 'members'}',
                      style: const TextStyle(
                        color: Color(0xFFD1FAE5),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                if (detail.recentForm.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: Text(
                          'FORM',
                          style: TextStyle(
                            color: Color(0xFFD1FAE5),
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ),
                      for (final result in detail.recentForm) ...[
                        _FormPill(result: result),
                        const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _HeroStat(
                        value: clan.wins.toString(),
                        label: 'Wins',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _HeroStat(
                        value: clan.losses.toString(),
                        label: 'Losses',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _HeroStat(
                        value: '${clan.winRate}%',
                        label: 'Win %',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _HeroStat(
                        value: detail.goalDiffLabel,
                        label: 'GD',
                        accent: detail.goalDiff > 0
                            ? const Color(0xFFA7F3D0)
                            : detail.goalDiff < 0
                            ? const Color(0xFFFECACA)
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ClanHeaderMenu extends StatelessWidget {
  const _ClanHeaderMenu({
    required this.enabled,
    required this.canEdit,
    required this.canArchive,
    required this.onSelected,
  });

  final bool enabled;
  final bool canEdit;
  final bool canArchive;
  final ValueChanged<_ClanHeaderAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(12),
      child: PopupMenuButton<_ClanHeaderAction>(
        key: const ValueKey('clan-options-menu'),
        enabled: enabled,
        tooltip: 'Clan options',
        onSelected: onSelected,
        icon: const Icon(Icons.more_horiz_rounded, color: fieldGray900),
        itemBuilder: (context) => [
          if (canEdit)
            const PopupMenuItem<_ClanHeaderAction>(
              key: ValueKey('clan-edit-action'),
              value: _ClanHeaderAction.edit,
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, size: 19, color: fieldGray700),
                  SizedBox(width: 10),
                  Text(
                    'Edit clan',
                    style: TextStyle(
                      color: fieldGray900,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          if (canArchive)
            const PopupMenuItem<_ClanHeaderAction>(
              key: ValueKey('clan-archive-action'),
              value: _ClanHeaderAction.archive,
              child: Row(
                children: [
                  Icon(
                    Icons.delete_outline_rounded,
                    size: 19,
                    color: Color(0xFFDC2626),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Delete clan',
                    style: TextStyle(
                      color: Color(0xFFDC2626),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          if (canEdit || canArchive) const PopupMenuDivider(),
          const PopupMenuItem<_ClanHeaderAction>(
            key: ValueKey('clan-report-action'),
            value: _ClanHeaderAction.report,
            child: Row(
              children: [
                Icon(
                  Icons.outlined_flag_rounded,
                  size: 19,
                  color: Color(0xFFDC2626),
                ),
                SizedBox(width: 10),
                Text(
                  'Report clan',
                  style: TextStyle(
                    color: Color(0xFFDC2626),
                    fontWeight: FontWeight.w700,
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

class _FormPill extends StatelessWidget {
  const _FormPill({required this.result});

  final String result;

  @override
  Widget build(BuildContext context) {
    final background = switch (result) {
      'W' => const Color(0xFFA7F3D0),
      'L' => const Color(0xFFFCA5A5),
      _ => Colors.white.withValues(alpha: 0.40),
    };
    final foreground = switch (result) {
      'W' => const Color(0xFF064E3B),
      'L' => const Color(0xFF7F1D1D),
      _ => Colors.white,
    };

    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        result,
        style: TextStyle(
          color: foreground,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.value, required this.label, this.accent});

  final String value;
  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: accent ?? Colors.white,
                fontSize: 20,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Color(0xFFD1FAE5),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentedTabs extends StatelessWidget {
  const _SegmentedTabs({
    required this.selectedIndex,
    required this.pendingCount,
    required this.onChanged,
  });

  final int selectedIndex;
  final int pendingCount;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: fieldGray200.withValues(alpha: 0.60),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _SegmentedTabButton(
            label: 'Overview',
            selected: selectedIndex == 0,
            onTap: () => onChanged(0),
          ),
          _SegmentedTabButton(
            label: 'Matches',
            selected: selectedIndex == 1,
            onTap: () => onChanged(1),
          ),
          _SegmentedTabButton(
            label: 'Members',
            badgeCount: pendingCount,
            selected: selectedIndex == 2,
            onTap: () => onChanged(2),
          ),
        ],
      ),
    );
  }
}

class _SegmentedTabButton extends StatelessWidget {
  const _SegmentedTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? const Color(0xFF047857) : fieldGray600,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (badgeCount > 0) ...[
                const SizedBox(width: 5),
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  height: 18,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badgeCount > 99 ? '99+' : badgeCount.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({super.key, required this.clan, required this.detail});

  final Clan clan;
  final _ClanDetailData detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _RatingPanel(clan: clan),
        if (detail.nextMatch != null) ...[
          const SizedBox(height: 16),
          _NextMatchCard(match: detail.nextMatch!),
        ],
        if (detail.topScorer != null || detail.topAssister != null) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _TopPerformerCard(
                  icon: Icons.sports_soccer_rounded,
                  label: 'Top Scorer',
                  player: detail.topScorer?.playerName,
                  value: detail.topScorer?.value ?? '—',
                  colors: const [Color(0xFFF97316), Color(0xFFDB2777)],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TopPerformerCard(
                  icon: Icons.auto_awesome_rounded,
                  label: 'Top Assister',
                  player: detail.topAssister?.playerName,
                  value: detail.topAssister?.value ?? '—',
                  colors: const [Color(0xFF3B82F6), Color(0xFF7C3AED)],
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        _ScoringPanel(detail: detail),
        const SizedBox(height: 16),
        _KitIdentityPanel(clan: clan),
      ],
    );
  }
}

class _RatingPanel extends StatelessWidget {
  const _RatingPanel({required this.clan});

  final Clan clan;

  @override
  Widget build(BuildContext context) {
    final rank = clan.rank;
    final bounds = _divisionBounds(rank);
    final maxLabel = rank.tier == ClanTier.champion
        ? 'MAX'
        : (bounds.max + 1).toString();
    final progress = rank.tier == ClanTier.champion
        ? 1.0
        : ((clan.skillRating - bounds.min) / (bounds.max + 1 - bounds.min))
              .clamp(0, 1)
              .toDouble();
    final srToNext = rank.tier == ClanTier.champion
        ? null
        : (bounds.max + 1) - clan.skillRating;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Skill Rating',
                            style: TextStyle(
                              color: fieldGray900,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        TierLabelBadge(rank: rank, small: true),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(
                        children: [
                          if (srToNext != null)
                            TextSpan(
                              text: '$srToNext SR',
                              style: const TextStyle(
                                color: fieldEmerald600,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          TextSpan(
                            text: srToNext == null
                                ? 'Champion — Max Tier'
                                : ' to next division',
                          ),
                        ],
                      ),
                      style: TextStyle(
                        color: srToNext == null
                            ? const Color(0xFFF59E0B)
                            : fieldGray500,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                clan.skillRating.toString(),
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 30,
                  height: 1,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 12),
              TierBadge(rank: rank, small: true),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                bounds.min.toString(),
                style: const TextStyle(
                  color: fieldGray400,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                maxLabel,
                style: const TextStyle(
                  color: fieldGray400,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 16,
              child: Stack(
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(color: fieldGray100),
                    child: SizedBox.expand(),
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: progress),
                    duration: const Duration(milliseconds: 850),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, child) {
                      return FractionallySizedBox(
                        widthFactor: value,
                        child: child,
                      );
                    },
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            tierStartColor(rank.tier),
                            tierMiddleColor(rank.tier),
                            tierEndColor(rank.tier),
                          ],
                        ),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NextMatchCard extends StatelessWidget {
  const _NextMatchCard({required this.match});

  final _FixtureSummary match;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4F46E5), Color(0xFF2563EB), Color(0xFF06B6D4)],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2563EB).withValues(alpha: 0.30),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            top: -48,
            right: -42,
            child: Container(
              width: 128,
              height: 128,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF67E8F9).withValues(alpha: 0.30),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF67E8F9).withValues(alpha: 0.35),
                    blurRadius: 30,
                    spreadRadius: 12,
                  ),
                ],
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'NEXT MATCH',
                      style: TextStyle(
                        color: Color(0xFFCFFAFE),
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          match.opponentEmblem,
                          style: const TextStyle(fontSize: 25),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'vs ${match.opponentName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        const Icon(
                          Icons.calendar_month_rounded,
                          color: Color(0xFFCFFAFE),
                          size: 13,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${match.dateLabel} · ${match.timeLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFCFFAFE),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    match.daysAway.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 40,
                      height: 0.95,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  Text(
                    match.daysAway == 1 ? 'DAY' : 'DAYS',
                    style: const TextStyle(
                      color: Color(0xFFCFFAFE),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopPerformerCard extends StatelessWidget {
  const _TopPerformerCard({
    required this.icon,
    required this.label,
    required this.player,
    required this.value,
    required this.colors,
  });

  final IconData icon;
  final String label;
  final String? player;
  final String value;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.all(16),
      child: Stack(
        children: [
          Positioned(
            top: -16,
            left: -16,
            right: -16,
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: colors),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: colors,
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: Colors.white, size: 15),
              ),
              const SizedBox(height: 10),
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                player ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScoringPanel extends StatelessWidget {
  const _ScoringPanel({required this.detail});

  final _ClanDetailData detail;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle(
            icon: Icons.track_changes_rounded,
            iconColor: Color(0xFFEA580C),
            iconBackground: Color(0xFFFFF7ED),
            title: 'Scoring',
            tracking: true,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _ScoringStat(
                  value: detail.goalsFor.toString(),
                  label: 'For',
                  color: fieldEmerald600,
                ),
              ),
              Expanded(
                child: _ScoringStat(
                  value: detail.goalsAgainst.toString(),
                  label: 'Against',
                  color: const Color(0xFFEF4444),
                ),
              ),
              Expanded(
                child: _ScoringStat(
                  value: detail.goalDiffLabel,
                  label: 'Diff',
                  color: detail.goalDiff > 0
                      ? fieldEmerald600
                      : detail.goalDiff < 0
                      ? const Color(0xFFEF4444)
                      : fieldGray500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScoringStat extends StatelessWidget {
  const _ScoringStat({
    required this.value,
    required this.label,
    required this.color,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 26,
            height: 1,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.1,
          ),
        ),
      ],
    );
  }
}

class _KitIdentityPanel extends StatelessWidget {
  const _KitIdentityPanel({required this.clan});

  final Clan clan;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle(
            icon: Icons.palette_rounded,
            iconColor: Color(0xFF7C3AED),
            iconBackground: Color(0xFFF5F3FF),
            title: 'Kit Identity',
          ),
          const SizedBox(height: 16),
          KitCard(
            clanName: clan.name,
            clanTag: clan.tag,
            motto: clan.motto,
            emblem: clan.emblem,
            theme: clan.theme,
            pattern: clan.patternId,
          ),
        ],
      ),
    );
  }
}

class _MembersTab extends StatelessWidget {
  const _MembersTab({
    super.key,
    required this.members,
    required this.expectedCount,
    required this.pendingRequests,
    required this.isManager,
    required this.isLoadingMembers,
    required this.isLoadingRequests,
    required this.errorText,
    required this.currentProfileId,
    required this.currentRole,
    required this.activeMemberAction,
    required this.activeJoinRequest,
    required this.onRetry,
    required this.onOpenMember,
    required this.onMemberAction,
    required this.onReviewRequest,
    required this.onLeaveClan,
  });

  final List<ClanMember> members;
  final int expectedCount;
  final List<ClanJoinRequest> pendingRequests;
  final bool isManager;
  final bool isLoadingMembers;
  final bool isLoadingRequests;
  final String? errorText;
  final String? currentProfileId;
  final String? currentRole;
  final String? activeMemberAction;
  final String? activeJoinRequest;
  final VoidCallback onRetry;
  final ValueChanged<ClanMember> onOpenMember;
  final void Function(ClanMember, _MemberAction) onMemberAction;
  final void Function(ClanJoinRequest, {required bool approve}) onReviewRequest;
  final VoidCallback? onLeaveClan;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (isManager) ...[
          _PendingRequestsPanel(
            requests: pendingRequests,
            isLoading: isLoadingRequests,
            activeRequestId: activeJoinRequest,
            onReview: onReviewRequest,
          ),
          const SizedBox(height: 16),
        ],
        _RosterPanel(
          members: members,
          expectedCount: expectedCount,
          isLoading: isLoadingMembers,
          errorText: errorText,
          onRetry: onRetry,
          currentProfileId: currentProfileId,
          currentRole: currentRole,
          activeMemberAction: activeMemberAction,
          onOpenMember: onOpenMember,
          onMemberAction: onMemberAction,
          onLeaveClan: onLeaveClan,
        ),
      ],
    );
  }
}

class _PendingRequestsPanel extends StatelessWidget {
  const _PendingRequestsPanel({
    required this.requests,
    required this.isLoading,
    required this.activeRequestId,
    required this.onReview,
  });

  final List<ClanJoinRequest> requests;
  final bool isLoading;
  final String? activeRequestId;
  final void Function(ClanJoinRequest, {required bool approve}) onReview;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: _PanelTitle(
                  icon: Icons.person_add_alt_1_rounded,
                  iconColor: fieldEmerald600,
                  iconBackground: Color(0xFFECFDF5),
                  title: 'Join Requests',
                ),
              ),
              Container(
                constraints: const BoxConstraints(minWidth: 28),
                height: 28,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: requests.isEmpty
                      ? fieldGray100
                      : const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  requests.length.toString(),
                  style: TextStyle(
                    color: requests.isEmpty
                        ? fieldGray500
                        : const Color(0xFFDC2626),
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (isLoading && requests.isEmpty)
            const Column(
              children: [
                _RosterSkeletonRow(),
                SizedBox(height: 12),
                _RosterSkeletonRow(),
              ],
            )
          else if (requests.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: const Column(
                children: [
                  Icon(
                    Icons.mark_email_read_rounded,
                    color: fieldGray400,
                    size: 28,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'No pending requests',
                    style: TextStyle(
                      color: fieldGray500,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            )
          else
            for (var index = 0; index < requests.length; index++) ...[
              _JoinRequestRow(
                request: requests[index],
                isBusy: activeRequestId == requests[index].id,
                actionsEnabled: activeRequestId == null,
                onReview: onReview,
              ),
              if (index != requests.length - 1)
                const Divider(height: 20, color: fieldGray100),
            ],
        ],
      ),
    );
  }
}

class _JoinRequestRow extends StatelessWidget {
  const _JoinRequestRow({
    required this.request,
    required this.isBusy,
    required this.actionsEnabled,
    required this.onReview,
  });

  final ClanJoinRequest request;
  final bool isBusy;
  final bool actionsEnabled;
  final void Function(ClanJoinRequest, {required bool approve}) onReview;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF34D399), Color(0xFF3B82F6)],
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            request.initials,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                request.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _joinRequestDate(request.requestedAt),
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (isBusy)
          const SizedBox(
            width: 38,
            height: 38,
            child: Padding(
              padding: EdgeInsets.all(10),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else ...[
          IconButton(
            onPressed: actionsEnabled
                ? () => onReview(request, approve: false)
                : null,
            tooltip: 'Decline request',
            icon: const Icon(Icons.close_rounded),
            color: const Color(0xFFDC2626),
          ),
          IconButton.filled(
            onPressed: actionsEnabled
                ? () => onReview(request, approve: true)
                : null,
            tooltip: 'Approve request',
            icon: const Icon(Icons.check_rounded, size: 20),
            style: IconButton.styleFrom(
              backgroundColor: fieldEmerald600,
              foregroundColor: Colors.white,
              disabledBackgroundColor: fieldGray200,
            ),
          ),
        ],
      ],
    );
  }
}

String _joinRequestDate(DateTime? value) {
  if (value == null) return 'Requested recently';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = value.toLocal();
  return 'Requested ${months[local.month - 1]} ${local.day}';
}

class _RosterPanel extends StatelessWidget {
  const _RosterPanel({
    required this.members,
    required this.expectedCount,
    required this.isLoading,
    required this.errorText,
    required this.onRetry,
    required this.currentProfileId,
    required this.currentRole,
    required this.activeMemberAction,
    required this.onOpenMember,
    required this.onMemberAction,
    required this.onLeaveClan,
  });

  final List<ClanMember> members;
  final int expectedCount;
  final bool isLoading;
  final String? errorText;
  final VoidCallback onRetry;
  final String? currentProfileId;
  final String? currentRole;
  final String? activeMemberAction;
  final ValueChanged<ClanMember> onOpenMember;
  final void Function(ClanMember, _MemberAction) onMemberAction;
  final VoidCallback? onLeaveClan;

  @override
  Widget build(BuildContext context) {
    final count = isLoading && members.isEmpty ? expectedCount : members.length;

    return _Panel(
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: _PanelTitle(
                  icon: Icons.group_rounded,
                  iconColor: fieldBlue600,
                  iconBackground: Color(0xFFEFF6FF),
                  title: 'Roster',
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: fieldGray100,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  count.toString(),
                  style: const TextStyle(
                    color: fieldGray600,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (onLeaveClan != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  onPressed: activeMemberAction == null ? onLeaveClan : null,
                  tooltip: 'Leave clan',
                  icon: const Icon(Icons.logout_rounded, size: 20),
                  color: fieldGray500,
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          if (isLoading && members.isEmpty)
            const Column(
              children: [
                _RosterSkeletonRow(),
                SizedBox(height: 12),
                _RosterSkeletonRow(),
                SizedBox(height: 12),
                _RosterSkeletonRow(),
              ],
            )
          else if (errorText != null)
            _RosterErrorState(message: errorText!, onRetry: onRetry)
          else if (members.isEmpty)
            const _DashedEmptyState(message: 'No members found yet.')
          else
            for (var i = 0; i < members.length; i++) ...[
              _MemberRow(
                member: members[i],
                currentProfileId: currentProfileId,
                currentRole: currentRole,
                isBusy: activeMemberAction == members[i].profileId,
                actionsEnabled: activeMemberAction == null,
                onTap: () => onOpenMember(members[i]),
                onAction: onMemberAction,
              ),
              if (i != members.length - 1) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.currentProfileId,
    required this.currentRole,
    required this.isBusy,
    required this.actionsEnabled,
    required this.onTap,
    required this.onAction,
  });

  final ClanMember member;
  final String? currentProfileId;
  final String? currentRole;
  final bool isBusy;
  final bool actionsEnabled;
  final VoidCallback onTap;
  final void Function(ClanMember, _MemberAction) onAction;

  List<_MemberAction> get _actions {
    if (member.profileId == currentProfileId) return const [];
    if (currentRole == 'owner') {
      return [
        if (member.isLeader)
          _MemberAction.removeLeader
        else
          _MemberAction.makeLeader,
        _MemberAction.transferOwnership,
        _MemberAction.remove,
      ];
    }
    if (currentRole == 'leader' && !member.isManager) {
      return const [_MemberAction.remove];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF34D399), Color(0xFF3B82F6)],
                  ),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 7,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  member.initials,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            member.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: fieldGray900,
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        if (member.isManager) ...[
                          const SizedBox(width: 7),
                          _RoleBadge(role: member.role),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      member.roleLabel,
                      style: const TextStyle(
                        color: fieldGray500,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (isBusy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (_actions.isNotEmpty)
                PopupMenuButton<_MemberAction>(
                  enabled: actionsEnabled,
                  tooltip: 'Manage ${member.displayName}',
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    color: fieldGray500,
                  ),
                  onSelected: (action) => onAction(member, action),
                  itemBuilder: (context) => [
                    for (final action in _actions)
                      PopupMenuItem<_MemberAction>(
                        value: action,
                        child: Row(
                          children: [
                            Icon(
                              _memberActionIcon(action),
                              size: 19,
                              color: action == _MemberAction.remove
                                  ? const Color(0xFFDC2626)
                                  : fieldGray700,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _memberActionLabel(action),
                              style: TextStyle(
                                color: action == _MemberAction.remove
                                    ? const Color(0xFFDC2626)
                                    : fieldGray900,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                )
              else
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: fieldGray300,
                    size: 21,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RosterSkeletonRow extends StatelessWidget {
  const _RosterSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        FieldSkeletonBox(width: 42, height: 42, borderRadius: 999),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FieldSkeletonBox(height: 14, borderRadius: 6),
              SizedBox(height: 8),
              FieldSkeletonBox(width: 120, height: 12, borderRadius: 6),
            ],
          ),
        ),
        SizedBox(width: 12),
        FieldSkeletonBox(width: 58, height: 24, borderRadius: 999),
      ],
    );
  }
}

class _RosterErrorState extends StatelessWidget {
  const _RosterErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('Try Again'),
          style: TextButton.styleFrom(
            foregroundColor: fieldEmerald600,
            textStyle: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final isOwner = role == 'owner';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isOwner
              ? const [Color(0xFFFBBF24), Color(0xFFF97316)]
              : const [Color(0xFF10B981), Color(0xFF2563EB)],
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isOwner ? Icons.workspace_premium_rounded : Icons.shield_rounded,
            color: Colors.white,
            size: 10,
          ),
          const SizedBox(width: 3),
          Text(
            isOwner ? 'OWNER' : 'LEADER',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.7,
            ),
          ),
        ],
      ),
    );
  }
}

String _memberActionLabel(_MemberAction action) {
  return switch (action) {
    _MemberAction.makeLeader => 'Make leader',
    _MemberAction.removeLeader => 'Remove leader',
    _MemberAction.transferOwnership => 'Transfer ownership',
    _MemberAction.remove => 'Remove from clan',
  };
}

IconData _memberActionIcon(_MemberAction action) {
  return switch (action) {
    _MemberAction.makeLeader => Icons.add_moderator_rounded,
    _MemberAction.removeLeader => Icons.remove_moderator_rounded,
    _MemberAction.transferOwnership => Icons.swap_horiz_rounded,
    _MemberAction.remove => Icons.person_remove_rounded,
  };
}

class _MatchesTab extends StatelessWidget {
  const _MatchesTab({
    super.key,
    required this.clan,
    required this.detail,
    required this.onOpenFixture,
    required this.onOpenClan,
  });

  final Clan clan;
  final _ClanDetailData detail;
  final ValueChanged<Fixture> onOpenFixture;
  final ValueChanged<FixtureClan> onOpenClan;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Panel(
          child: Column(
            children: [
              const _PanelTitle(
                icon: Icons.sports_mma_rounded,
                iconColor: fieldEmerald600,
                iconBackground: Color(0xFFECFDF5),
                title: 'Upcoming',
              ),
              const SizedBox(height: 16),
              if (detail.upcomingMatches.isEmpty)
                const _DashedEmptyState(message: 'No upcoming fixtures')
              else
                for (var i = 0; i < detail.upcomingMatches.length; i++) ...[
                  _UpcomingMatchRow(
                    match: detail.upcomingMatches[i],
                    onTap: () =>
                        onOpenFixture(detail.upcomingMatches[i].fixture),
                  ),
                  if (i != detail.upcomingMatches.length - 1)
                    const SizedBox(height: 12),
                ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Panel(
          child: Column(
            children: [
              const _PanelTitle(
                icon: Icons.history_rounded,
                iconColor: fieldBlue600,
                iconBackground: Color(0xFFEFF6FF),
                title: 'History',
              ),
              const SizedBox(height: 16),
              if (detail.pastMatches.isEmpty)
                const _DashedEmptyState(message: 'No past matches yet')
              else
                for (var i = 0; i < detail.pastMatches.length; i++) ...[
                  _PastMatchCard(
                    clan: clan,
                    match: detail.pastMatches[i],
                    onTap: () => onOpenFixture(detail.pastMatches[i].fixture),
                    onOpponentTap: detail.pastMatches[i].opponent == null
                        ? null
                        : () => onOpenClan(detail.pastMatches[i].opponent!),
                  ),
                  if (i != detail.pastMatches.length - 1)
                    const SizedBox(height: 12),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

class _UpcomingMatchRow extends StatelessWidget {
  const _UpcomingMatchRow({required this.match, required this.onTap});

  final _FixtureSummary match;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: fieldGray100.withValues(alpha: 0.72),
            border: Border.all(color: fieldGray100),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              _OpponentAvatar(emblem: match.opponentEmblem),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'vs ${match.opponentName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: fieldGray900,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFECFDF5),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            match.dayShort,
                            style: const TextStyle(
                              color: fieldEmerald600,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(
                          Icons.calendar_month_rounded,
                          color: fieldGray500,
                          size: 12,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '${match.dateLabel} - ${match.timeLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: fieldGray500,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right_rounded,
                color: fieldGray400,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PastMatchCard extends StatelessWidget {
  const _PastMatchCard({
    required this.clan,
    required this.match,
    required this.onTap,
    this.onOpponentTap,
  });

  final Clan clan;
  final _FixtureSummary match;
  final VoidCallback onTap;
  final VoidCallback? onOpponentTap;

  @override
  Widget build(BuildContext context) {
    final badgeColor = match.isCancelled
        ? const Color(0xFFB45309)
        : match.outcome == 'Victory'
        ? fieldEmerald600
        : match.outcome == 'Draw'
        ? fieldGray600
        : const Color(0xFFDC2626);
    final badgeBackground = match.isCancelled
        ? const Color(0xFFFFF7ED)
        : match.outcome == 'Victory'
        ? const Color(0xFFECFDF5)
        : match.outcome == 'Draw'
        ? fieldGray100
        : const Color(0xFFFEF2F2);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: fieldGray100),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${match.dateLabel} - ${match.timeLabel}',
                      style: const TextStyle(
                        color: fieldGray400,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: badgeBackground,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      match.outcome.toUpperCase(),
                      style: TextStyle(
                        color: badgeColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (match.isCancelled)
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF7ED),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.event_busy_rounded,
                        color: Color(0xFFEA580C),
                        size: 19,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        match.note ?? 'Match cancelled.',
                        style: const TextStyle(
                          color: fieldGray600,
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: _ScorecardClanSide(
                        name: clan.name,
                        tag: clan.tag,
                        emblem: clan.emblem,
                        score: match.myScore,
                        highlight: match.outcome == 'Victory',
                        alignEnd: false,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        '-',
                        style: TextStyle(
                          color: fieldGray300,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _ScorecardClanSide(
                        name: match.opponentName,
                        tag: match.opponentTag,
                        emblem: match.opponentEmblem,
                        score: match.opponentScore,
                        highlight: match.outcome == 'Defeat',
                        alignEnd: true,
                        onTap: onOpponentTap,
                      ),
                    ),
                  ],
                ),
              if (!match.isCancelled && match.srChange != null) ...[
                const SizedBox(height: 12),
                const Divider(color: fieldGray100, height: 1),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Rating Change',
                        style: TextStyle(
                          color: fieldGray500,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      match.srChange! > 0
                          ? Icons.trending_up_rounded
                          : match.srChange! < 0
                          ? Icons.trending_down_rounded
                          : Icons.remove_rounded,
                      color: match.srChange! > 0
                          ? fieldEmerald600
                          : match.srChange! < 0
                          ? const Color(0xFFEF4444)
                          : fieldGray500,
                      size: 15,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${match.srChange! > 0 ? '+' : ''}${match.srChange} SR',
                      style: TextStyle(
                        color: match.srChange! > 0
                            ? fieldEmerald600
                            : match.srChange! < 0
                            ? const Color(0xFFEF4444)
                            : fieldGray500,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ScorecardClanSide extends StatelessWidget {
  const _ScorecardClanSide({
    required this.name,
    required this.tag,
    required this.emblem,
    required this.score,
    required this.highlight,
    required this.alignEnd,
    this.onTap,
  });

  final String name;
  final String tag;
  final String emblem;
  final int score;
  final bool highlight;
  final bool alignEnd;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisAlignment: alignEnd
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: alignEnd
          ? [
              Flexible(
                child: _ScorecardClanText(name: name, tag: tag, alignEnd: true),
              ),
              const SizedBox(width: 8),
              _ScoreText(value: score, highlight: highlight),
              const SizedBox(width: 8),
              _OpponentAvatar(emblem: emblem, size: 32),
            ]
          : [
              _OpponentAvatar(emblem: emblem, size: 32),
              const SizedBox(width: 8),
              _ScoreText(value: score, highlight: highlight),
              const SizedBox(width: 8),
              Flexible(
                child: _ScorecardClanText(name: name, tag: tag),
              ),
            ],
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: content,
        ),
      ),
    );
  }
}

class _ScoreText extends StatelessWidget {
  const _ScoreText({required this.value, required this.highlight});

  final int value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Text(
      value.toString(),
      style: TextStyle(
        color: highlight ? fieldGray900 : fieldGray500,
        fontSize: 22,
        height: 1,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class _ScorecardClanText extends StatelessWidget {
  const _ScorecardClanText({
    required this.name,
    required this.tag,
    this.alignEnd = false,
  });

  final String name;
  final String tag;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: alignEnd ? TextAlign.right : TextAlign.left,
          style: const TextStyle(
            color: fieldGray900,
            fontSize: 12,
            height: 1,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          tag,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: alignEnd ? TextAlign.right : TextAlign.left,
          style: const TextStyle(
            color: fieldGray400,
            fontSize: 10,
            height: 1,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}

class _OpponentAvatar extends StatelessWidget {
  const _OpponentAvatar({required this.emblem, this.size = 40});

  final String emblem;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(emblem, style: TextStyle(fontSize: size * 0.52)),
    );
  }
}

class _DashedEmptyState extends StatelessWidget {
  const _DashedEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: fieldGray100.withValues(alpha: 0.66),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    this.tracking = false,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String title;
  final bool tracking;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: iconBackground,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        const SizedBox(width: 10),
        Text(
          title.toUpperCase(),
          style: TextStyle(
            color: fieldGray900,
            fontSize: tracking ? 14 : 18,
            fontWeight: FontWeight.w900,
            letterSpacing: tracking ? 1.9 : 0,
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _ClanActionBar extends StatelessWidget {
  const _ClanActionBar({
    required this.canManageMatches,
    required this.isCurrentClan,
    required this.hasClan,
    required this.hasPendingRequest,
    required this.isWorking,
    required this.onPressed,
  });

  final bool canManageMatches;
  final bool isCurrentClan;
  final bool hasClan;
  final bool hasPendingRequest;
  final bool isWorking;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = !isWorking && (canManageMatches || !hasClan);
    final icon = canManageMatches
        ? Icons.sports_mma_rounded
        : isCurrentClan
        ? Icons.verified_user_rounded
        : hasClan
        ? Icons.lock_rounded
        : hasPendingRequest
        ? Icons.hourglass_top_rounded
        : Icons.group_add_rounded;
    final label = canManageMatches
        ? 'Schedule a Match'
        : isCurrentClan
        ? 'Clan Member'
        : hasClan
        ? 'Already in a Clan'
        : hasPendingRequest
        ? 'Request Pending'
        : 'Request to Join';
    final activeColor = hasPendingRequest ? fieldGray900 : fieldEmerald600;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.88),
          border: const Border(top: BorderSide(color: fieldGray200)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: SizedBox(
          height: 56,
          width: double.infinity,
          child: Material(
            color: enabled ? activeColor : fieldGray200,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: enabled ? onPressed : null,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: enabled
                      ? null
                      : Border.all(color: fieldGray300, width: 1.2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isWorking)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        icon,
                        color: enabled ? Colors.white : fieldGray500,
                        size: 22,
                      ),
                    const SizedBox(width: 9),
                    Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        color: enabled ? Colors.white : fieldGray500,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.9,
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
}

class _DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = fieldGray200
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const dash = 7.0;
    const gap = 5.0;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(14),
    );
    final path = Path()..addRRect(rect);

    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dash), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) => false;
}

class _DivisionBounds {
  const _DivisionBounds({required this.min, required this.max});

  final int min;
  final int max;
}

_DivisionBounds _divisionBounds(ClanRank rank) {
  final tierMin = switch (rank.tier) {
    ClanTier.silver => 0,
    ClanTier.gold => 900,
    ClanTier.diamond => 1800,
    ClanTier.champion => 2700,
  };
  if (rank.division == null) {
    return _DivisionBounds(min: tierMin, max: 5000);
  }
  final index = 3 - rank.division!;
  return _DivisionBounds(
    min: tierMin + (index * 300),
    max: tierMin + ((index + 1) * 300) - 1,
  );
}

class _ClanDetailData {
  const _ClanDetailData({
    required this.recentForm,
    required this.goalsFor,
    required this.goalsAgainst,
    required this.members,
    required this.upcomingMatches,
    required this.pastMatches,
    this.nextMatch,
    this.topScorer,
    this.topAssister,
  });

  final List<String> recentForm;
  final int goalsFor;
  final int goalsAgainst;
  final List<ClanMember> members;
  final List<_FixtureSummary> upcomingMatches;
  final List<_FixtureSummary> pastMatches;
  final _FixtureSummary? nextMatch;
  final _TopPerformer? topScorer;
  final _TopPerformer? topAssister;

  int get goalDiff => goalsFor - goalsAgainst;

  String get goalDiffLabel => goalDiff > 0 ? '+$goalDiff' : goalDiff.toString();

  factory _ClanDetailData.fromClan(
    Clan clan, {
    required List<ClanMember> members,
    required List<Fixture> fixtures,
  }) {
    final recentForm = _recentFormFor(clan);
    final goalsFor = clan.wins == 0 && clan.losses == 0
        ? 0
        : (clan.wins * 3) + clan.losses;
    final goalsAgainst = clan.wins == 0 && clan.losses == 0
        ? 0
        : (clan.losses * 2) + (clan.wins ~/ 2);
    final upcomingMatches = _upcomingMatchesFor(clan, fixtures);
    final pastMatches = _pastMatchesFor(clan, fixtures);

    return _ClanDetailData(
      recentForm: recentForm,
      goalsFor: goalsFor,
      goalsAgainst: goalsAgainst,
      members: members,
      upcomingMatches: upcomingMatches,
      pastMatches: pastMatches,
      nextMatch: upcomingMatches.isEmpty ? null : upcomingMatches.first,
      topScorer: goalsFor > 0 && members.isNotEmpty
          ? _TopPerformer(
              playerName: members.first.displayName,
              value: '$goalsFor ${goalsFor == 1 ? 'goal' : 'goals'}',
            )
          : null,
      topAssister: goalsFor > 2 && members.isNotEmpty
          ? _TopPerformer(
              playerName: members.length > 1
                  ? members[1].displayName
                  : members.first.displayName,
              value: '${(goalsFor / 2).floor()} assists',
            )
          : null,
    );
  }
}

List<String> _recentFormFor(Clan clan) {
  final results = <String>[];
  var wins = clan.wins;
  var losses = clan.losses;
  while (results.length < 5 && (wins > 0 || losses > 0)) {
    if (wins > 0) {
      results.add('W');
      wins -= 1;
    }
    if (results.length < 5 && losses > 0) {
      results.add('L');
      losses -= 1;
    }
  }
  return results;
}

List<_FixtureSummary> _upcomingMatchesFor(Clan clan, List<Fixture> fixtures) {
  final upcoming =
      fixtures
          .where(
            (fixture) =>
                fixture.status == FixtureStatus.open ||
                fixture.status == FixtureStatus.scheduled ||
                fixture.status == FixtureStatus.live,
          )
          .toList()
        ..sort(_fixtureAscending);

  return [for (final fixture in upcoming) _summaryFromFixture(clan, fixture)];
}

List<_FixtureSummary> _pastMatchesFor(Clan clan, List<Fixture> fixtures) {
  final past =
      fixtures
          .where(
            (fixture) =>
                fixture.status == FixtureStatus.finalResult ||
                fixture.status == FixtureStatus.cancelled,
          )
          .toList()
        ..sort((a, b) => _fixtureAscending(b, a));

  return [for (final fixture in past) _summaryFromFixture(clan, fixture)];
}

int _fixtureAscending(Fixture a, Fixture b) {
  final dateCompare = a.matchDate.compareTo(b.matchDate);
  if (dateCompare != 0) return dateCompare;
  return a.timeSlot.compareTo(b.timeSlot);
}

_FixtureSummary _summaryFromFixture(Clan clan, Fixture fixture) {
  final opponent = fixture.opponentFor(clan.id);
  final isCancelled = fixture.status == FixtureStatus.cancelled;
  final myScore = fixture.scoreFor(clan.id);
  final opponentScore = opponent == null
      ? null
      : (fixture.homeClanId == clan.id ? fixture.awayScore : fixture.homeScore);
  final matchStart = DateTime(
    fixture.matchDate.year,
    fixture.matchDate.month,
    fixture.matchDate.day,
  );
  final today = DateTime.now();
  final todayDate = DateTime(today.year, today.month, today.day);
  final daysAway = matchStart.difference(todayDate).inDays;

  return _FixtureSummary(
    fixture: fixture,
    opponent: opponent,
    opponentName: opponent?.name ?? 'Awaiting opponent',
    opponentTag: opponent?.tag ?? 'TBD',
    opponentEmblem: opponent?.emblem ?? '?',
    dateLabel: fixture.monthDay,
    timeLabel: fixture.timeSlot,
    dayShort: fixture.dayShort,
    daysAway: daysAway < 0 ? 0 : daysAway,
    myScore: myScore ?? 0,
    opponentScore: opponentScore ?? 0,
    srChange: fixture.srChangeFor(clan.id),
    isCancelled: isCancelled,
    note: isCancelled ? fixture.cancellationDisplayReason : null,
  );
}

class _TopPerformer {
  const _TopPerformer({required this.playerName, required this.value});

  final String playerName;
  final String value;
}

class _FixtureSummary {
  const _FixtureSummary({
    required this.fixture,
    required this.opponent,
    required this.opponentName,
    required this.opponentTag,
    required this.opponentEmblem,
    required this.dateLabel,
    required this.timeLabel,
    required this.dayShort,
    required this.daysAway,
    this.myScore = 0,
    this.opponentScore = 0,
    this.srChange,
    this.isCancelled = false,
    this.note,
  });

  final Fixture fixture;
  final FixtureClan? opponent;
  final String opponentName;
  final String opponentTag;
  final String opponentEmblem;
  final String dateLabel;
  final String timeLabel;
  final String dayShort;
  final int daysAway;
  final int myScore;
  final int opponentScore;
  final int? srChange;
  final bool isCancelled;
  final String? note;

  String get outcome {
    if (isCancelled) return 'Cancelled';
    if (myScore > opponentScore) return 'Victory';
    if (myScore == opponentScore) return 'Draw';
    return 'Defeat';
  }
}
