import 'package:flutter/material.dart';

import '../ui/field_loading.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../home/fieldrush_home_widgets.dart';
import '../open_queue/fieldrush_booking_flow.dart';
import '../open_queue/fieldrush_game_detail_screen.dart';
import '../open_queue/open_queue.dart';
import '../open_queue/open_queue_repository.dart';
import '../ranking/rating_division.dart';
import 'fixture_repository.dart';

const _cream = FieldrushAuthTheme.cream;
const _ink = FieldrushAuthTheme.ink;
const _green = FieldrushAuthTheme.forest;
const _muted = FieldrushAuthTheme.muted;
const _border = FieldrushAuthTheme.border;
const _wash = Color(0xFFF2EFE3);

TextStyle _outfit(double size, {Color color = _ink}) => TextStyle(
  fontFamily: 'Outfit',
  fontSize: size,
  fontWeight: FontWeight.w800,
  height: 1.1,
  letterSpacing: -.3,
  color: color,
);
TextStyle _jakarta(double size, {Color color = _muted, double? tracking}) =>
    TextStyle(
      fontFamily: 'PlusJakartaSans',
      fontSize: size,
      fontWeight: FontWeight.w800,
      height: 1.35,
      letterSpacing: tracking,
      color: color,
    );

class FieldrushFixturePage extends StatefulWidget {
  const FieldrushFixturePage({
    super.key,
    required this.repository,
    this.fixtureRepository,
    this.onPlay,
    this.onOpenGame,
    this.onNavigateTab,
    this.activationTick = 0,
    this.now,
  });

  final OpenQueueRepository repository;
  final FixtureRepository? fixtureRepository;
  final Future<void> Function(OpenQueueGame? game)? onPlay;
  final Future<void> Function(OpenQueueGame game)? onOpenGame;
  final ValueChanged<int>? onNavigateTab;
  final int activationTick;
  final DateTime? now;

  @override
  State<FieldrushFixturePage> createState() => _FieldrushFixturePageState();
}

class _FieldrushFixturePageState extends State<FieldrushFixturePage> {
  List<OpenQueueGame> _games = const [];
  Set<String> _bookedIds = const {};
  DateTime? _selectedDate;
  bool _loading = true;
  bool _hasLoaded = false;
  bool _opening = false;
  String? _error;
  int _loadVersion = 0;

  DateTime get _now => widget.now ?? DateTime.now();
  DateTime get _today => _date(gameLocalDateTime(_now, 'America/Phoenix'));
  List<DateTime> get _dates =>
      {for (final game in _games) _date(game.localStartsAt)}.toList()..sort();
  List<OpenQueueGame> get _selectedGames => _games
      .where((game) => _date(game.localStartsAt) == _selectedDate)
      .toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FieldrushFixturePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activationTick != widget.activationTick ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    setState(() {
      _loading = !_hasLoaded;
      _error = null;
    });
    try {
      final repository = widget.repository;
      final results = await Future.wait<dynamic>([
        repository.listFixtureGames(),
        repository is OpenQueueMarketRepository
            ? (repository as OpenQueueMarketRepository).listMarketGames(
                'America/Phoenix',
              )
            : repository.listGames(),
        repository.getMyUpcomingBookings(),
      ]);
      if (!mounted || version != _loadVersion) return;
      final bookings = (results[2] as List<OpenQueueBooking>)
          .where((booking) => booking.status == 'CONFIRMED')
          .toList();
      // Keep market discovery independent from the all-market history feed.
      // Fixture rows then win because they contain the live/history match data.
      final byId = <String, OpenQueueGame>{
        for (final booking in bookings) booking.gameId: booking.game,
        for (final game in results[1] as List<OpenQueueGame>) game.id: game,
        for (final game in results[0] as List<OpenQueueGame>) game.id: game,
      };
      final games =
          byId.values
              .where(
                (game) =>
                    game.timezone == 'America/Phoenix' &&
                    game.currency == 'USD',
              )
              .toList()
            ..sort((a, b) {
              final time = a.startsAt.compareTo(b.startsAt);
              return time == 0 ? a.id.compareTo(b.id) : time;
            });
      setState(() {
        _hasLoaded = true;
        _games = games;
        _bookedIds = {for (final booking in bookings) booking.gameId};
        final dates = _dates;
        if (!dates.contains(_selectedDate)) {
          _selectedDate =
              dates.where((date) => !date.isBefore(_today)).firstOrNull ??
              dates.lastOrNull;
        }
      });
    } catch (error) {
      if (mounted && version == _loadVersion) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'We could not load fixtures. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted && version == _loadVersion) setState(() => _loading = false);
    }
  }

  Future<void> _play([OpenQueueGame? game]) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      if (game == null &&
          await showFieldrushFixturePlayChooser(context) != true) {
        return;
      }
      if (!mounted) return;
      if (widget.onPlay != null) {
        await widget.onPlay!(game);
      } else {
        await Navigator.of(context).push<OpenQueueBooking>(
          MaterialPageRoute(
            builder: (_) => FieldrushBookingFlow(
              repository: widget.repository,
              initialGame: game,
              onNavigateTab: widget.onNavigateTab,
              now: widget.now,
            ),
          ),
        );
      }
      if (mounted) await _load();
    } catch (error) {
      _showRouteError(error);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _openGame(OpenQueueGame game) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      if (widget.onOpenGame != null) {
        await widget.onOpenGame!(game);
      } else {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => FieldrushGameDetailScreen(
              repository: widget.repository,
              gameId: game.id,
              initialGame: game,
              fixtureRepository: widget.fixtureRepository,
              onJoin: (game) async {
                if (widget.onPlay != null) {
                  await widget.onPlay!(game);
                } else {
                  await Navigator.of(context).push<OpenQueueBooking>(
                    MaterialPageRoute(
                      builder: (_) => FieldrushBookingFlow(
                        repository: widget.repository,
                        initialGame: game,
                        onNavigateTab: widget.onNavigateTab,
                        now: widget.now,
                      ),
                    ),
                  );
                }
              },
              onNavigateTab: widget.onNavigateTab,
            ),
          ),
        );
      }
      if (mounted) await _load();
    } catch (error) {
      _showRouteError(error);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _showRouteError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          userFacingError(
            error,
            fallback: 'We could not open this game. Try again.',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedDate;
    final games = _selectedGames;
    final past = selected != null && selected.isBefore(_today);
    final open = games.any(
      (game) => game.supportedRoles.any((role) => game.canBookAt(role, _now)),
    );
    final live = games.any(
      (game) => game.status == 'LIVE' && !game.hasPendingOperationalResolution,
    );
    final dayNote = live
        ? 'LIVE'
        : past
        ? games.every(
                (game) =>
                    game.status == 'FINAL' &&
                    !game.hasPendingOperationalResolution,
              )
              ? 'PLAYED'
              : 'PAST'
        : open
        ? 'OPEN'
        : games.isEmpty
        ? ''
        : 'MATCHDAY';
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: ColoredBox(
        color: _cream,
        child: SafeArea(
          bottom: false,
          child: FieldRefreshIndicator(
            color: _green,
            onRefresh: _load,
            child: ListView(
              key: const ValueKey('fieldrush-fixtures-list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 18, bottom: 132),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Fixtures', style: _outfit(25)),
                            const SizedBox(height: 2),
                            PopupMenuButton<String>(
                              key: const ValueKey('fixtures-city-picker'),
                              tooltip: 'Fixture city',
                              color: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                                side: const BorderSide(color: _border),
                              ),
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'Phoenix',
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Phoenix, AZ',
                                              style: _jakarta(13, color: _ink),
                                            ),
                                            const SizedBox(height: 5),
                                            Text(
                                              'Available matchdays below',
                                              style: _jakarta(10.5).copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Icon(
                                        Icons.check_rounded,
                                        color: _green,
                                        size: 18,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              child: SizedBox(
                                height: 36,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.location_on_outlined,
                                      size: 14,
                                      color: _green,
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        'Phoenix, AZ',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: _jakarta(
                                          12,
                                          color: const Color(0xFF24472C),
                                        ),
                                      ),
                                    ),
                                    const Icon(
                                      Icons.expand_more_rounded,
                                      color: _green,
                                      size: 15,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Semantics(
                        button: true,
                        label: 'Play a game',
                        child: Material(
                          color: _green,
                          borderRadius: BorderRadius.circular(999),
                          child: InkWell(
                            key: const ValueKey('fixtures-play-action'),
                            onTap: _opening ? null : _play,
                            borderRadius: BorderRadius.circular(999),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                11,
                                15,
                                11,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 19,
                                    height: 19,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFA7C957),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 14,
                                      color: _ink,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Play',
                                    style: _jakarta(12, color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_loading)
                  const Padding(
                    key: ValueKey('fixtures-loading-skeleton'),
                    padding: EdgeInsets.all(16),
                    child: FieldLoadingContent(
                      label: 'Loading fixtures',
                      rows: 3,
                    ),
                  )
                else if (_error != null)
                  _FixtureState(
                    title: 'Fixtures unavailable',
                    message: _error!,
                    onRetry: _load,
                  )
                else if (_games.isEmpty)
                  const _FixtureState(
                    title: 'No games yet',
                    message:
                        'Phoenix fixtures will appear here as soon as games are scheduled.',
                  )
                else ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _FixtureCalendar(
                      dates: _dates,
                      selected: selected!,
                      today: _today,
                      onSelected: (date) =>
                          setState(() => _selectedDate = date),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_weekdays[selected.weekday - 1]}, ${_months[selected.month - 1]} ${selected.day}',
                            style: _outfit(22),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          dayNote,
                          style: _jakarta(
                            10,
                            color: open ? FieldrushAuthTheme.danger : _muted,
                            tracking: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (var i = 0; i < games.length; i++)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 13, 16, 0),
                      child: FieldrushFixtureCard(
                        game: games[i],
                        slot: i + 1,
                        booked:
                            _bookedIds.contains(games[i].id) ||
                            games[i].hasMyBooking,
                        now: _now,
                        onOpen: _opening ? null : () => _openGame(games[i]),
                      ),
                    ),
                ],
                if (!_loading && _error == null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: _ClanComingSoon(slot: games.length + 1),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FixtureCalendar extends StatefulWidget {
  const _FixtureCalendar({
    required this.dates,
    required this.selected,
    required this.today,
    required this.onSelected,
  });
  final List<DateTime> dates;
  final DateTime selected;
  final DateTime today;
  final ValueChanged<DateTime> onSelected;
  @override
  State<_FixtureCalendar> createState() => _FixtureCalendarState();
}

class _FixtureCalendarState extends State<_FixtureCalendar> {
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(covariant _FixtureCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) _reveal();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !_scroll.hasClients) return;
    final scale = (MediaQuery.textScalerOf(context).scale(18) / 18).clamp(
      1.0,
      3.0,
    );
    final offset =
        (widget.dates.indexOf(widget.selected) * (44.0 * scale + 7) +
                22 * scale -
                _scroll.position.viewportDimension / 2)
            .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      offset,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  });
  @override
  Widget build(BuildContext context) {
    final scale = (MediaQuery.textScalerOf(context).scale(18) / 18).clamp(
      1.0,
      3.0,
    );
    final index = widget.dates.indexOf(widget.selected);
    final next = widget.dates
        .where((date) => !date.isBefore(widget.today))
        .firstOrNull;
    final label = widget.selected.isBefore(widget.today)
        ? 'PAST MATCHDAY'
        : widget.selected == next
        ? 'NEXT MATCHDAY'
        : 'MATCHDAY';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 15),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('fixtures-previous-day'),
                tooltip: 'Previous matchday',
                onPressed: index > 0
                    ? () => widget.onSelected(widget.dates[index - 1])
                    : null,
                icon: const Icon(Icons.chevron_left_rounded),
                color: _green,
                iconSize: 23,
              ),
              Expanded(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: _jakarta(10.5, tracking: 1.2),
                ),
              ),
              IconButton(
                key: const ValueKey('fixtures-next-day'),
                tooltip: 'Next matchday',
                onPressed: index < widget.dates.length - 1
                    ? () => widget.onSelected(widget.dates[index + 1])
                    : null,
                icon: const Icon(Icons.chevron_right_rounded),
                color: _green,
                iconSize: 23,
              ),
            ],
          ),
          const SizedBox(height: 3),
          SizedBox(
            height: 61 * scale,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final contentWidth =
                    widget.dates.length * 44 * scale +
                    (widget.dates.length - 1) * 7;
                final inset = ((constraints.maxWidth - contentWidth) / 2).clamp(
                  0.0,
                  constraints.maxWidth,
                );
                return ListView.separated(
                  key: const ValueKey('fixtures-date-strip'),
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.dates.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 7),
                  itemBuilder: (_, i) {
                    final date = widget.dates[i];
                    final active = date == widget.selected;
                    return Semantics(
                      selected: active,
                      button: true,
                      label:
                          '${_weekdays[date.weekday - 1]}, ${_months[date.month - 1]} ${date.day}, ${date.year}',
                      child: Material(
                        color: active ? _green : _wash,
                        borderRadius: BorderRadius.circular(13),
                        child: InkWell(
                          key: ValueKey('fixtures-date-${_dateKey(date)}'),
                          onTap: () => widget.onSelected(date),
                          borderRadius: BorderRadius.circular(13),
                          child: SizedBox(
                            width: 44 * scale,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _weekdays[date.weekday - 1].toUpperCase(),
                                  style: _jakarta(
                                    9,
                                    color: active
                                        ? const Color(0xFFC7DD9B)
                                        : _muted,
                                    tracking: .8,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  '${date.day}',
                                  style: _outfit(
                                    18,
                                    color: active ? Colors.white : _ink,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class FieldrushFixtureCard extends StatelessWidget {
  const FieldrushFixtureCard({
    super.key,
    required this.game,
    required this.slot,
    required this.booked,
    required this.now,
    this.onOpen,
  });
  final OpenQueueGame game;
  final int slot;
  final bool booked;
  final DateTime now;
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) {
    final canJoin =
        !booked && game.supportedRoles.any((role) => game.canBookAt(role, now));
    final upcoming =
        game.isUpcomingReservationAt(now) &&
        !game.hasPendingOperationalResolution;
    final spots = (game.capacity - game.confirmedCount).clamp(0, game.capacity);
    final note = game.hasPendingOperationalResolution
        ? game.operationalStatusLabel!.toUpperCase()
        : game.status == 'CANCELLED'
        ? 'CANCELLED'
        : booked && upcoming
        ? "YOU’RE IN · $spots ${spots == 1 ? 'SPOT' : 'SPOTS'} LEFT"
        : upcoming
        ? '$spots ${spots == 1 ? 'SPOT' : 'SPOTS'} LEFT'
        : game.statusLabel.toUpperCase();
    final average = game.matchAverageSr;
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('solo-fixture-${game.id}'),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 17, 18, 19),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SLOT $slot · SOLO',
                    style: _jakarta(
                      11,
                      color: const Color(0xFF24472C),
                      tracking: 1,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${game.startTimeLabel} · ${game.venue}',
                      textAlign: TextAlign.right,
                      style: _jakarta(
                        10.5,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: _muted,
                  ),
                ],
              ),
              if (game.shouldDisplayScore) ...[
                const SizedBox(height: 14),
                _score(
                  'White',
                  game.whiteScore,
                  game.myBookingTeam == openQueueWhiteTeamId,
                ),
                const SizedBox(height: 4),
                _score(
                  'Black',
                  game.blackScore,
                  game.myBookingTeam == openQueueBlackTeamId,
                ),
                const SizedBox(height: 12),
                Text(
                  note,
                  style: _jakarta(
                    10.5,
                    color: game.status == 'LIVE'
                        ? FieldrushAuthTheme.danger
                        : _muted,
                    tracking: .7,
                  ),
                ),
              ] else if (upcoming) ...[
                const SizedBox(height: 15),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          text: '${game.confirmedCount}',
                          style: _outfit(44),
                          children: [
                            TextSpan(
                              text: '/${game.capacity}',
                              style: _outfit(22, color: _muted),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (average != null) ...[
                      FieldrushDivisionShield(
                        division: divisionFromRating(average).number,
                        size: 20,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        'Div ${divisionFromRating(average).number}',
                        style: _outfit(11.5),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 13),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: game.capacity > 0
                        ? (game.confirmedCount / game.capacity).clamp(0.0, 1.0)
                        : 0,
                    minHeight: 10,
                    backgroundColor: _wash,
                    color: _green,
                  ),
                ),
                const SizedBox(height: 13),
                Text(
                  note,
                  style: _jakarta(
                    11,
                    color: canJoin ? FieldrushAuthTheme.danger : _green,
                    tracking: .5,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 18),
                Text(note, style: _outfit(22)),
                if (game.operationalStatusDetail != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    game.operationalStatusDetail!,
                    style: _jakarta(11.5).copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ],
              if (game.shouldDisplayScore && average != null) ...[
                const SizedBox(height: 14),
                const Divider(height: 1, color: Color(0xFFF0ECE0)),
                const SizedBox(height: 13),
                Row(
                  children: [
                    FieldrushDivisionShield(
                      division: divisionFromRating(average).number,
                      size: 20,
                    ),
                    const SizedBox(width: 9),
                    Text(
                      'Division ${divisionFromRating(average).number}',
                      style: _outfit(13),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'lobby average · $average SR',
                        style: _jakarta(
                          10.5,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
              if (upcoming) ...[
                const SizedBox(height: 15),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: ValueKey('fixture-game-action-${game.id}'),
                    onPressed: onOpen,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 12,
                      ),
                    ),
                    child: Text(canJoin ? 'Join game' : 'View game'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _score(String team, int? score, bool isMine) => Row(
    children: [
      Text(team, style: _outfit(27)),
      if (isMine) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: _wash,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text('YOU', style: _jakarta(8, tracking: .7)),
        ),
      ],
      const Spacer(),
      Text(score?.toString() ?? '—', style: _outfit(31)),
    ],
  );
}

class _ClanComingSoon extends StatelessWidget {
  const _ClanComingSoon({required this.slot});
  final int slot;
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: const _DashedBorder(),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 15, 16, 15),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SLOT $slot · CLAN', style: _jakarta(11, tracking: 1.2)),
                const SizedBox(height: 8),
                Text(
                  'Clan games are coming soon',
                  style: _jakarta(11.5).copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const _SoonPill(),
        ],
      ),
    ),
  );
}

class _SoonPill extends StatelessWidget {
  const _SoonPill();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFF7EED6),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      'COMING SOON',
      style: _jakarta(9, color: const Color(0xFF8A6516), tracking: 1),
    ),
  );
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder();
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(20)),
      );
    final paint = Paint()
      ..color = const Color(0xFFDED8C6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (double start = 0; start < metric.length; start += 8) {
        canvas.drawPath(
          metric.extractPath(start, (start + 4).clamp(0, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorder oldDelegate) => false;
}

class _FixtureState extends StatelessWidget {
  const _FixtureState({
    required this.title,
    required this.message,
    this.onRetry,
  });
  final String title;
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 44, 24, 36),
    child: Column(
      children: [
        const Icon(Icons.calendar_month_outlined, size: 32, color: _green),
        const SizedBox(height: 14),
        Text(title, style: _outfit(21), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          message,
          style: _jakarta(12).copyWith(fontWeight: FontWeight.w600),
          textAlign: TextAlign.center,
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 18),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ],
    ),
  );
}

Future<bool?> showFieldrushFixturePlayChooser(BuildContext context) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _cream,
      barrierColor: const Color(0x85172415),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDED8C6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text('Start a game', style: _outfit(19)),
                ),
                const SizedBox(height: 14),
                Material(
                  color: _green,
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    key: const ValueKey('play-solo-choice'),
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => Navigator.pop(context, true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 17,
                        vertical: 16,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .18),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              '1',
                              style: _outfit(15, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Solo game',
                                  style: _outfit(15, color: Colors.white),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Pick your positions. Find your next game.',
                                  style: _jakarta(
                                    11,
                                    color: const Color(0xFFC7DD9B),
                                  ).copyWith(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFFC7DD9B),
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                Semantics(
                  button: true,
                  enabled: false,
                  child: Container(
                    key: const ValueKey('play-clan-choice'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 17,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFBFAF4),
                      border: Border.all(color: const Color(0xFFEDEAE0)),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFEDE4),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            '11',
                            style: _outfit(15, color: const Color(0xFF7D7866)),
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Clan game',
                                style: _outfit(
                                  15,
                                  color: const Color(0xFF7D7866),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Play as a team with your clan',
                                style: _jakarta(
                                  11,
                                  color: const Color(0xFF7D7866),
                                ).copyWith(fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const _SoonPill(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

DateTime _date(DateTime date) => DateTime(date.year, date.month, date.day);
String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
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
