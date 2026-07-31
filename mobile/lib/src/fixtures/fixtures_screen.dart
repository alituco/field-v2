import 'package:flutter/material.dart';

import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../open_queue/open_queue.dart';
import '../open_queue/open_queue_repository.dart';
import '../open_queue/open_queue_review_screen.dart';
import '../open_queue/open_queue_screen.dart';
import 'create_fixture_screen.dart';
import 'fixture.dart';
import 'fixture_detail_screen.dart';
import 'fixture_play_chooser.dart';
import 'fixture_repository.dart';
import 'fixture_widgets.dart';

Future<OpenQueueRole?> showSoloFixtureAvailabilitySheet(
  BuildContext context,
  OpenQueueGame game,
) {
  return showModalBottomSheet<OpenQueueRole>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _SoloFixtureSheet(game: game),
  );
}

class FixturesScreen extends StatefulWidget {
  const FixturesScreen({
    super.key,
    required this.fixtureRepository,
    required this.openQueueRepository,
    this.clanRepository,
    this.onNavigateTab,
  });

  final FixtureRepository fixtureRepository;
  final OpenQueueRepository openQueueRepository;
  final ClanRepository? clanRepository;
  final ValueChanged<int>? onNavigateTab;

  @override
  State<FixturesScreen> createState() => _FixturesScreenState();
}

class _FixturesScreenState extends State<FixturesScreen> {
  List<Fixture> _fixtures = const [];
  List<OpenQueueGame> _soloGames = const [];
  MyClanMembership? _myClanMembership;
  FixtureStatus? _selectedStatus;
  DateTime? _selectedMatchDate;
  bool _isLoading = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final results = await Future.wait([
        widget.fixtureRepository.listFixtures(),
        widget.openQueueRepository.listFixtureGames(),
        widget.fixtureRepository.getMyClanMembership(),
      ]);
      if (!mounted) return;
      final fixtures = results[0] as List<Fixture>;
      final soloGames = results[1] as List<OpenQueueGame>;
      final matches = _fixtureFeedItems(fixtures, soloGames);
      setState(() {
        _fixtures = fixtures;
        _soloGames = soloGames;
        _myClanMembership = results[2] as MyClanMembership?;
        _selectedMatchDate ??= _defaultMatchDate(matches);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = userFacingError(
          error,
          fallback: 'We could not load matches. Pull down to try again.',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<_FixtureFeedItem> get _matches =>
      _fixtureFeedItems(_fixtures, _soloGames);

  List<DateTime> get _calendarDates => _matchCalendarDates(_matches);

  List<_FixtureFeedItem> get _selectedDateMatches {
    final selectedDate = _selectedMatchDate;
    if (selectedDate == null) return const [];

    return _matches
        .where((match) => _sameDay(match.matchDate, selectedDate))
        .toList();
  }

  List<_FixtureFeedItem> get _filteredMatches {
    final matches = _selectedDateMatches;
    if (_selectedStatus == null) return matches;
    return matches
        .where((match) => match.filterStatus == _selectedStatus)
        .toList();
  }

  Map<FixtureStatus, int> _statusCounts(Iterable<_FixtureFeedItem> matches) {
    final counts = <FixtureStatus, int>{};
    for (final match in matches) {
      counts.update(
        match.filterStatus,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return counts;
  }

  Future<void> _openPlay() async {
    final selection = await showFixturePlayChooser(
      context: context,
      cachedMembership: _myClanMembership,
      loadMembership: widget.fixtureRepository.getMyClanMembership,
    );
    if (selection == null || !mounted) return;

    if (selection.mode == FixturePlayMode.solo) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => OpenQueueScreen(
            repository: widget.openQueueRepository,
            onNavigateTab: widget.onNavigateTab,
          ),
        ),
      );
      if (mounted) await _load();
      return;
    }

    final membership = selection.membership;
    setState(() => _myClanMembership = membership);
    if (membership?.canManageMatches != true) {
      final goToClans = await showClanScheduleBlockedDialog(
        context: context,
        membership: membership,
      );
      if (goToClans && mounted) widget.onNavigateTab?.call(2);
      return;
    }

    await _openCreateMatch(membership!);
  }

  Future<void> _openCreateMatch(MyClanMembership membership) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => CreateFixtureScreen(
          fixtureRepository: widget.fixtureRepository,
          myClanMembership: membership,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _load();
    }
  }

  Future<void> _openFixture(Fixture fixture) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => FixtureDetailScreen(
          fixture: fixture,
          fixtureRepository: widget.fixtureRepository,
          clanRepository: widget.clanRepository,
          myClanMembership: _myClanMembership,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _load();
    }
  }

  Future<void> _openSoloGame(OpenQueueGame game) async {
    if (game.hasPendingOperationalResolution ||
        game.status == 'FULL' ||
        game.status == 'LIVE' ||
        game.status == 'FINAL' ||
        game.status == 'CANCELLED') {
      await _openSoloMatchDetail(game);
      return;
    }

    final role = await showSoloFixtureAvailabilitySheet(context, game);
    if (role == null || !mounted) return;

    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OpenQueueReviewScreen(
          repository: widget.openQueueRepository,
          game: game,
          role: role,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openSoloMatchDetail(OpenQueueGame game) async {
    try {
      final detail = await widget.openQueueRepository.getMatchDetail(game.id);
      if (!mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => FixtureDetailScreen(
            fixture: detail.toFixture(),
            fixtureRepository: widget.fixtureRepository,
            clanRepository: widget.clanRepository,
            myClanMembership: null,
            sourceLabel: 'SOLO',
            showTeamRatings: false,
            playerRatingUpdate: detail.viewerRatingUpdate,
            refreshFixture: () async {
              final next = await widget.openQueueRepository.getMatchDetail(
                game.id,
              );
              return next.toFixture();
            },
          ),
        ),
      );
      if (mounted) await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'We could not open this solo match. Try again.',
            ),
          ),
        ),
      );
    }
  }

  Widget _matchCard(_FixtureFeedItem match) {
    final fixture = match.fixture;
    if (fixture != null) {
      return FixtureCard(fixture: fixture, onTap: () => _openFixture(fixture));
    }

    final game = match.soloGame!;
    return SoloFixtureCard(game: game, onTap: () => _openSoloGame(game));
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    final calendarDates = _calendarDates;
    final selectedDate =
        _selectedMatchDate ??
        (calendarDates.isEmpty ? null : calendarDates.first);
    final selectedDateMatches = _selectedDateMatches;
    final filteredMatches = _filteredMatches;
    final selectedStatusCounts = _statusCounts(selectedDateMatches);

    return FieldHeaderOverlay(
      header: FieldPageHeader(
        title: 'Fixtures',
        rightAction: HeaderActionButton(
          key: const ValueKey('fixtures-play-action'),
          icon: Icons.sports_soccer_rounded,
          label: 'Play',
          tone: HeaderActionTone.blue,
          onPressed: _openPlay,
        ),
      ),
      child: RefreshIndicator(
        color: fieldEmerald600,
        edgeOffset: fieldPageHeaderExtent(context),
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: fieldHeaderAwarePadding(context, top: 24, bottom: 124),
          children: [
            FixtureHeroBanner(
              totalMatches: matches.length,
              statusCounts: _statusCounts(matches),
            ),
            const SizedBox(height: 24),
            const _SectionLabel('Match Calendar'),
            const SizedBox(height: 10),
            _MatchDayCalendar(
              dates: calendarDates,
              selectedDate: selectedDate,
              matches: matches,
              onSelected: (date) {
                setState(() {
                  _selectedMatchDate = date;
                  _selectedStatus = null;
                });
              },
            ),
            const SizedBox(height: 24),
            const _SectionLabel('Filter Matches'),
            const SizedBox(height: 10),
            FixtureStatusFilters(
              selectedStatus: _selectedStatus,
              statusCounts: selectedStatusCounts,
              totalMatches: selectedDateMatches.length,
              onSelected: (status) {
                setState(() => _selectedStatus = status);
              },
            ),
            const SizedBox(height: 24),
            _SectionLabel(
              selectedDate == null
                  ? 'No Match Day Selected'
                  : '${_longDateLabel(selectedDate)} - ${filteredMatches.length} Match${filteredMatches.length == 1 ? '' : 'es'}',
            ),
            const SizedBox(height: 12),
            if (_isLoading)
              const _FixturesLoadingState()
            else if (_errorText != null)
              _FixturesErrorState(message: _errorText!, onRetry: _load)
            else if (filteredMatches.isEmpty)
              const _FixturesEmptyState()
            else
              for (var i = 0; i < filteredMatches.length; i++) ...[
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: Duration(milliseconds: 240 + (i * 50)),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) {
                    return Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(0, 10 * (1 - value)),
                        child: child,
                      ),
                    );
                  },
                  child: _matchCard(filteredMatches[i]),
                ),
                if (i != filteredMatches.length - 1) const SizedBox(height: 12),
              ],
          ],
        ),
      ),
    );
  }
}

class _MatchDayCalendar extends StatefulWidget {
  const _MatchDayCalendar({
    required this.dates,
    required this.selectedDate,
    required this.matches,
    required this.onSelected,
  });

  final List<DateTime> dates;
  final DateTime? selectedDate;
  final List<_FixtureFeedItem> matches;
  final ValueChanged<DateTime> onSelected;

  @override
  State<_MatchDayCalendar> createState() => _MatchDayCalendarState();
}

class _MatchDayCalendarState extends State<_MatchDayCalendar> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _scrollSelectedIntoView(animated: false);
  }

  @override
  void didUpdateWidget(covariant _MatchDayCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameNullableDay(widget.selectedDate, oldWidget.selectedDate) ||
        widget.dates.length != oldWidget.dates.length) {
      _scrollSelectedIntoView(animated: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scrollSelectedIntoView({required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients || widget.selectedDate == null) {
        return;
      }

      final index = widget.dates.indexWhere(
        (date) => _sameDay(date, widget.selectedDate!),
      );
      if (index < 0) return;

      final target = ((index - 1).clamp(0, widget.dates.length) * 92.0).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );

      if (animated) {
        _controller.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      } else {
        _controller.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dates.isEmpty) {
      return const _StatePanel(
        icon: Icons.calendar_month_rounded,
        title: 'No match days',
        message: 'Tuesday and Friday match days will show here.',
      );
    }

    return SizedBox(
      height: 104,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: widget.dates.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final date = widget.dates[index];
          final selected =
              widget.selectedDate != null &&
              _sameDay(date, widget.selectedDate!);
          final count = widget.matches
              .where((match) => _sameDay(match.matchDate, date))
              .length;

          return _MatchDayChip(
            date: date,
            selected: selected,
            matchCount: count,
            onTap: () => widget.onSelected(date),
          );
        },
      ),
    );
  }
}

class _MatchDayChip extends StatelessWidget {
  const _MatchDayChip({
    required this.date,
    required this.selected,
    required this.matchCount,
    required this.onTap,
  });

  final DateTime date;
  final bool selected;
  final int matchCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 82,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(colors: [fieldEmerald500, fieldBlue600])
                : null,
            color: selected ? null : Colors.white,
            border: Border.all(
              color: selected ? Colors.transparent : fieldGray100,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: selected
                    ? fieldEmerald500.withValues(alpha: 0.22)
                    : fieldGray900.withValues(alpha: 0.035),
                blurRadius: selected ? 18 : 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _weekdayShort(date).toUpperCase(),
                style: TextStyle(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.82)
                      : fieldGray500,
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.7,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                date.day.toString(),
                style: TextStyle(
                  color: selected ? Colors.white : fieldGray900,
                  fontSize: 28,
                  height: 0.9,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _monthShort(date).toUpperCase(),
                    style: TextStyle(
                      color: selected
                          ? Colors.white.withValues(alpha: 0.82)
                          : fieldGray400,
                      fontSize: 10,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.7,
                    ),
                  ),
                  if (matchCount > 0) ...[
                    const SizedBox(width: 5),
                    Container(
                      width: 18,
                      height: 18,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? Colors.white.withValues(alpha: 0.20)
                            : fieldGray100,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        matchCount.toString(),
                        style: TextStyle(
                          color: selected ? Colors.white : fieldGray700,
                          fontSize: 10,
                          height: 1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: fieldGray600,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
    );
  }
}

class _FixturesLoadingState extends StatelessWidget {
  const _FixturesLoadingState();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++) ...[
          Container(
            height: 156,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: fieldGray100),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: fieldGray900.withValues(alpha: 0.025),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      FieldSkeletonBox(
                        width: 86,
                        height: 24,
                        borderRadius: 999,
                      ),
                      Spacer(),
                      FieldSkeletonBox(
                        width: 74,
                        height: 20,
                        borderRadius: 999,
                      ),
                    ],
                  ),
                  SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: FieldSkeletonBox(height: 18, borderRadius: 6),
                      ),
                      SizedBox(width: 24),
                      FieldSkeletonBox(width: 34, height: 18, borderRadius: 6),
                      SizedBox(width: 24),
                      Expanded(
                        child: FieldSkeletonBox(height: 18, borderRadius: 6),
                      ),
                    ],
                  ),
                  Spacer(),
                  FieldSkeletonBox(height: 14, borderRadius: 6),
                  SizedBox(height: 10),
                  FieldSkeletonBox(width: 180, height: 12, borderRadius: 6),
                ],
              ),
            ),
          ),
          if (i != 2) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _FixturesErrorState extends StatelessWidget {
  const _FixturesErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _StatePanel(
      icon: Icons.warning_rounded,
      title: 'Fixtures unavailable',
      message: message,
      actionLabel: 'Try Again',
      onAction: onRetry,
    );
  }
}

class _FixturesEmptyState extends StatelessWidget {
  const _FixturesEmptyState();

  @override
  Widget build(BuildContext context) {
    return const _StatePanel(
      icon: Icons.sports_mma_rounded,
      title: 'No matches yet',
      message: 'There are no clan or solo games on this match day.',
    );
  }
}

const _soloFixtureSpotOrder = [
  OpenQueueRole.goalkeeper,
  OpenQueueRole.defender,
  OpenQueueRole.midfielder,
  OpenQueueRole.attacker,
];

class _SoloFixtureSheet extends StatelessWidget {
  const _SoloFixtureSheet({required this.game});

  final OpenQueueGame game;

  @override
  Widget build(BuildContext context) {
    final status = _soloFixtureStatus(game);
    final showScore = game.shouldDisplayScore;
    final showAvailability =
        !showScore &&
        status != FixtureStatus.cancelled &&
        game.startsAt.isAfter(DateTime.now());
    final canSelectSpot =
        game.status.toUpperCase() == 'OPEN' &&
        !game.hasMyBooking &&
        !game.isFull &&
        game.startsAt.isAfter(DateTime.now());
    final startsAt = game.bahrainStartsAt;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.90;

    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: const BoxDecoration(
          color: fieldBackground,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: fieldGray300,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'SOLO',
                      style: TextStyle(
                        color: fieldBlue600,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _soloStatusLabel(game),
                    style: TextStyle(
                      color: status == FixtureStatus.live
                          ? Colors.redAccent
                          : fieldGray600,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Open Queue Game',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_longDateLabel(DateTime(startsAt.year, startsAt.month, startsAt.day))} · ${game.timeLabel}',
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 18),
              if (game.hasPendingOperationalResolution) ...[
                Container(
                  key: const ValueKey('solo-operational-state-callout'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    border: Border.all(color: const Color(0xFFFDE68A)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    game.operationalState == MatchOperationalState.noData
                        ? game.operationalReasonCode == 'RESULT_MISSING'
                              ? 'The final result is missing. An admin can review and finalize the outcome.'
                              : 'No match data was recorded. An admin can review and finalize the outcome.'
                        : 'This match is under admin review. Its score and attendance outcome are not final.',
                    style: const TextStyle(
                      color: Color(0xFF92400E),
                      fontSize: 12,
                      height: 1.4,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (showScore)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: fieldGray100),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'WHITE',
                          style: TextStyle(
                            color: fieldGray700,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      Text(
                        '${game.whiteScore ?? 0}  –  ${game.blackScore ?? 0}',
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          'BLACK',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: fieldGray700,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (showScore) const SizedBox(height: 12),
              _SoloSheetRow(
                icon: Icons.location_on_outlined,
                label: 'Venue',
                value: game.venue,
              ),
              const SizedBox(height: 10),
              _SoloSheetRow(
                icon: Icons.groups_rounded,
                label: 'Players',
                value: '${game.confirmedCount} of ${game.capacity} confirmed',
              ),
              if (game.hasMyBooking) ...[
                const SizedBox(height: 10),
                _SoloSheetRow(
                  icon: Icons.verified_rounded,
                  label: 'Your spot',
                  value:
                      '${game.myBookingRole?.label ?? 'Confirmed'}${game.myBookingTeam == null ? '' : ' · ${game.myBookingTeam}'}',
                  highlighted: true,
                ),
              ],
              if (showAvailability) ...[
                const SizedBox(height: 22),
                const Text(
                  'AVAILABLE SPOTS',
                  style: TextStyle(
                    color: fieldGray700,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.25,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  game.hasMyBooking
                      ? 'You are already confirmed. Here is what remains for this game.'
                      : game.isFull
                      ? 'This game is full. There are no positions left.'
                      : 'Tap an available position to book this exact game.',
                  style: const TextStyle(
                    color: fieldGray500,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.72,
                  children: [
                    for (final role in _soloFixtureSpotOrder)
                      _SoloSpotTile(
                        role: role,
                        spots: game.spotsFor(role),
                        enabled: canSelectSpot && game.spotsFor(role) > 0,
                        onSelected: () => Navigator.of(context).pop(role),
                      ),
                  ],
                ),
              ],
              if (!showAvailability && !showScore) ...[
                const SizedBox(height: 18),
                const Text(
                  'Position booking is closed for this game.',
                  style: TextStyle(
                    color: fieldGray500,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    foregroundColor: fieldGray700,
                    side: const BorderSide(color: fieldGray200),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Close',
                    style: TextStyle(fontWeight: FontWeight.w900),
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

class _SoloSpotTile extends StatelessWidget {
  const _SoloSpotTile({
    required this.role,
    required this.spots,
    required this.enabled,
    required this.onSelected,
  });

  final OpenQueueRole role;
  final int spots;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final hasSpots = spots > 0;
    final spotLabel = switch (spots) {
      <= 0 => 'Full',
      1 => '1 spot left',
      _ => '$spots spots left',
    };

    return Material(
      key: ValueKey('solo-spot-${role.code}'),
      color: enabled
          ? fieldEmerald50
          : hasSpots
          ? Colors.white
          : fieldGray100,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: enabled ? onSelected : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: enabled ? fieldEmerald200 : fieldGray200),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: enabled ? fieldEmerald600 : fieldGray300,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      role.code,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    enabled
                        ? Icons.chevron_right_rounded
                        : Icons.lock_outline_rounded,
                    color: enabled ? fieldEmerald600 : fieldGray400,
                    size: 18,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                role.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                spotLabel,
                style: TextStyle(
                  color: enabled ? fieldEmerald700 : fieldGray500,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoloSheetRow extends StatelessWidget {
  const _SoloSheetRow({
    required this.icon,
    required this.label,
    required this.value,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          size: 19,
          color: highlighted ? fieldEmerald600 : fieldGray400,
        ),
        const SizedBox(width: 10),
        Text(
          '$label:',
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: highlighted ? fieldEmerald700 : fieldGray900,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatePanel extends StatelessWidget {
  const _StatePanel({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, color: fieldEmerald600, size: 34),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 14,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

DateTime? _defaultMatchDate(List<_FixtureFeedItem> matches) {
  final calendarDates = _matchCalendarDates(matches);
  if (calendarDates.isEmpty) return null;

  final today = _bahrainToday();
  final actualDates = <String, DateTime>{
    for (final match in matches)
      _dateKey(match.matchDate): _dateOnly(match.matchDate),
  }.values.toList()..sort();
  final upcoming = actualDates.where((date) => !date.isBefore(today)).toList();
  if (upcoming.isNotEmpty) return upcoming.first;
  if (actualDates.isNotEmpty) return actualDates.last;

  return calendarDates.firstWhere(
    (date) => !date.isBefore(today),
    orElse: () => calendarDates.last,
  );
}

List<DateTime> _matchCalendarDates(List<_FixtureFeedItem> matches) {
  final datesByKey = <String, DateTime>{};
  final today = _bahrainToday();

  for (final match in matches) {
    final date = _dateOnly(match.matchDate);
    datesByKey[_dateKey(date)] = date;
  }

  var cursor = today.subtract(const Duration(days: 1));
  var addedPast = 0;
  while (addedPast < 24) {
    if (_isEnabledMatchDay(cursor)) {
      datesByKey[_dateKey(cursor)] = cursor;
      addedPast += 1;
    }
    cursor = cursor.subtract(const Duration(days: 1));
  }

  cursor = today;
  var addedUpcoming = 0;
  while (addedUpcoming < 12) {
    if (_isEnabledMatchDay(cursor)) {
      datesByKey[_dateKey(cursor)] = cursor;
      addedUpcoming += 1;
    }
    cursor = cursor.add(const Duration(days: 1));
  }

  final dates = datesByKey.values.toList()..sort();
  return dates;
}

List<_FixtureFeedItem> _fixtureFeedItems(
  List<Fixture> fixtures,
  List<OpenQueueGame> soloGames,
) {
  final matches = <_FixtureFeedItem>[
    for (final fixture in fixtures) _FixtureFeedItem.clan(fixture),
    for (final game in soloGames) _FixtureFeedItem.solo(game),
  ];
  matches.sort((left, right) {
    final date = left.matchDate.compareTo(right.matchDate);
    if (date != 0) return date;
    final time = left.sortMinutes.compareTo(right.sortMinutes);
    if (time != 0) return time;
    return left.id.compareTo(right.id);
  });
  return matches;
}

class _FixtureFeedItem {
  const _FixtureFeedItem._({this.fixture, this.soloGame});

  factory _FixtureFeedItem.clan(Fixture fixture) {
    return _FixtureFeedItem._(fixture: fixture);
  }

  factory _FixtureFeedItem.solo(OpenQueueGame game) {
    return _FixtureFeedItem._(soloGame: game);
  }

  final Fixture? fixture;
  final OpenQueueGame? soloGame;

  String get id => fixture?.id ?? soloGame!.id;

  DateTime get matchDate {
    final clanFixture = fixture;
    if (clanFixture != null) return _dateOnly(clanFixture.matchDate);
    final startsAt = soloGame!.bahrainStartsAt;
    return DateTime(startsAt.year, startsAt.month, startsAt.day);
  }

  FixtureStatus get filterStatus {
    final clanFixture = fixture;
    return clanFixture?.status ?? _soloFixtureStatus(soloGame!);
  }

  int get sortMinutes {
    final game = soloGame;
    if (game != null) {
      final startsAt = game.bahrainStartsAt;
      return startsAt.hour * 60 + startsAt.minute;
    }
    return fixture!.timeSlot.startsWith('8:30') ? 20 * 60 + 30 : 19 * 60;
  }
}

FixtureStatus _soloFixtureStatus(OpenQueueGame game) {
  return switch (game.status.toUpperCase()) {
    'OPEN' when game.isFull => FixtureStatus.scheduled,
    'FULL' => FixtureStatus.scheduled,
    'LIVE' => FixtureStatus.live,
    'FINAL' => FixtureStatus.finalResult,
    'CANCELLED' => FixtureStatus.cancelled,
    _ => FixtureStatus.open,
  };
}

String _soloStatusLabel(OpenQueueGame game) {
  return game.statusLabel.toUpperCase();
}

DateTime _bahrainToday() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 3));
  return DateTime(now.year, now.month, now.day);
}

bool _isEnabledMatchDay(DateTime date) {
  return isFixtureMatchDay(date);
}

bool _sameNullableDay(DateTime? a, DateTime? b) {
  if (a == null || b == null) return a == b;
  return _sameDay(a, b);
}

bool _sameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

DateTime _dateOnly(DateTime date) {
  return DateTime(date.year, date.month, date.day);
}

String _dateKey(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

String _longDateLabel(DateTime date) {
  return '${_weekdayName(date)}, ${_monthShort(date)} ${date.day}';
}

String _weekdayShort(DateTime date) {
  return _weekdayName(date).substring(0, 3);
}

String _weekdayName(DateTime date) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return weekdays[date.weekday - 1];
}

String _monthShort(DateTime date) {
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
  return months[date.month - 1];
}
