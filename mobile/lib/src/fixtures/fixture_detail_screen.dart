import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../clans/clan_widgets.dart';
import 'fixture.dart';
import 'fixture_repository.dart';
import 'fixture_widgets.dart';

class FixtureDetailScreen extends StatefulWidget {
  const FixtureDetailScreen({
    super.key,
    required this.fixture,
    required this.fixtureRepository,
    required this.myClanMembership,
  });

  final Fixture fixture;
  final FixtureRepository fixtureRepository;
  final MyClanMembership? myClanMembership;

  @override
  State<FixtureDetailScreen> createState() => _FixtureDetailScreenState();
}

class _FixtureDetailScreenState extends State<FixtureDetailScreen> {
  late Fixture _fixture = widget.fixture;
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
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  bool get _canJoin {
    final membership = widget.myClanMembership;
    return membership != null &&
        membership.isOwner &&
        _fixture.isOpen &&
        _fixture.homeClanId != membership.clan.id;
  }

  bool get _canShowCompleteAction {
    return false;
  }

  bool get _canComplete {
    final membership = widget.myClanMembership;
    if (membership == null || !membership.isOwner) return false;
    if (!_canShowCompleteAction) return false;

    return membership.clan.id == _fixture.homeClanId ||
        membership.clan.id == _fixture.awayClanId;
  }

  Future<void> _joinFixture() async {
    final membership = widget.myClanMembership;
    if (membership == null || !membership.isOwner) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only a clan owner can join matches.')),
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
        () => _errorText = error.toString().replaceFirst('Exception: ', ''),
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
          content: Text('Only a participating clan owner can finalize scores.'),
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
        () => _errorText = error.toString().replaceFirst('Exception: ', ''),
      );
    } finally {
      if (mounted) {
        setState(() => _isCompleting = false);
      }
    }
  }

  Future<void> _refreshFixture({bool quiet = false}) async {
    if (_isRefreshing) return;
    if (!quiet) {
      setState(() => _errorText = null);
    }
    _isRefreshing = true;

    try {
      final fixture = await widget.fixtureRepository.getFixture(_fixture.id);
      if (!mounted) return;
      setState(() {
        _fixture = fixture;
        _didChange = true;
      });
      _configureRefreshTimer();
    } catch (error) {
      if (!mounted || quiet) return;
      setState(
        () => _errorText = error.toString().replaceFirst('Exception: ', ''),
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
    }
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

    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: FieldPageHeader(
          title: 'Match Details',
          showBack: true,
          onBack: () => Navigator.of(context).pop(_didChange),
        ),
        child: ListView(
          padding: fieldHeaderAwarePadding(
            context,
            bottom: bottomAction == null ? 32 : 116,
          ),
          children: [
            _Scoreboard(fixture: _fixture),
            if (_errorText != null) ...[
              const SizedBox(height: 14),
              _ErrorCallout(message: _errorText!),
            ],
            const SizedBox(height: 18),
            _InfoGrid(fixture: _fixture),
            if (_fixture.scorers.isNotEmpty) ...[
              const SizedBox(height: 18),
              _GoalContributions(fixture: _fixture),
            ],
            if (_fixture.timeline.isNotEmpty) ...[
              const SizedBox(height: 18),
              _MatchTimeline(fixture: _fixture),
            ],
            if (_fixture.isFinal &&
                (_fixture.homeSrChange != null ||
                    _fixture.awaySrChange != null)) ...[
              const SizedBox(height: 18),
              _RatingUpdates(fixture: _fixture),
            ],
            const SizedBox(height: 18),
            _BroadcastPanel(fixture: _fixture),
          ],
        ),
      ),
      bottomNavigationBar: bottomAction,
    );
  }
}

class _Scoreboard extends StatelessWidget {
  const _Scoreboard({required this.fixture});

  final Fixture fixture;

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
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const RadialGradient(
          center: Alignment(0.8, -0.8),
          radius: 1.4,
          colors: [Color(0xFF374151), Color(0xFF111827), Color(0xFF000000)],
          stops: [0, 0.52, 1],
        ),
        borderRadius: BorderRadius.circular(26),
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

class _ScoreboardClan extends StatelessWidget {
  const _ScoreboardClan({required this.clan, required this.winner});

  final FixtureClan clan;
  final bool winner;

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
        const SizedBox(height: 8),
        TierBadge(rank: clan.rank, small: true),
      ],
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

class _GoalContributions extends StatelessWidget {
  const _GoalContributions({required this.fixture});

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
              Icon(Icons.sports_soccer_rounded, color: fieldEmerald600),
              SizedBox(width: 8),
              Text(
                'GOALS & ASSISTS',
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
          for (final scorer in fixture.scorers) ...[
            _GoalContributionRow(fixture: fixture, scorer: scorer),
            if (scorer != fixture.scorers.last)
              const Divider(height: 18, color: fieldGray100),
          ],
        ],
      ),
    );
  }
}

class _GoalContributionRow extends StatelessWidget {
  const _GoalContributionRow({required this.fixture, required this.scorer});

  final Fixture fixture;
  final FixtureScorer scorer;

  @override
  Widget build(BuildContext context) {
    final team = _teamTagFor(fixture, scorer.clanId);
    final assistLabel = scorer.assistProfileId == null
        ? 'No assist'
        : 'Assist ${scorer.assistName}';

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
          child: Text(
            '${scorer.minute}\'',
            style: const TextStyle(
              color: fieldEmerald600,
              fontSize: 12,
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
                scorer.scorerName,
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
                '$team · $assistLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MatchTimeline extends StatelessWidget {
  const _MatchTimeline({required this.fixture});

  final Fixture fixture;

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
            _TimelineRow(fixture: fixture, event: event),
            if (event != events.last) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.fixture, required this.event});

  final Fixture fixture;
  final FixtureTimelineEvent event;

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
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
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

class _BroadcastPanel extends StatelessWidget {
  const _BroadcastPanel({required this.fixture});

  final Fixture fixture;

  @override
  Widget build(BuildContext context) {
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
                  color: fixture.isLive
                      ? const Color(0xFFEF4444)
                      : const Color(0xFFDC2626),
                ),
                const SizedBox(width: 8),
                Text(
                  fixture.isFinal
                      ? 'MATCH REPLAY'
                      : fixture.isLive
                      ? 'LIVE STREAM'
                      : 'LIVE BROADCAST',
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: fieldGray900,
              child: Center(
                child: fixture.isLive
                    ? FilledButton(
                        onPressed: () {},
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Watch Live'),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            fixture.isFinal
                                ? Icons.shield_rounded
                                : Icons.schedule_rounded,
                            color: fieldGray400,
                            size: 34,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            fixture.isFinal
                                ? 'VOD Not Available'
                                : 'Broadcast starts on match day',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
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
