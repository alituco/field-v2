import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import 'fixture.dart';
import 'fixture_repository.dart';
import 'fixture_widgets.dart';

class FixtureDetailScreen extends StatefulWidget {
  const FixtureDetailScreen({
    super.key,
    required this.fixture,
    required this.fixtureRepository,
    required this.myClanMembership,
    this.refreshFixture,
    this.sourceLabel,
    this.showTeamRatings = true,
    this.playerRatingUpdate,
  });

  final Fixture fixture;
  final FixtureRepository fixtureRepository;
  final MyClanMembership? myClanMembership;
  final Future<Fixture> Function()? refreshFixture;
  final String? sourceLabel;
  final bool showTeamRatings;
  final FixturePlayerRatingUpdate? playerRatingUpdate;

  @override
  State<FixtureDetailScreen> createState() => _FixtureDetailScreenState();
}

enum _FixtureDetailSection { watch, timeline, lineups }

class _FixtureDetailScreenState extends State<FixtureDetailScreen> {
  late Fixture _fixture = widget.fixture;
  final ProfileRepository _profileRepository = SupabaseProfileRepository();
  _FixtureDetailSection _selectedSection = _FixtureDetailSection.timeline;
  Timer? _refreshTimer;
  bool _isJoining = false;
  bool _isCompleting = false;
  bool _isRefreshing = false;
  bool _didChange = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _configureRefreshTimer();
    unawaited(_refreshFixture(quiet: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  bool get _canJoin {
    final membership = widget.myClanMembership;
    return membership != null &&
        membership.canManageMatches &&
        _fixture.isOpen &&
        _fixture.homeClanId != membership.clan.id;
  }

  bool get _canShowCompleteAction {
    return false;
  }

  bool get _canSeePayments {
    final membership = widget.myClanMembership;
    if (membership == null) return false;
    final isParticipating =
        membership.clan.id == _fixture.homeClanId ||
        membership.clan.id == _fixture.awayClanId;
    final isUpcoming =
        _fixture.status == FixtureStatus.open ||
        _fixture.status == FixtureStatus.scheduled;
    return isParticipating && isUpcoming;
  }

  bool get _canComplete {
    final membership = widget.myClanMembership;
    if (membership == null || !membership.canManageMatches) return false;
    if (!_canShowCompleteAction) return false;

    return membership.clan.id == _fixture.homeClanId ||
        membership.clan.id == _fixture.awayClanId;
  }

  Future<void> _joinFixture() async {
    final membership = widget.myClanMembership;
    if (membership == null || !membership.canManageMatches) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only clan owners and leaders can join matches.'),
        ),
      );
      return;
    }

    setState(() {
      _isJoining = true;
      _errorText = null;
    });

    try {
      final fixture = await widget.fixtureRepository.joinFixture(
        fixtureId: _fixture.id,
        awayClanId: membership.clan.id,
      );
      if (!mounted) return;
      setState(() {
        _fixture = fixture;
        _didChange = true;
      });
      _configureRefreshTimer();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Match joined. Game on.')));
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not join this match. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isJoining = false);
      }
    }
  }

  Future<void> _completeFixture() async {
    if (!_canComplete) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Only participating clan owners and leaders can finalize scores.',
          ),
        ),
      );
      return;
    }

    final scores = await showModalBottomSheet<_ScoreSubmission>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CompleteScoreSheet(fixture: _fixture),
    );
    if (scores == null) return;

    setState(() {
      _isCompleting = true;
      _errorText = null;
    });

    try {
      final fixture = await widget.fixtureRepository.completeFixture(
        fixtureId: _fixture.id,
        homeScore: scores.homeScore,
        awayScore: scores.awayScore,
      );
      if (!mounted) return;
      setState(() {
        _fixture = fixture;
        _didChange = true;
      });
      _configureRefreshTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Score finalized. SR updated.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not finalize this match. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isCompleting = false);
      }
    }
  }

  Future<void> _openPlayerProfile(String profileId) async {
    if (profileId.trim().isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: fieldBackground,
          body: ProfileScreen(
            profileRepository: _profileRepository,
            profileId: profileId,
          ),
        ),
      ),
    );
  }

  Future<void> _refreshFixture({bool quiet = false}) async {
    if (_isRefreshing) return;
    if (!quiet) {
      setState(() => _errorText = null);
    }
    _isRefreshing = true;

    try {
      final fixture =
          await (widget.refreshFixture?.call() ??
              widget.fixtureRepository.getFixture(_fixture.id));
      if (!mounted) return;
      setState(() {
        _fixture = fixture;
        _didChange = true;
      });
      _configureRefreshTimer();
    } catch (error) {
      if (!mounted || quiet) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not refresh this match. Try again.',
        ),
      );
    } finally {
      _isRefreshing = false;
    }
  }

  void _configureRefreshTimer() {
    _refreshTimer?.cancel();
    if (_fixture.isLive) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _refreshFixture(quiet: true),
      );
      return;
    }
    if (_fixture.status == FixtureStatus.scheduled) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _refreshFixture(quiet: true),
      );
      return;
    }
    if (_fixture.broadcast?.shouldPoll == true) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _refreshFixture(quiet: true),
      );
    }
  }

  Widget _buildSelectedSection() {
    return switch (_selectedSection) {
      _FixtureDetailSection.watch => _BroadcastPanel(fixture: _fixture),
      _FixtureDetailSection.timeline => Column(
        children: [
          _InfoGrid(fixture: _fixture),
          if (_canSeePayments) ...[
            const SizedBox(height: 18),
            _TeamPaymentsPanel(
              fixture: _fixture,
              onOpenProfile: _openPlayerProfile,
            ),
          ],
          if (_fixture.isFinal && widget.playerRatingUpdate != null) ...[
            const SizedBox(height: 18),
            _PlayerRatingUpdateCard(update: widget.playerRatingUpdate!),
          ],
          if (_fixture.isFinal &&
              (_fixture.homeSrChange != null ||
                  _fixture.awaySrChange != null)) ...[
            const SizedBox(height: 18),
            _RatingUpdates(fixture: _fixture),
          ],
          const SizedBox(height: 18),
          if (_fixture.timeline.isEmpty)
            const _EmptyFixtureSection(
              icon: Icons.timeline_rounded,
              title: 'No timeline yet',
              message: 'Match events will appear here as the game is played.',
            )
          else
            _MatchTimeline(
              fixture: _fixture,
              onOpenProfile: _openPlayerProfile,
            ),
        ],
      ),
      _FixtureDetailSection.lineups =>
        _fixture.homeLineup.isEmpty && _fixture.awayLineup.isEmpty
            ? const _EmptyFixtureSection(
                icon: Icons.groups_2_rounded,
                title: 'Lineups not available yet',
                message:
                    'The team formations will appear here once players are assigned.',
              )
            : _FormationLineupsPanel(
                fixture: _fixture,
                onOpenProfile: _openPlayerProfile,
              ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final bottomAction = _fixture.isOpen
        ? _JoinActionBar(
            canJoin: _canJoin,
            isJoining: _isJoining,
            onJoin: _joinFixture,
          )
        : _canShowCompleteAction
        ? _CompleteActionBar(
            canComplete: _canComplete,
            isCompleting: _isCompleting,
            onComplete: _completeFixture,
          )
        : null;

    final title = widget.sourceLabel == null
        ? 'Match Details'
        : '${widget.sourceLabel} Match';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: fieldBackground,
        body: FieldHeaderOverlay(
          header: _FixtureDetailHeader(
            title: title,
            onBack: () => Navigator.of(context).pop(_didChange),
          ),
          child: ListView(
            padding: EdgeInsets.only(bottom: bottomAction == null ? 32 : 116),
            children: [
              SizedBox(
                width: double.infinity,
                child: _Scoreboard(
                  fixture: _fixture,
                  sourceLabel: widget.sourceLabel,
                  showTeamRatings: widget.showTeamRatings,
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _FixtureSectionSwitcher(
                  selected: _selectedSection,
                  onSelected: (section) {
                    if (_selectedSection == section) return;
                    setState(() => _selectedSection = section);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    if (_errorText != null) ...[
                      const SizedBox(height: 14),
                      _ErrorCallout(message: _errorText!),
                    ],
                    if (_fixture.isCancelled) ...[
                      const SizedBox(height: 18),
                      _CancellationPanel(fixture: _fixture),
                    ],
                    const SizedBox(height: 18),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: KeyedSubtree(
                        key: ValueKey(_selectedSection),
                        child: _buildSelectedSection(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: bottomAction,
      ),
    );
  }
}

class _FixtureDetailHeader extends StatelessWidget {
  const _FixtureDetailHeader({required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Container(
      key: const ValueKey('fixture-detail-header'),
      height: topInset + 64,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.42),
            Colors.black.withValues(alpha: 0.12),
            Colors.transparent,
          ],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, topInset, 16, 0),
      child: Row(
        children: [
          Material(
            color: Colors.white.withValues(alpha: 0.13),
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onBack,
              customBorder: const CircleBorder(),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.24),
                  ),
                ),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  color: Colors.white,
                  size: 21,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const SizedBox(
            width: 4,
            height: 25,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [fieldEmerald500, fieldBlue600],
                ),
                borderRadius: BorderRadius.all(Radius.circular(99)),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FixtureSectionSwitcher extends StatelessWidget {
  const _FixtureSectionSwitcher({
    required this.selected,
    required this.onSelected,
  });

  final _FixtureDetailSection selected;
  final ValueChanged<_FixtureDetailSection> onSelected;

  @override
  Widget build(BuildContext context) {
    const items = [
      (_FixtureDetailSection.watch, Icons.play_circle_outline_rounded, 'WATCH'),
      (_FixtureDetailSection.timeline, Icons.timeline_rounded, 'TIMELINE'),
      (_FixtureDetailSection.lineups, Icons.groups_2_rounded, 'LINEUPS'),
    ];

    return Container(
      key: const ValueKey('fixture-main-switcher'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: fieldGray100,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: _FixtureSectionButton(
                icon: item.$2,
                label: item.$3,
                selected: selected == item.$1,
                onTap: () => onSelected(item.$1),
              ),
            ),
        ],
      ),
    );
  }
}

class _FixtureSectionButton extends StatelessWidget {
  const _FixtureSectionButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('fixture-section-${label.toLowerCase()}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x12111827),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? fieldEmerald600 : fieldGray500,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: selected ? fieldGray900 : fieldGray500,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyFixtureSection extends StatelessWidget {
  const _EmptyFixtureSection({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, color: fieldGray400, size: 28),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 12,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Scoreboard extends StatelessWidget {
  const _Scoreboard({
    required this.fixture,
    required this.sourceLabel,
    required this.showTeamRatings,
  });

  final Fixture fixture;
  final String? sourceLabel;
  final bool showTeamRatings;

  @override
  Widget build(BuildContext context) {
    final homeWin =
        fixture.isFinal &&
        fixture.homeScore != null &&
        fixture.awayScore != null &&
        fixture.homeScore! > fixture.awayScore!;
    final awayWin =
        fixture.isFinal &&
        fixture.homeScore != null &&
        fixture.awayScore != null &&
        fixture.awayScore! > fixture.homeScore!;

    return Container(
      key: const ValueKey('fixture-scoreboard'),
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        22,
        fieldPageHeaderExtent(context) + 38,
        22,
        22,
      ),
      decoration: BoxDecoration(
        gradient: const RadialGradient(
          center: Alignment(0.8, -0.8),
          radius: 1.4,
          colors: [Color(0xFF374151), Color(0xFF111827), Color(0xFF000000)],
          stops: [0, 0.52, 1],
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(26)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            top: -54,
            right: -54,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fieldEmerald500.withValues(alpha: 0.10),
              ),
            ),
          ),
          Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (sourceLabel != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        sourceLabel!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: fixture.isLive
                          ? const Color(0xFFEF4444)
                          : fixture.isFinal
                          ? Colors.white.withValues(alpha: 0.18)
                          : fieldEmerald600,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      fixture.detailStatusLabel.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
              if (fixture.isLive) ...[
                const SizedBox(height: 10),
                _LiveMinutePill(clock: fixture.clock),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _ScoreboardClan(
                      clan: fixture.homeClan,
                      winner: homeWin,
                      showRating: showTeamRatings,
                      averagePlayerRating: fixture.homeAveragePlayerRating,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: fixture.isFinal || fixture.isLive
                        ? Row(
                            children: [
                              _ScoreNumber(
                                value: fixture.homeScore ?? 0,
                                highlight: homeWin,
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8),
                                child: Text(
                                  '-',
                                  style: TextStyle(
                                    color: fieldGray500,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              _ScoreNumber(
                                value: fixture.awayScore ?? 0,
                                highlight: awayWin,
                              ),
                            ],
                          )
                        : Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 15,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: const Text(
                              'VS',
                              style: TextStyle(
                                color: fieldGray400,
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                  ),
                  Expanded(
                    child: fixture.awayClan == null
                        ? const _TbdClan()
                        : _ScoreboardClan(
                            clan: fixture.awayClan!,
                            winner: awayWin,
                            showRating: showTeamRatings,
                            averagePlayerRating:
                                fixture.awayAveragePlayerRating,
                          ),
                  ),
                ],
              ),
              if (fixture.matchAveragePlayerRating != null) ...[
                const SizedBox(height: 18),
                _MatchAverageRatingPill(
                  average: fixture.matchAveragePlayerRating!,
                  spread: fixture.teamRatingSpread,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ScoreboardClan extends StatelessWidget {
  const _ScoreboardClan({
    required this.clan,
    required this.winner,
    required this.showRating,
    required this.averagePlayerRating,
  });

  final FixtureClan clan;
  final bool winner;
  final bool showRating;
  final int? averagePlayerRating;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FixtureClanAvatar(clan: clan, size: 64),
        const SizedBox(height: 10),
        Text(
          clan.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: winner ? const Color(0xFFA7F3D0) : Colors.white,
            fontSize: 13,
            height: 1.1,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (averagePlayerRating case final rating?) ...[
          const SizedBox(height: 8),
          Text(
            '$rating AVG PLAYER RATING',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldEmerald200,
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 10),
        ] else if (showRating) ...[
          const SizedBox(height: 8),
          TierBadge(rank: clan.rank, small: true),
          const SizedBox(height: 6),
          Text(
            '${clan.skillRating} SR${clan.regionRank == null ? '' : ' · ${_regionName(clan.region)} #${clan.regionRank}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray400,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ] else
          const SizedBox(height: 10),
      ],
    );
  }
}

class _MatchAverageRatingPill extends StatelessWidget {
  const _MatchAverageRatingPill({required this.average, required this.spread});

  final int average;
  final int? spread;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'MATCH AVG $average SR${spread == null ? '' : '  ·  $spread SR SPREAD'}',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _TbdClan extends StatelessWidget {
  const _TbdClan();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.shield_rounded, color: fieldGray400),
        ),
        const SizedBox(height: 10),
        const Text(
          'TBD',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 44),
      ],
    );
  }
}

class _ScoreNumber extends StatelessWidget {
  const _ScoreNumber({required this.value, required this.highlight});

  final int value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Text(
      value.toString(),
      style: TextStyle(
        color: highlight ? const Color(0xFF34D399) : Colors.white,
        fontSize: 40,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class _LiveMinutePill extends StatefulWidget {
  const _LiveMinutePill({required this.clock});

  final FixtureClock? clock;

  @override
  State<_LiveMinutePill> createState() => _LiveMinutePillState();
}

class _LiveMinutePillState extends State<_LiveMinutePill> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _LiveMinutePill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    if (widget.clock?.isRunning ?? false) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = widget.clock?.elapsedSeconds() ?? 0;
    final minute = elapsed == 0 ? 0 : (elapsed ~/ 60) + 1;
    final label = widget.clock?.isRunning ?? false
        ? 'LIVE $minute\''
        : '$minute\'';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _MatchTimeline extends StatelessWidget {
  const _MatchTimeline({required this.fixture, required this.onOpenProfile});

  final Fixture fixture;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final events = fixture.timeline.take(18).toList();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.timeline_rounded, color: fieldBlue600),
              SizedBox(width: 8),
              Text(
                'TIMELINE',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (final event in events) ...[
            _TimelineRow(
              fixture: fixture,
              event: event,
              onOpenProfile: onOpenProfile,
            ),
            if (event != events.last) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.fixture,
    required this.event,
    required this.onOpenProfile,
  });

  final Fixture fixture;
  final FixtureTimelineEvent event;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final eventStyle = _timelineEventStyle(event.eventType);
    final title = _timelineTitle(event);
    final subtitle = _timelineSubtitle(fixture, event);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: eventStyle.background,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(eventStyle.icon, color: eventStyle.color, size: 19),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: event.profileId == null
                    ? null
                    : () => onOpenProfile(event.profileId!),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: event.profileId == null
                          ? fieldGray900
                          : fieldBlue600,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              InkWell(
                onTap: event.assistProfileId == null
                    ? null
                    : () => onOpenProfile(event.assistProfileId!),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: event.assistProfileId == null
                          ? fieldGray500
                          : fieldBlue600,
                      fontSize: 12,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          event.minute == 0
              ? '0:00'
              : '${event.minute}:${event.second.toString().padLeft(2, '0')}',
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _InfoGrid extends StatelessWidget {
  const _InfoGrid({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _InfoTile(
                icon: Icons.calendar_month_rounded,
                iconColor: fieldEmerald600,
                iconBackground: const Color(0xFFECFDF5),
                label: fixture.day,
                value: fixture.monthDay,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _InfoTile(
                icon: Icons.access_time_rounded,
                iconColor: fieldBlue600,
                iconBackground: const Color(0xFFEFF6FF),
                label: 'Time',
                value: fixture.timeSlot.split(' - ').first,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _InfoTile(
          icon: Icons.location_on_rounded,
          iconColor: const Color(0xFFD97706),
          iconBackground: const Color(0xFFFFFBEB),
          label: 'Venue',
          value: fixture.venue,
        ),
      ],
    );
  }
}

class _FormationLineupsPanel extends StatelessWidget {
  const _FormationLineupsPanel({
    required this.fixture,
    required this.onOpenProfile,
  });

  final Fixture fixture;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final homePlayers = _visibleLineup(fixture.homeLineup);
    final awayPlayers = _visibleLineup(fixture.awayLineup);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D111827),
            blurRadius: 12,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.groups_2_rounded, color: fieldBlue600, size: 19),
              SizedBox(width: 8),
              Text(
                'TEAM LINEUPS',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            fixture.teamRatingSpread == null
                ? 'Both 7-a-side formations, including each keeper.'
                : 'Balanced to a ${fixture.teamRatingSpread} SR average spread.',
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          AspectRatio(
            aspectRatio: 0.5,
            child: _FormationPitch(
              homeName: fixture.homeClan.name,
              awayName: fixture.awayClan?.name ?? 'Away Team',
              homeAverage: fixture.homeAveragePlayerRating,
              awayAverage: fixture.awayAveragePlayerRating,
              homePlayers: _formationEntries(homePlayers),
              awayPlayers: _formationEntries(awayPlayers),
              onOpenProfile: onOpenProfile,
            ),
          ),
        ],
      ),
    );
  }
}

class _FormationPitch extends StatelessWidget {
  const _FormationPitch({
    required this.homeName,
    required this.awayName,
    required this.homeAverage,
    required this.awayAverage,
    required this.homePlayers,
    required this.awayPlayers,
    required this.onOpenProfile,
  });

  final String homeName;
  final String awayName;
  final int? homeAverage;
  final int? awayAverage;
  final List<_FormationEntry> homePlayers;
  final List<_FormationEntry> awayPlayers;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      key: const ValueKey('fixture-formation-pitch'),
      borderRadius: BorderRadius.circular(22),
      child: CustomPaint(
        painter: const _PitchPainter(),
        child: Stack(
          children: [
            Positioned(
              top: 13,
              left: 13,
              right: 13,
              child: _PitchTeamLabel(
                name: homeName,
                averageRating: homeAverage,
                alignRight: false,
              ),
            ),
            Positioned.fill(
              top: 44,
              bottom: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7),
                child: Column(
                  children: [
                    Expanded(
                      child: _TeamFormation(
                        entries: homePlayers,
                        direction: _FormationDirection.down,
                        onOpenProfile: onOpenProfile,
                      ),
                    ),
                    Expanded(
                      child: _TeamFormation(
                        entries: awayPlayers,
                        direction: _FormationDirection.up,
                        onOpenProfile: onOpenProfile,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 13,
              left: 13,
              right: 13,
              child: _PitchTeamLabel(
                name: awayName,
                averageRating: awayAverage,
                alignRight: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _FormationDirection { down, up }

class _TeamFormation extends StatelessWidget {
  const _TeamFormation({
    required this.entries,
    required this.direction,
    required this.onOpenProfile,
  });

  final List<_FormationEntry> entries;
  final _FormationDirection direction;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Text(
          'LINEUP PENDING',
          style: TextStyle(
            color: Color(0xBFFFFFFF),
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
          ),
        ),
      );
    }

    const orderedRoles = ['GK', 'DEF', 'MID', 'ATT'];
    final roles = direction == _FormationDirection.down
        ? orderedRoles
        : orderedRoles.reversed.toList();

    return Column(
      children: [
        for (final role in roles)
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final entry in entries.where(
                  (entry) => entry.role == role,
                ))
                  _FormationPlayerMarker(
                    entry: entry,
                    onTap: () => onOpenProfile(entry.player.id),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FormationPlayerMarker extends StatelessWidget {
  const _FormationPlayerMarker({required this.entry, required this.onTap});

  final _FormationEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final player = entry.player;
    final avatarUrl = player.avatarUrl?.trim();
    final rating = player.displayedRating;
    return SizedBox(
      width: 96,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: player.isMe ? fieldEmerald200 : Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x35111827),
                        blurRadius: 5,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: CircleAvatar(
                    radius: 22,
                    backgroundColor: player.side.toUpperCase() == 'AWAY'
                        ? fieldGray900
                        : fieldGray100,
                    backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                        ? NetworkImage(avatarUrl)
                        : null,
                    child: avatarUrl != null && avatarUrl.isNotEmpty
                        ? null
                        : Text(
                            player.initials,
                            style: TextStyle(
                              color: player.side.toUpperCase() == 'AWAY'
                                  ? Colors.white
                                  : fieldGray700,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  player.isMe
                      ? '${player.displayName} (You)'
                      : player.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    shadows: [Shadow(color: Color(0x80111827), blurRadius: 3)],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  rating == null ? entry.role : '${entry.role} · $rating SR',
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    shadows: [Shadow(color: Color(0x80111827), blurRadius: 2)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PitchTeamLabel extends StatelessWidget {
  const _PitchTeamLabel({
    required this.name,
    required this.averageRating,
    required this.alignRight,
  });

  final String name;
  final int? averageRating;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xC9111827),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '${name.toUpperCase()}${averageRating == null ? '' : ' · $averageRating AVG SR'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

class _PitchPainter extends CustomPainter {
  const _PitchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = const Color(0xFF07845F));

    final stripePaint = Paint()..color = Colors.white.withValues(alpha: 0.055);
    final stripeHeight = size.height / 8;
    for (var index = 0; index < 8; index += 2) {
      canvas.drawRect(
        Rect.fromLTWH(0, index * stripeHeight, size.width, stripeHeight),
        stripePaint,
      );
    }

    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.52)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final inset = Rect.fromLTWH(14, 14, size.width - 28, size.height - 28);
    canvas.drawRRect(
      RRect.fromRectAndRadius(inset, const Radius.circular(16)),
      linePaint,
    );
    canvas.drawLine(
      Offset(14, size.height / 2),
      Offset(size.width - 14, size.height / 2),
      linePaint,
    );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width * 0.16,
      linePaint,
    );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      2.2,
      Paint()..color = Colors.white.withValues(alpha: 0.62),
    );
    final boxWidth = size.width * 0.48;
    final boxHeight = size.height * 0.12;
    canvas.drawRect(
      Rect.fromLTWH((size.width - boxWidth) / 2, 14, boxWidth, boxHeight),
      linePaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        (size.width - boxWidth) / 2,
        size.height - 14 - boxHeight,
        boxWidth,
        boxHeight,
      ),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _PitchPainter oldDelegate) => false;
}

class _FormationEntry {
  const _FormationEntry({required this.player, required this.role});

  final FixtureLineupPlayer player;
  final String role;
}

List<FixtureLineupPlayer> _visibleLineup(List<FixtureLineupPlayer> players) {
  final played = players.where((player) => player.played).toList();
  final visible = played.isEmpty ? players : played;
  return visible.take(7).toList();
}

List<_FormationEntry> _formationEntries(List<FixtureLineupPlayer> players) {
  const fallback = ['GK', 'DEF', 'DEF', 'MID', 'MID', 'ATT', 'ATT'];
  return [
    for (var index = 0; index < players.length; index++)
      _FormationEntry(
        player: players[index],
        role: _formationRole(
          players[index].role,
          fallback[index % fallback.length],
        ),
      ),
  ];
}

String _formationRole(String rawRole, String fallback) {
  final role = rawRole.trim().toUpperCase();
  if (role == 'GK' || role.contains('GOALKEEP')) return 'GK';
  if (role == 'DEF' || role.contains('DEFEND')) return 'DEF';
  if (role == 'MID' || role.contains('MIDFIELD')) return 'MID';
  if (role == 'ATT' || role.contains('ATTACK') || role.contains('FORWARD')) {
    return 'ATT';
  }
  return fallback;
}

class _CancellationPanel extends StatelessWidget {
  const _CancellationPanel({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
    final actorName = fixture.cancellationActor?.displayName;
    final actorLabel = actorName == null || actorName.trim().isEmpty
        ? fixture.cancellationCode == 'NO_OPPONENT_24H'
              ? 'Automatic cancellation'
              : 'Cancellation source not recorded'
        : 'Cancelled by $actorName';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        border: Border.all(color: const Color(0xFFFED7AA)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEDD5),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.event_busy_rounded,
                  color: Color(0xFFEA580C),
                  size: 21,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  fixture.cancellationTitle,
                  style: const TextStyle(
                    color: Color(0xFF9A3412),
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            fixture.cancellationDisplayReason,
            style: const TextStyle(
              color: Color(0xFF7C2D12),
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 13),
          const Divider(height: 1, color: Color(0xFFFED7AA)),
          const SizedBox(height: 11),
          Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                color: Color(0xFFC2410C),
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  actorLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9A3412),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (fixture.cancelledAt != null)
                Text(
                  _cancellationTimestamp(fixture.cancelledAt!),
                  style: const TextStyle(
                    color: Color(0xFF9A3412),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _cancellationTimestamp(DateTime value) {
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
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${months[local.month - 1]} ${local.day}, $hour:$minute $period';
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fieldGray500,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
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

class _TeamPaymentsPanel extends StatelessWidget {
  const _TeamPaymentsPanel({
    required this.fixture,
    required this.onOpenProfile,
  });

  final Fixture fixture;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.receipt_long_rounded, color: fieldEmerald600),
              SizedBox(width: 8),
              Text(
                'TEAM PAYMENTS',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Spacer(),
              Text(
                '20 BHD EACH',
                style: TextStyle(
                  color: fieldGray500,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _PaymentRow(
            clan: fixture.homeClan,
            payer: fixture.homePayer,
            paidAt: fixture.homePaidAt,
            onOpenProfile: onOpenProfile,
          ),
          if (fixture.awayClan != null) ...[
            const Divider(height: 22, color: fieldGray100),
            _PaymentRow(
              clan: fixture.awayClan!,
              payer: fixture.awayPayer,
              paidAt: fixture.awayPaidAt,
              onOpenProfile: onOpenProfile,
            ),
          ],
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({
    required this.clan,
    required this.payer,
    required this.paidAt,
    required this.onOpenProfile,
  });

  final FixtureClan clan;
  final FixtureParticipant? payer;
  final DateTime? paidAt;
  final ValueChanged<String> onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final hasPayer = payer != null && payer!.id.isNotEmpty;
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFECFDF5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(clan.emblem, style: const TextStyle(fontSize: 23)),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                clan.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              InkWell(
                onTap: hasPayer ? () => onOpenProfile(payer!.id) : null,
                borderRadius: BorderRadius.circular(5),
                child: Text(
                  hasPayer
                      ? 'Paid by ${payer!.displayName}'
                      : 'Payment not recorded',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasPayer ? fieldBlue600 : fieldGray500,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (paidAt != null)
          Text(
            _shortPaymentDate(paidAt!),
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
  }
}

String _shortPaymentDate(DateTime value) {
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
  return '${months[local.month - 1]} ${local.day}';
}

class _PlayerRatingUpdateCard extends StatelessWidget {
  const _PlayerRatingUpdateCard({required this.update});

  final FixturePlayerRatingUpdate update;

  @override
  Widget build(BuildContext context) {
    final change = update.ratingChange;
    final positive = change > 0;
    final negative = change < 0;
    final changeColor = positive
        ? fieldEmerald600
        : negative
        ? const Color(0xFFDC2626)
        : fieldGray500;
    final changeBackground = positive
        ? fieldEmerald50
        : negative
        ? const Color(0xFFFEF2F2)
        : fieldGray100;
    final result = update.result?.trim().toUpperCase();

    return Container(
      key: const ValueKey('fixture-player-rating-update'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.trending_up_rounded,
                color: fieldBlue600,
                size: 22,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'PLAYER RATING UPDATE',
                  style: TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (result != null && result.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: switch (result) {
                      'WIN' => fieldEmerald50,
                      'LOSS' => const Color(0xFFFEF2F2),
                      _ => fieldGray100,
                    },
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    result,
                    style: TextStyle(
                      color: switch (result) {
                        'WIN' => fieldEmerald700,
                        'LOSS' => const Color(0xFFDC2626),
                        _ => fieldGray600,
                      },
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _PlayerRatingValue(label: 'BEFORE', value: update.ratingBefore),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: fieldGray300,
                  size: 20,
                ),
              ),
              _PlayerRatingValue(label: 'AFTER', value: update.ratingAfter),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: changeBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${change > 0 ? '+' : ''}$change SR',
                  style: TextStyle(
                    color: changeColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayerRatingValue extends StatelessWidget {
  const _PlayerRatingValue({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: fieldGray400,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '$value',
          style: const TextStyle(
            color: fieldGray900,
            fontSize: 20,
            height: 1,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _RatingUpdates extends StatelessWidget {
  const _RatingUpdates({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.emoji_events_rounded, color: Color(0xFFF59E0B)),
              SizedBox(width: 8),
              Text(
                'RATING UPDATES',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _SrChangeTile(
                  clan: fixture.homeClan,
                  change: fixture.homeSrChange ?? 0,
                ),
              ),
              Container(width: 1, height: 46, color: fieldGray100),
              Expanded(
                child: _SrChangeTile(
                  clan: fixture.awayClan,
                  change: fixture.awaySrChange ?? 0,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SrChangeTile extends StatelessWidget {
  const _SrChangeTile({required this.clan, required this.change});

  final FixtureClan? clan;
  final int change;

  @override
  Widget build(BuildContext context) {
    final positive = change >= 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            clan?.name ?? 'TBD',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Icon(
                positive
                    ? Icons.trending_up_rounded
                    : Icons.trending_down_rounded,
                color: positive ? fieldEmerald600 : const Color(0xFFEF4444),
                size: 18,
              ),
              const SizedBox(width: 4),
              Text(
                '${positive ? '+' : ''}$change SR',
                style: TextStyle(
                  color: positive ? fieldEmerald600 : const Color(0xFFEF4444),
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BroadcastPanel extends StatefulWidget {
  const _BroadcastPanel({required this.fixture});

  final Fixture fixture;

  @override
  State<_BroadcastPanel> createState() => _BroadcastPanelState();
}

enum _CompletedVideoView { highlights, fullGame }

class _BroadcastPanelState extends State<_BroadcastPanel> {
  VideoPlayerController? _controller;
  Timer? _retryTimer;
  String? _loadedUrl;
  String? _playerError;
  bool _isLoading = false;
  bool _isAdvancingHighlight = false;
  int _activeHighlightIndex = 0;
  int _playerLoadGeneration = 0;
  Duration _fullGamePosition = Duration.zero;
  _CompletedVideoView _completedView = _CompletedVideoView.highlights;
  late List<FixtureHighlightMoment> _highlightMoments;

  Fixture get fixture => widget.fixture;

  bool get _showHighlights {
    return fixture.isFinal && _completedView == _CompletedVideoView.highlights;
  }

  @override
  void initState() {
    super.initState();
    _highlightMoments = _highlightMomentsFor(fixture);
    unawaited(_syncPlayer());
  }

  @override
  void didUpdateWidget(covariant _BroadcastPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldHighlightSignature = _highlightSignature(_highlightMoments);
    _highlightMoments = _highlightMomentsFor(fixture);
    final highlightsChanged =
        oldHighlightSignature != _highlightSignature(_highlightMoments);
    if (!oldWidget.fixture.isFinal && widget.fixture.isFinal) {
      _completedView = _CompletedVideoView.highlights;
      _activeHighlightIndex = 0;
      _fullGamePosition = Duration.zero;
    }
    final oldUrl = _playbackUrl(oldWidget.fixture);
    final nextUrl = _playbackUrl(widget.fixture);
    if (oldUrl != nextUrl ||
        oldWidget.fixture.broadcast?.status !=
            widget.fixture.broadcast?.status) {
      unawaited(_syncPlayer(force: oldUrl == nextUrl));
    } else if (highlightsChanged && _showHighlights) {
      unawaited(_resetHighlightPlayback());
    }
  }

  @override
  void dispose() {
    _playerLoadGeneration += 1;
    _retryTimer?.cancel();
    final controller = _controller;
    controller?.removeListener(_handlePlaybackTick);
    unawaited(controller?.dispose());
    super.dispose();
  }

  Future<void> _syncPlayer({bool force = false}) async {
    final loadGeneration = ++_playerLoadGeneration;
    final url = _playbackUrl(fixture);
    if (url == null) {
      _retryTimer?.cancel();
      final previous = _controller;
      previous?.removeListener(_handlePlaybackTick);
      _controller = null;
      _loadedUrl = null;
      if (previous != null) await previous.dispose();
      if (mounted && loadGeneration == _playerLoadGeneration) {
        setState(() {
          _isLoading = false;
          _playerError = null;
        });
      }
      return;
    }

    if (!force &&
        _loadedUrl == url &&
        _controller?.value.isInitialized == true) {
      return;
    }

    _retryTimer?.cancel();
    final previous = _controller;
    previous?.removeListener(_handlePlaybackTick);
    _controller = null;
    _loadedUrl = null;
    if (previous != null) await previous.dispose();
    if (!mounted || loadGeneration != _playerLoadGeneration) return;
    setState(() {
      _isLoading = true;
      _playerError = null;
    });

    final next = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await next.initialize();
      await next.setLooping(false);
      if (!mounted ||
          loadGeneration != _playerLoadGeneration ||
          _playbackUrl(fixture) != url) {
        await next.dispose();
        return;
      }
      _highlightMoments = _highlightMomentsFor(fixture, next);
      if (_showHighlights) {
        _activeHighlightIndex = 0;
        final highlights = _availableHighlights(next);
        if (highlights.isNotEmpty) {
          await next.seekTo(highlights.first.start);
        }
      } else if (fixture.isFinal) {
        await next.seekTo(_boundedPosition(_fullGamePosition, next));
      }
      if (!mounted || loadGeneration != _playerLoadGeneration) {
        await next.dispose();
        return;
      }
      next.addListener(_handlePlaybackTick);
      setState(() {
        _controller = next;
        _loadedUrl = url;
        _isLoading = false;
      });
    } catch (_) {
      await next.dispose();
      if (!mounted || loadGeneration != _playerLoadGeneration) return;
      setState(() {
        _isLoading = false;
        _playerError = _playerFailureMessage;
      });
      if (fixture.broadcast?.shouldPoll == true || fixture.isFinal) {
        _retryTimer = Timer(
          const Duration(seconds: 10),
          () => unawaited(_syncPlayer(force: true)),
        );
      }
    }
  }

  String? _playbackUrl(Fixture value) {
    if (value.isLive) return value.livePlaybackUrl;
    if (value.isFinal) return value.fullGamePlaybackUrl;
    return null;
  }

  String get _playerFailureMessage {
    if (fixture.isLive) return 'The live stream is not ready yet.';
    if (_showHighlights) return 'Highlights are still loading.';
    return 'The full game replay is still loading.';
  }

  List<FixtureHighlightMoment> _availableHighlights(
    VideoPlayerController? controller,
  ) {
    if (controller?.value.isInitialized != true ||
        controller!.value.duration <= Duration.zero) {
      return _highlightMoments;
    }
    return _highlightMoments
        .where((moment) => moment.start < controller.value.duration)
        .toList(growable: false);
  }

  List<FixtureHighlightMoment> _highlightMomentsFor(
    Fixture value, [
    VideoPlayerController? controller,
  ]) {
    final playbackController = controller ?? _controller;
    if (playbackController?.value.isInitialized == true &&
        playbackController!.value.duration > Duration.zero) {
      return value.highlightMomentsForReplay(playbackController.value.duration);
    }
    return value.highlightMoments;
  }

  String _highlightSignature(List<FixtureHighlightMoment> moments) {
    return moments
        .map(
          (moment) =>
              '${moment.event.id}:${moment.start.inMilliseconds}:${moment.end.inMilliseconds}',
        )
        .join('|');
  }

  Future<void> _resetHighlightPlayback() async {
    final controller = _controller;
    if (controller?.value.isInitialized != true) {
      if (_playbackUrl(fixture) != null) {
        unawaited(_syncPlayer(force: true));
      }
      return;
    }
    await _playHighlightAt(0, autoplay: controller!.value.isPlaying);
  }

  Future<void> _playHighlightAt(
    int requestedIndex, {
    bool autoplay = true,
  }) async {
    if (_isAdvancingHighlight) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final highlights = _availableHighlights(controller);
    if (highlights.isEmpty) return;
    final index = requestedIndex.clamp(0, highlights.length - 1);

    _isAdvancingHighlight = true;
    try {
      if (controller.value.isPlaying) await controller.pause();
      if (!mounted || controller != _controller) return;
      setState(() => _activeHighlightIndex = index);
      await controller.seekTo(
        _boundedPosition(highlights[index].start, controller),
      );
      if (!mounted || controller != _controller) return;
      if (autoplay) await controller.play();
    } finally {
      _isAdvancingHighlight = false;
    }
  }

  Duration _boundedPosition(
    Duration position,
    VideoPlayerController controller,
  ) {
    if (position.isNegative) return Duration.zero;
    final duration = controller.value.duration;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  Future<void> _selectCompletedView(_CompletedVideoView view) async {
    if (!fixture.isFinal || view == _completedView) return;

    final controller = _controller;
    if (_completedView == _CompletedVideoView.fullGame &&
        controller?.value.isInitialized == true) {
      _fullGamePosition = controller!.value.position;
    }
    if (controller?.value.isPlaying == true) await controller!.pause();
    if (!mounted) return;

    setState(() {
      _completedView = view;
      _activeHighlightIndex = 0;
      _playerError = null;
    });

    if (controller?.value.isInitialized != true) return;
    if (view == _CompletedVideoView.highlights) {
      await _playHighlightAt(0, autoplay: false);
    } else {
      await controller!.seekTo(_boundedPosition(_fullGamePosition, controller));
    }
  }

  void _handlePlaybackTick() {
    final controller = _controller;
    if (!_showHighlights ||
        _isAdvancingHighlight ||
        controller == null ||
        !controller.value.isInitialized ||
        !controller.value.isPlaying) {
      return;
    }

    final highlights = _availableHighlights(controller);
    if (highlights.isEmpty) return;
    final index = _activeHighlightIndex.clamp(0, highlights.length - 1);
    final end = _boundedPosition(highlights[index].end, controller);
    if (controller.value.position + const Duration(milliseconds: 250) < end) {
      return;
    }
    unawaited(_advanceHighlight(controller, highlights, index));
  }

  Future<void> _advanceHighlight(
    VideoPlayerController controller,
    List<FixtureHighlightMoment> highlights,
    int currentIndex,
  ) async {
    if (_isAdvancingHighlight) return;
    if (currentIndex < highlights.length - 1) {
      await _playHighlightAt(currentIndex + 1);
      return;
    }

    _isAdvancingHighlight = true;
    try {
      await controller.pause();
      await controller.seekTo(
        _boundedPosition(highlights[currentIndex].end, controller),
      );
    } finally {
      _isAdvancingHighlight = false;
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      if (_showHighlights) {
        final highlights = _availableHighlights(controller);
        if (highlights.isEmpty) return;
        final index = _activeHighlightIndex.clamp(0, highlights.length - 1);
        final end = _boundedPosition(highlights[index].end, controller);
        if (controller.value.position + const Duration(milliseconds: 250) >=
            end) {
          final nextIndex = index == highlights.length - 1 ? 0 : index + 1;
          await _playHighlightAt(nextIndex);
          return;
        }
      }
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _openFullscreen() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _FullscreenVideoPage(
          controller: controller,
          allowSeeking: fixture.isFinal && !_showHighlights,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isLive = fixture.isLive;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(15),
            child: Row(
              children: [
                Icon(
                  Icons.play_circle_rounded,
                  color: isLive ? const Color(0xFFEF4444) : fieldEmerald600,
                ),
                const SizedBox(width: 8),
                Text(
                  isLive
                      ? 'LIVE STREAM'
                      : fixture.isFinal
                      ? 'WATCH MATCH'
                      : 'MATCH VIDEO',
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                if (isLive) ...[
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(
                        color: Color(0xFFDC2626),
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (fixture.isFinal) ...[
            const Divider(height: 1, color: fieldGray100),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<_CompletedVideoView>(
                  key: const ValueKey('completed-video-switcher'),
                  showSelectedIcon: false,
                  expandedInsets: EdgeInsets.zero,
                  segments: const [
                    ButtonSegment<_CompletedVideoView>(
                      value: _CompletedVideoView.highlights,
                      label: Text('Highlights'),
                    ),
                    ButtonSegment<_CompletedVideoView>(
                      value: _CompletedVideoView.fullGame,
                      label: Text('Full Game'),
                    ),
                  ],
                  selected: {_completedView},
                  onSelectionChanged: (selection) {
                    unawaited(_selectCompletedView(selection.first));
                  },
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: fieldGray900,
                    selectedForegroundColor: Colors.white,
                    backgroundColor: Colors.white,
                    foregroundColor: fieldGray700,
                    side: const BorderSide(color: fieldGray200),
                    textStyle: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
          ],
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(color: fieldGray900, child: _buildPlayerBody()),
          ),
          if (fixture.isFinal) _buildCompletedPlaybackControls(),
          if (!fixture.isFinal && !fixture.isCancelled)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              color: const Color(0xFFF9FAFB),
              child: const Row(
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 17,
                    color: fieldGray500,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Highlights will be available after the game',
                      style: TextStyle(
                        color: fieldGray500,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
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

  Widget _buildPlayerBody() {
    final isLive = fixture.isLive;
    final isProcessing =
        fixture.broadcast?.isProcessing == true ||
        fixture.broadcast?.isStopping == true;
    final controller = _controller;
    final highlights = _availableHighlights(controller);
    final hasNoUsableHighlights =
        _highlightMoments.isEmpty ||
        (controller?.value.isInitialized == true && highlights.isEmpty);

    if (_showHighlights && hasNoUsableHighlights) {
      final recordedGoals = fixture.timeline.where((event) {
        return event.eventType.toUpperCase() == 'GOAL' &&
            event.note?.toLowerCase() != 'admin correction';
      }).length;
      final isWaitingForHighlightTiming =
          recordedGoals > 0 && isProcessing && _highlightMoments.isEmpty;
      return _buildEmptyState(
        icon: Icons.auto_awesome_rounded,
        title: isWaitingForHighlightTiming
            ? 'Preparing highlights...'
            : recordedGoals == 0
            ? 'No goal highlights from this match'
            : 'Highlights are not available for this recording',
        detail: isWaitingForHighlightTiming
            ? 'They will appear as soon as the recording is ready.'
            : fixture.fullGamePlaybackUrl == null
            ? 'The full game replay is not available yet.'
            : 'You can still watch the full game.',
        actionLabel: fixture.fullGamePlaybackUrl == null
            ? null
            : 'Watch full game',
        onAction: fixture.fullGamePlaybackUrl == null
            ? null
            : () =>
                  unawaited(_selectCompletedView(_CompletedVideoView.fullGame)),
      );
    }

    if (controller != null && controller.value.isInitialized) {
      return ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: value.aspectRatio == 0
                      ? 16 / 9
                      : value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _togglePlayback,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: value.isPlaying ? 0 : 1,
                    child: Center(
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: const BoxDecoration(
                          color: Color(0xCC111827),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 10,
                bottom: 10,
                child: IconButton.filledTonal(
                  tooltip: 'Fullscreen',
                  onPressed: _openFullscreen,
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
              ),
              if (_showHighlights && highlights.isNotEmpty)
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xCC111827),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _highlightLabel(highlights),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: 0,
                bottom: 0,
                left: 0,
                child: _showHighlights && highlights.isNotEmpty
                    ? _HighlightProgress(
                        count: highlights.length,
                        activeIndex: _activeHighlightIndex,
                      )
                    : VideoProgressIndicator(
                        controller,
                        allowScrubbing: !isLive,
                        colors: const VideoProgressColors(
                          playedColor: fieldEmerald600,
                          bufferedColor: fieldGray500,
                          backgroundColor: fieldGray700,
                        ),
                      ),
              ),
            ],
          );
        },
      );
    }

    if (_isLoading) {
      return const _VideoSkeleton();
    }

    final message =
        _playerError ??
        (isLive
            ? 'Connecting to live stream...'
            : _showHighlights && isProcessing
            ? 'Preparing highlights...'
            : _showHighlights
            ? 'Highlights are not available yet'
            : fixture.isFinal && isProcessing
            ? 'Preparing the full game replay...'
            : fixture.isFinal
            ? 'Full game replay is not available yet'
            : fixture.isCancelled
            ? 'No video is available for this match'
            : 'Broadcast starts on match day');
    final detail = _showHighlights && isProcessing
        ? 'They will appear as soon as the recording is ready.'
        : null;
    return _buildEmptyState(
      icon: _showHighlights
          ? Icons.auto_awesome_rounded
          : fixture.isFinal
          ? Icons.movie_creation_outlined
          : isLive
          ? Icons.sensors_rounded
          : Icons.schedule_rounded,
      title: message,
      detail: detail,
      actionLabel: _playerError == null ? null : 'Try again',
      onAction: _playerError == null
          ? null
          : () => unawaited(_syncPlayer(force: true)),
    );
  }

  String _highlightLabel(List<FixtureHighlightMoment> highlights) {
    final index = _activeHighlightIndex.clamp(0, highlights.length - 1);
    final event = highlights[index].event;
    final scorer = event.playerName == 'Unknown' ? 'Goal' : event.playerName;
    return '$scorer · ${event.minute}\' · ${index + 1}/${highlights.length}';
  }

  Widget _buildCompletedPlaybackControls() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    if (_showHighlights) {
      final highlights = _availableHighlights(controller);
      if (highlights.isEmpty) return const SizedBox.shrink();
      return _HighlightNavigationControls(
        highlights: highlights,
        activeIndex: _activeHighlightIndex,
        onSelect: (index) => unawaited(_playHighlightAt(index)),
        onPrevious: _activeHighlightIndex <= 0
            ? null
            : () => unawaited(_playHighlightAt(_activeHighlightIndex - 1)),
        onRestart: () => unawaited(_playHighlightAt(_activeHighlightIndex)),
        onNext: _activeHighlightIndex >= highlights.length - 1
            ? null
            : () => unawaited(_playHighlightAt(_activeHighlightIndex + 1)),
      );
    }

    return _VideoSeekControls(controller: controller);
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    String? detail,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fieldGray400, size: 34),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 5),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                detail,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: fieldGray400,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 10),
            TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ],
      ),
    );
  }
}

class _HighlightNavigationControls extends StatelessWidget {
  const _HighlightNavigationControls({
    required this.highlights,
    required this.activeIndex,
    required this.onSelect,
    required this.onPrevious,
    required this.onRestart,
    required this.onNext,
  });

  final List<FixtureHighlightMoment> highlights;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback? onPrevious;
  final VoidCallback onRestart;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = activeIndex.clamp(0, highlights.length - 1);
    final navigationButtonStyle = OutlinedButton.styleFrom(
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: fieldGray100)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'JUMP TO GOAL',
                style: TextStyle(
                  color: fieldGray500,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.7,
                ),
              ),
              const Spacer(),
              Text(
                '${selectedIndex + 1} of ${highlights.length}',
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var index = 0; index < highlights.length; index++) ...[
                  ChoiceChip(
                    key: ValueKey('highlight-goal-$index'),
                    label: Text(
                      'Goal ${index + 1} · ${highlights[index].event.minute}\'',
                    ),
                    selected: index == selectedIndex,
                    showCheckmark: false,
                    onSelected: (_) => onSelect(index),
                    selectedColor: fieldGray900,
                    backgroundColor: const Color(0xFFF9FAFB),
                    side: const BorderSide(color: fieldGray200),
                    labelStyle: TextStyle(
                      color: index == selectedIndex
                          ? Colors.white
                          : fieldGray700,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (index != highlights.length - 1) const SizedBox(width: 7),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPrevious,
                  style: navigationButtonStyle,
                  icon: const Icon(Icons.skip_previous_rounded, size: 18),
                  label: const Text('Previous'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('highlight-restart'),
                  onPressed: onRestart,
                  style: navigationButtonStyle,
                  icon: const Icon(Icons.replay_rounded, size: 18),
                  label: const Text('Restart'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onNext,
                  style: navigationButtonStyle,
                  icon: const Icon(Icons.skip_next_rounded, size: 18),
                  label: const Text('Next'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VideoSeekControls extends StatefulWidget {
  const _VideoSeekControls({
    required this.controller,
    this.dark = false,
    this.allowSeeking = true,
    this.onInteraction,
  });

  final VideoPlayerController controller;
  final bool dark;
  final bool allowSeeking;
  final VoidCallback? onInteraction;

  @override
  State<_VideoSeekControls> createState() => _VideoSeekControlsState();
}

class _VideoSeekControlsState extends State<_VideoSeekControls> {
  double? _dragMilliseconds;
  bool _resumeAfterDrag = false;
  Future<void>? _pauseBeforeDrag;

  @override
  void didUpdateWidget(covariant _VideoSeekControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _dragMilliseconds = null;
      _resumeAfterDrag = false;
      _pauseBeforeDrag = null;
    }
  }

  Future<void> _togglePlayback() async {
    if (widget.controller.value.isPlaying) {
      await widget.controller.pause();
    } else {
      await widget.controller.play();
    }
    widget.onInteraction?.call();
  }

  Future<void> _seekBy(Duration delta) async {
    final value = widget.controller.value;
    final target = value.position + delta;
    final position = target < Duration.zero
        ? Duration.zero
        : target > value.duration
        ? value.duration
        : target;
    await widget.controller.seekTo(position);
    widget.onInteraction?.call();
  }

  void _startDrag(double milliseconds) {
    _resumeAfterDrag = widget.controller.value.isPlaying;
    _pauseBeforeDrag = _resumeAfterDrag ? widget.controller.pause() : null;
    widget.onInteraction?.call();
    setState(() => _dragMilliseconds = milliseconds);
  }

  void _updateDrag(double milliseconds) {
    setState(() => _dragMilliseconds = milliseconds);
  }

  Future<void> _finishDrag(double milliseconds) async {
    await _pauseBeforeDrag;
    await widget.controller.seekTo(
      Duration(milliseconds: milliseconds.round()),
    );
    if (_resumeAfterDrag) await widget.controller.play();
    widget.onInteraction?.call();
    _pauseBeforeDrag = null;
    if (mounted) {
      setState(() {
        _dragMilliseconds = null;
        _resumeAfterDrag = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final foreground = widget.dark ? Colors.white : fieldGray900;
    final muted = widget.dark ? Colors.white70 : fieldGray500;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final durationMilliseconds = value.duration.inMilliseconds;
        final maxMilliseconds = durationMilliseconds <= 0
            ? 1.0
            : durationMilliseconds.toDouble();
        final positionMilliseconds =
            (_dragMilliseconds ?? value.position.inMilliseconds.toDouble())
                .clamp(0.0, maxMilliseconds);
        final shownPosition = Duration(
          milliseconds: positionMilliseconds.round(),
        );

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          decoration: BoxDecoration(
            color: widget.dark ? const Color(0xE6111827) : Colors.white,
            border: widget.dark
                ? null
                : const Border(top: BorderSide(color: fieldGray100)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Row(
                  children: [
                    Text(
                      '${_formatVideoTime(shownPosition)} / ${_formatVideoTime(value.duration)}',
                      style: TextStyle(
                        color: muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.allowSeeking)
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    activeTrackColor: fieldEmerald600,
                    inactiveTrackColor: widget.dark
                        ? Colors.white30
                        : fieldGray200,
                    thumbColor: fieldEmerald600,
                    overlayColor: fieldEmerald600.withValues(alpha: 0.18),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                    ),
                  ),
                  child: Slider(
                    key: const ValueKey('full-game-seek'),
                    min: 0,
                    max: maxMilliseconds,
                    value: positionMilliseconds,
                    label: _formatVideoTime(shownPosition),
                    onChangeStart: durationMilliseconds <= 0
                        ? null
                        : _startDrag,
                    onChanged: durationMilliseconds <= 0 ? null : _updateDrag,
                    onChangeEnd: durationMilliseconds <= 0
                        ? null
                        : (milliseconds) =>
                              unawaited(_finishDrag(milliseconds)),
                  ),
                ),
              Row(
                children: [
                  IconButton(
                    tooltip: value.isPlaying ? 'Pause' : 'Play',
                    onPressed: _togglePlayback,
                    color: foreground,
                    icon: Icon(
                      value.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  const Spacer(),
                  if (widget.allowSeeking) ...[
                    IconButton(
                      tooltip: 'Back 10 seconds',
                      onPressed: () =>
                          unawaited(_seekBy(const Duration(seconds: -10))),
                      color: foreground,
                      icon: const Icon(Icons.replay_10_rounded),
                    ),
                    IconButton(
                      tooltip: 'Forward 10 seconds',
                      onPressed: () =>
                          unawaited(_seekBy(const Duration(seconds: 10))),
                      color: foreground,
                      icon: const Icon(Icons.forward_10_rounded),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

String _formatVideoTime(Duration value) {
  final totalSeconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _HighlightProgress extends StatelessWidget {
  const _HighlightProgress({required this.count, required this.activeIndex});

  final int count;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: fieldGray700,
      child: SizedBox(
        height: 4,
        child: Row(
          children: [
            for (var index = 0; index < count; index++) ...[
              Expanded(
                child: ColoredBox(
                  color: index <= activeIndex ? fieldEmerald600 : fieldGray500,
                ),
              ),
              if (index != count - 1) const SizedBox(width: 2),
            ],
          ],
        ),
      ),
    );
  }
}

class _VideoSkeleton extends StatelessWidget {
  const _VideoSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(22),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFF374151),
              shape: BoxShape.circle,
            ),
            child: SizedBox(width: 54, height: 54),
          ),
          SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFF374151),
              borderRadius: BorderRadius.all(Radius.circular(5)),
            ),
            child: SizedBox(width: 170, height: 12),
          ),
        ],
      ),
    );
  }
}

class _FullscreenVideoPage extends StatefulWidget {
  const _FullscreenVideoPage({
    required this.controller,
    required this.allowSeeking,
  });

  final VideoPlayerController controller;
  final bool allowSeeking;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  static const _controlsFadeDuration = Duration(milliseconds: 180);
  static const _controlsVisibleDuration = Duration(seconds: 3);

  Timer? _controlsTimer;
  bool _controlsVisible = true;

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restartControlsTimer();
    });
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _toggleControls() {
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _restartControlsTimer();
  }

  void _showControls() {
    _controlsTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _restartControlsTimer();
  }

  void _restartControlsTimer() {
    _controlsTimer?.cancel();
    if (!widget.controller.value.isPlaying) return;
    _controlsTimer = Timer(_controlsVisibleDuration, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  Future<void> _togglePlayback() async {
    if (widget.controller.value.isPlaying) {
      await widget.controller.pause();
    } else {
      await widget.controller.play();
    }
    _showControls();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: widget.controller.value.aspectRatio == 0
                    ? 16 / 9
                    : widget.controller.value.aspectRatio,
                child: VideoPlayer(widget.controller),
              ),
            ),
            GestureDetector(
              key: const ValueKey('fullscreen-video-tap-target'),
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
            ),
            Positioned.fill(
              child: AnimatedOpacity(
                key: const ValueKey('fullscreen-controls-opacity'),
                duration: _controlsFadeDuration,
                opacity: _controlsVisible ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        top: 10,
                        left: 10,
                        child: IconButton.filledTonal(
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                      Center(
                        child: ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: widget.controller,
                          builder: (context, value, _) {
                            return IconButton.filled(
                              key: const ValueKey('fullscreen-playback-toggle'),
                              tooltip: value.isPlaying ? 'Pause' : 'Play',
                              onPressed: () => unawaited(_togglePlayback()),
                              iconSize: 38,
                              padding: const EdgeInsets.all(15),
                              style: IconButton.styleFrom(
                                backgroundColor: const Color(0xB3111827),
                                foregroundColor: Colors.white,
                              ),
                              icon: Icon(
                                value.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                            );
                          },
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        left: 0,
                        child: _VideoSeekControls(
                          controller: widget.controller,
                          dark: true,
                          allowSeeking: widget.allowSeeking,
                          onInteraction: _showControls,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoinActionBar extends StatelessWidget {
  const _JoinActionBar({
    required this.canJoin,
    required this.isJoining,
    required this.onJoin,
  });

  final bool canJoin;
  final bool isJoining;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          border: const Border(top: BorderSide(color: fieldGray100)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton.icon(
            onPressed: canJoin && !isJoining ? onJoin : null,
            icon: isJoining
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sports_mma_rounded),
            label: Text(isJoining ? 'Joining...' : 'Join Match'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              disabledBackgroundColor: fieldGray300,
              disabledForegroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _CompleteActionBar extends StatelessWidget {
  const _CompleteActionBar({
    required this.canComplete,
    required this.isCompleting,
    required this.onComplete,
  });

  final bool canComplete;
  final bool isCompleting;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          border: const Border(top: BorderSide(color: fieldGray100)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton.icon(
            onPressed: canComplete && !isCompleting ? onComplete : null,
            icon: isCompleting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.fact_check_rounded),
            label: Text(isCompleting ? 'Finalizing...' : 'Finalize Score'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              disabledBackgroundColor: fieldGray300,
              disabledForegroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _ScoreSubmission {
  const _ScoreSubmission({required this.homeScore, required this.awayScore});

  final int homeScore;
  final int awayScore;
}

class _CompleteScoreSheet extends StatefulWidget {
  const _CompleteScoreSheet({required this.fixture});

  final Fixture fixture;

  @override
  State<_CompleteScoreSheet> createState() => _CompleteScoreSheetState();
}

class _CompleteScoreSheetState extends State<_CompleteScoreSheet> {
  late final TextEditingController _homeController;
  late final TextEditingController _awayController;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _homeController = TextEditingController(
      text: (widget.fixture.homeScore ?? 0).toString(),
    );
    _awayController = TextEditingController(
      text: (widget.fixture.awayScore ?? 0).toString(),
    );
  }

  @override
  void dispose() {
    _homeController.dispose();
    _awayController.dispose();
    super.dispose();
  }

  void _submit() {
    final homeScore = int.tryParse(_homeController.text.trim());
    final awayScore = int.tryParse(_awayController.text.trim());

    if (homeScore == null || awayScore == null) {
      setState(() => _errorText = 'Enter both scores.');
      return;
    }

    if (homeScore > 99 || awayScore > 99) {
      setState(() => _errorText = 'Scores must be between 0 and 99.');
      return;
    }

    Navigator.of(
      context,
    ).pop(_ScoreSubmission(homeScore: homeScore, awayScore: awayScore));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final fixture = widget.fixture;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: fieldGray900,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.fact_check_rounded,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Finalize Score',
                          style: TextStyle(
                            color: fieldGray900,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'This immediately updates SR.',
                          style: TextStyle(
                            color: fieldGray500,
                            fontSize: 13,
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
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _ScoreInputCard(
                      clan: fixture.homeClan,
                      controller: _homeController,
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '-',
                      style: TextStyle(
                        color: fieldGray400,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Expanded(
                    child: _ScoreInputCard(
                      clan: fixture.awayClan,
                      controller: _awayController,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                _ErrorCallout(message: _errorText!),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.trending_up_rounded),
                  label: const Text('Apply SR'),
                  style: FilledButton.styleFrom(
                    backgroundColor: fieldEmerald600,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScoreInputCard extends StatelessWidget {
  const _ScoreInputCard({
    required this.clan,
    required this.controller,
    required this.textInputAction,
    this.onSubmitted,
  });

  final FixtureClan? clan;
  final TextEditingController controller;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fieldBackground,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          clan == null
              ? Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: fieldGray200),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.shield_rounded,
                    color: fieldGray400,
                    size: 22,
                  ),
                )
              : FixtureClanAvatar(clan: clan!, size: 44),
          const SizedBox(height: 8),
          Text(
            clan?.tag ?? 'TBD',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: fieldGray600,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            textInputAction: textInputAction,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
            onSubmitted: onSubmitted,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
            decoration: InputDecoration(
              counterText: '',
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: fieldGray200),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: fieldGray200),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: fieldEmerald500, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _teamTagFor(Fixture fixture, String? clanId) {
  if (clanId == fixture.homeClanId) return fixture.homeClan.tag;
  if (clanId == fixture.awayClanId) return fixture.awayClan?.tag ?? 'AWAY';
  return 'MATCH';
}

String _regionName(String region) {
  if (region.isEmpty) return 'Region';
  return '${region[0].toUpperCase()}${region.substring(1).toLowerCase()}';
}

({IconData icon, Color color, Color background}) _timelineEventStyle(
  String eventType,
) {
  return switch (eventType) {
    'GOAL' => (
      icon: Icons.sports_soccer_rounded,
      color: fieldEmerald600,
      background: Color(0xFFECFDF5),
    ),
    'BLUE_CARD' => (
      icon: Icons.square_rounded,
      color: fieldBlue600,
      background: Color(0xFFEFF6FF),
    ),
    'BLUE_CARD_EXPIRED' => (
      icon: Icons.keyboard_return_rounded,
      color: Color(0xFF2563EB),
      background: Color(0xFFEFF6FF),
    ),
    'MATCH_STARTED' || 'MATCH_RESUMED' => (
      icon: Icons.play_arrow_rounded,
      color: fieldEmerald600,
      background: Color(0xFFECFDF5),
    ),
    'MATCH_PAUSED' => (
      icon: Icons.pause_rounded,
      color: Color(0xFFD97706),
      background: Color(0xFFFFFBEB),
    ),
    'MATCH_ENDED' => (
      icon: Icons.flag_rounded,
      color: fieldGray700,
      background: fieldGray100,
    ),
    'CORRECTION' => (
      icon: Icons.edit_note_rounded,
      color: Color(0xFF7C3AED),
      background: Color(0xFFF5F3FF),
    ),
    _ => (
      icon: Icons.bolt_rounded,
      color: fieldGray700,
      background: fieldGray100,
    ),
  };
}

String _timelineTitle(FixtureTimelineEvent event) {
  return switch (event.eventType) {
    'GOAL' => 'Goal · ${event.playerName}',
    'BLUE_CARD' => 'Blue card · ${event.playerName}',
    'BLUE_CARD_EXPIRED' => 'Returned · ${event.playerName}',
    'MATCH_STARTED' => 'Match started',
    'MATCH_PAUSED' => 'Match paused',
    'MATCH_RESUMED' => 'Match resumed',
    'MATCH_ENDED' => 'Match ended',
    'CORRECTION' => 'Admin correction',
    _ => event.eventType.replaceAll('_', ' '),
  };
}

String _timelineSubtitle(Fixture fixture, FixtureTimelineEvent event) {
  final team = _teamTagFor(fixture, event.clanId);
  final note = event.note == null || event.note!.isEmpty ? null : event.note;

  if (event.eventType == 'GOAL' && event.assistProfileId != null) {
    return '$team · assist ${event.assistName}';
  }
  if (note != null) return '$team · $note';
  return team;
}

class _ErrorCallout extends StatelessWidget {
  const _ErrorCallout({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        message,
        style: const TextStyle(
          color: Color(0xFF991B1B),
          fontSize: 13,
          height: 1.35,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
