import 'package:flutter/material.dart';
import 'fieldrush_check_in_notice.dart';

import '../ui/field_loading.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../core/read_timeout.dart';
import '../home/field_bottom_nav.dart';
import '../markets/fieldrush_city.dart';
import '../markets/fieldrush_city_repository.dart';
import 'fieldrush_booking_widgets.dart';
import 'fieldrush_checkout_sheet.dart';
import 'fieldrush_game_detail_screen.dart';
import 'open_queue.dart';
import 'open_queue_repository.dart';

/// The prototype's preference picker is not a reservation. Only checkout can
/// create one; every preceding step is local selection over fresh server data.
class FieldrushBookingFlow extends StatefulWidget {
  const FieldrushBookingFlow({
    super.key,
    required this.repository,
    this.initialGame,
    this.initialRoles = const {},
    this.startAtGames = false,
    this.onNavigateTab,
    this.now,
    this.cityRepository,
  });

  final OpenQueueRepository repository;
  final OpenQueueGame? initialGame;
  final Set<OpenQueueRole> initialRoles;
  final bool startAtGames;
  final ValueChanged<int>? onNavigateTab;
  final DateTime? now;
  final FieldrushCityRepository? cityRepository;

  @override
  State<FieldrushBookingFlow> createState() => _FieldrushBookingFlowState();
}

/// Highest number of open slots, then prototype order, within the player's
/// selected positions. Never silently replace their preference with another.
OpenQueueRole? fieldrushSuggestedRole(
  OpenQueueGame game,
  Set<OpenQueueRole> wanted,
  DateTime now,
) {
  final available = fieldrushOpenQueueRoles
      .where(
        (role) =>
            (wanted.isEmpty || wanted.contains(role)) &&
            game.canBookAt(role, now),
      )
      .toList();
  available.sort((a, b) {
    final comparison = game.spotsFor(b).compareTo(game.spotsFor(a));
    return comparison != 0 ? comparison : a.index.compareTo(b.index);
  });
  return available.firstOrNull;
}

class _FieldrushBookingFlowState extends State<FieldrushBookingFlow> {
  late final Set<OpenQueueRole> _roles = widget.initialRoles
      .where(fieldrushOpenQueueRoles.contains)
      .toSet();
  late int _step = widget.initialGame != null
      ? 3
      : widget.startAtGames
      ? 2
      : 1;
  late OpenQueueGame? _selectedGame = widget.initialGame;
  OpenQueueRole? _selectedRole;
  OpenQueueBooking? _confirmed;
  OpenQueueBooking? _activeBooking;
  bool _openingActiveGame = false;
  List<OpenQueueGame> _games = [];
  bool _loading = true;
  bool _hasLoaded = false;
  bool _availabilityReady = false;
  String? _error;
  int _generation = 0;
  final _scrollController = ScrollController();

  DateTime get _now => widget.now ?? DateTime.now();
  List<OpenQueueGame> get _matches => _games
      .where((game) => fieldrushSuggestedRole(game, _roles, _now) != null)
      .toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _resetScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  void _goStep(int step) {
    setState(() {
      _step = step;
      _error = null;
    });
    _resetScroll();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = !_hasLoaded;
      _availabilityReady = false;
      _error = null;
    });
    try {
      final repository = widget.repository;
      final cityRepository =
          widget.cityRepository ??
          (repository is SupabaseOpenQueueRepository
              ? SupabaseFieldrushCityRepository()
              : null);
      final preferredCity = cityRepository == null
          ? FieldrushCity.phoenix
          : await cityRepository.loadPreferredCity().timeout(fieldReadTimeout);
      if (!mounted || generation != _generation) return;
      final cityId = widget.initialGame?.marketCityId ?? preferredCity.id;
      final timezone = widget.initialGame?.timezone ?? preferredCity.timezone;
      final result = await Future.wait([
        repository is OpenQueueCityRepository
            ? (repository as OpenQueueCityRepository).listCityGames(cityId)
            : repository is OpenQueueMarketRepository
            ? (repository as OpenQueueMarketRepository).listMarketGames(
                timezone,
              )
            : repository.listGames(),
        repository.getMyUpcomingBookings(),
      ]).timeout(fieldReadTimeout);
      if (!mounted || generation != _generation) return;
      final bookings = result[1] as List<OpenQueueBooking>;
      final activeBooking = bookings.where((booking) {
        return booking.status == 'CONFIRMED' &&
            booking.game.blocksNewBookingAt(_now);
      }).firstOrNull;
      final bookedIds = bookings.map((b) => b.gameId).toSet();
      final games =
          (result[0] as List<OpenQueueGame>)
              .where(
                (g) =>
                    g.belongsToCity(cityId, timezone) &&
                    g.currency == 'USD' &&
                    !bookedIds.contains(g.id) &&
                    fieldrushSuggestedRole(g, {}, _now) != null,
              )
              .toList()
            ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
      setState(() {
        _hasLoaded = true;
        _availabilityReady = true;
        _activeBooking = activeBooking;
        _games = games;
        final selected = _selectedGame;
        if (selected != null) {
          _selectedGame = games.where((g) => g.id == selected.id).firstOrNull;
          if (_selectedGame == null) {
            _selectedRole = null;
            _error = 'This game is no longer available. Pick another game.';
            _step = 2;
          } else if (_selectedRole != null &&
              !_selectedGame!.canBookAt(_selectedRole!, _now)) {
            _selectedRole = null;
          } else if (_selectedRole == null && _roles.isNotEmpty) {
            _selectedRole = fieldrushSuggestedRole(
              _selectedGame!,
              _roles,
              _now,
            );
          }
        }
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(
        () => _error = userFacingError(
          error,
          fallback: 'Could not load available games. Try again.',
        ),
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _back() {
    if (_confirmed != null) {
      Navigator.of(context).pop(_confirmed);
    } else if (_step > 1) {
      _goStep(_step - 1);
    } else {
      Navigator.of(context).pop();
    }
  }

  void _pick(OpenQueueGame game, {bool anyPosition = false}) {
    setState(() {
      _selectedGame = game;
      _selectedRole = fieldrushSuggestedRole(
        game,
        anyPosition ? {} : _roles,
        _now,
      );
      _step = 3;
      _error = null;
    });
    _resetScroll();
  }

  Future<void> _checkout() async {
    final game = _selectedGame;
    final role = _selectedRole;
    if (!_availabilityReady ||
        _loading ||
        _activeBooking != null ||
        game == null ||
        role == null ||
        !game.canBookAt(role, _now)) {
      return;
    }
    final result = await showFieldrushCheckout(
      context: context,
      repository: widget.repository,
      game: game,
      role: role,
    );
    if (!mounted) return;
    if (result != null) {
      setState(() => _confirmed = result);
    } else {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: PopScope<OpenQueueBooking>(
      canPop: _confirmed != null || _step == 1,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: Scaffold(
        extendBody: true,
        backgroundColor: FieldrushAuthTheme.cream,
        bottomNavigationBar: widget.onNavigateTab == null
            ? null
            : FieldBottomNav(
                selectedIndex: 1,
                onSelected: (index) {
                  widget.onNavigateTab!(index);
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
              ),
        body: SafeArea(
          bottom: false,
          child: _confirmed != null
              ? _confirmation(_confirmed!)
              : FieldRefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    key: ValueKey('booking-step-$_step'),
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      16,
                      18,
                      16,
                      widget.onNavigateTab == null ? 36 : 132,
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            _headerAction(
                              label: 'Back',
                              icon: Icons.chevron_left,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                [
                                  'Your positions',
                                  'Pick a game',
                                  'Confirm booking',
                                ][_step - 1],
                                style: bookingHeading(18),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'STEP $_step OF 3',
                              style: bookingText(
                                10,
                                bold: true,
                              ).copyWith(letterSpacing: 1),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            for (var i = 1; i <= 3; i++)
                              Expanded(
                                child: Container(
                                  height: 5,
                                  margin: EdgeInsets.only(right: i < 3 ? 6 : 0),
                                  decoration: BoxDecoration(
                                    color: i <= _step
                                        ? FieldrushAuthTheme.forest
                                        : FieldrushAuthTheme.border,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 11),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(switch (_step) {
                          1 =>
                            'Tell us where you play and we only show games that still need you.',
                          2 =>
                            'Pick a game — your spot is whichever of your positions it needs most.',
                          _ => 'One look before you are in.',
                        }, style: bookingText(12)),
                      ),
                      const SizedBox(height: 18),
                      if (_loading)
                        const FieldLoadingContent(
                          label: 'Loading available positions and games',
                          rows: 3,
                        )
                      else if (_activeBooking != null)
                        _activeGameNotice(_activeBooking!)
                      else ...[
                        if (_error != null) ...[
                          Text(
                            _error!,
                            style: bookingText(
                              13,
                              color: FieldrushAuthTheme.danger,
                            ),
                          ),
                          TextButton(
                            onPressed: _load,
                            child: const Text('Try again'),
                          ),
                        ],
                        if (_error == null || _games.isNotEmpty)
                          ...switch (_step) {
                            1 => _positions(),
                            2 => _gameChoices(),
                            _ => _review(),
                          },
                      ],
                    ],
                  ),
                ),
        ),
      ),
    ),
  );

  Future<void> _openActiveGame() async {
    final booking = _activeBooking;
    if (booking == null || _openingActiveGame) return;
    setState(() => _openingActiveGame = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => FieldrushGameDetailScreen(
            repository: widget.repository,
            gameId: booking.gameId,
            initialGame: booking.game,
            onNavigateTab: widget.onNavigateTab,
          ),
        ),
      );
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _openingActiveGame = false);
    }
  }

  Widget _activeGameNotice(OpenQueueBooking booking) => Container(
    key: const ValueKey('booking-active-game-limit'),
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: FieldrushAuthTheme.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.event_available_rounded,
          color: FieldrushAuthTheme.forest,
          size: 32,
        ),
        const SizedBox(height: 14),
        Text('You’re already in a game', style: bookingHeading(24)),
        const SizedBox(height: 9),
        Text(
          'One upcoming or active game at a time. Finish or cancel your current booking before joining another.',
          style: bookingText(13),
        ),
        const SizedBox(height: 18),
        Text(booking.game.venue, style: bookingHeading(16)),
        const SizedBox(height: 5),
        Text(booking.game.displayProminentDateLabel, style: bookingText(12)),
        Text(
          '${booking.game.isUpcoming ? 'Check-in ' : ''}${booking.game.displayTimeLabel}',
          style: bookingText(12),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('booking-view-active-game'),
            onPressed: _openingActiveGame ? null : _openActiveGame,
            child: Text(
              _openingActiveGame ? 'Opening game…' : 'View your game',
            ),
          ),
        ),
      ],
    ),
  );

  Widget _headerAction({required String label, required IconData icon}) =>
      SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          onPressed: _back,
          tooltip: label,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF3C4A38),
            padding: EdgeInsets.zero,
            side: const BorderSide(color: FieldrushAuthTheme.border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: Icon(icon, size: label == 'Done' ? 16 : 21),
        ),
      );

  ButtonStyle get _secondaryActionStyle => OutlinedButton.styleFrom(
    backgroundColor: Colors.white,
    foregroundColor: FieldrushAuthTheme.ink,
    minimumSize: const Size(0, 46),
    side: const BorderSide(color: FieldrushAuthTheme.border),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    textStyle: bookingText(12.5, color: FieldrushAuthTheme.ink, bold: true),
  );

  List<Widget> _positions() => [
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'POSITIONS YOU PLAY',
              style: bookingText(11, bold: true).copyWith(letterSpacing: 1.3),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _roles.isEmpty ? 'Any position' : '${_roles.length} selected',
            style: bookingText(11),
          ),
        ],
      ),
    ),
    const SizedBox(height: 12),
    for (final role in fieldrushOpenQueueRoles) ...[
      _positionTile(role),
      const SizedBox(height: 9),
    ],
    const SizedBox(height: 7),
    FilledButton(
      key: const ValueKey('booking-see-games'),
      onPressed: () => _goStep(2),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: bookingText(13.5, color: Colors.white, bold: true),
      ),
      child: Text(
        _matches.isEmpty
            ? 'See open games'
            : 'See ${_matches.length} matching ${_matches.length == 1 ? 'game' : 'games'}',
      ),
    ),
  ];

  Widget _positionTile(OpenQueueRole role) {
    final on = _roles.contains(role);
    final count = _games.where((g) => g.canBookAt(role, _now)).length;
    final foreground = on ? Colors.white : FieldrushAuthTheme.ink;
    final secondary = on ? const Color(0xFFC7DD9B) : FieldrushAuthTheme.muted;
    final nameStyle = bookingHeading(15, color: foreground);
    final slotStyle = bookingText(11, color: secondary);
    final countStyle = bookingText(
      10.5,
      color: on || count > 0 ? secondary : const Color(0xFFA29D8B),
    ).copyWith(fontWeight: FontWeight.w700);
    final slotLabel = roleCapacityLabelForGames(role, _games);
    final countLabel = count == 0
        ? 'None open'
        : '$count ${count == 1 ? 'game' : 'games'} open';
    return Semantics(
      selected: on,
      child: Material(
        color: on ? FieldrushAuthTheme.forest : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: on ? FieldrushAuthTheme.forest : FieldrushAuthTheme.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('booking-position-${role.code}'),
          onTap: () => setState(() {
            if (!_roles.remove(role)) _roles.add(role);
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scaler = MediaQuery.textScalerOf(context);
                double textWidth(String text, TextStyle style) {
                  final painter = TextPainter(
                    text: TextSpan(text: text, style: style),
                    textDirection: Directionality.of(context),
                    textScaler: scaler,
                  )..layout();
                  final width = painter.width;
                  painter.dispose();
                  return width;
                }

                final nameWidth = textWidth(bookingRoleName(role), nameStyle);
                final slotWidth = textWidth(slotLabel, slotStyle);
                final labelWidth = nameWidth > slotWidth
                    ? nameWidth
                    : slotWidth;
                // Keep the source's trailing tag at normal widths. At large text
                // sizes, move it under the subtitle instead of squeezing labels.
                final stackedCount =
                    constraints.maxWidth <
                    109 + labelWidth + textWidth(countLabel, countStyle);
                return Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: on
                            ? Colors.white.withValues(alpha: .2)
                            : const Color(0xFFF2EFE3),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Text(
                        role.code,
                        style: bookingHeading(13, color: foreground),
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(bookingRoleName(role), style: nameStyle),
                          const SizedBox(height: 6),
                          Text(slotLabel, style: slotStyle),
                          if (stackedCount) ...[
                            const SizedBox(height: 4),
                            Text(countLabel, style: countStyle),
                          ],
                        ],
                      ),
                    ),
                    if (!stackedCount) ...[
                      const SizedBox(width: 13),
                      Text(countLabel, style: countStyle),
                    ],
                    const SizedBox(width: 13),
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: on
                            ? const Color(0xFFA7C957)
                            : Colors.transparent,
                        shape: BoxShape.circle,
                        border: on
                            ? null
                            : Border.all(
                                color: const Color(0xFFDED8C6),
                                width: 1.5,
                              ),
                      ),
                      child: on
                          ? const Icon(
                              Icons.check_rounded,
                              color: Color(0xFF1D2A1B),
                              size: 15,
                            )
                          : null,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _gameChoices() {
    final matches = _matches;
    final sooner = _games
        .where(
          (g) => matches.isEmpty || g.startsAt.isBefore(matches.first.startsAt),
        )
        .firstOrNull;
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              _roles.isEmpty
                  ? 'ALL OPEN GAMES'
                  : 'GAMES NEEDING YOUR POSITIONS',
              style: bookingText(10, bold: true),
            ),
          ),
          TextButton(
            onPressed: () => _goStep(1),
            child: Text(
              _roles.isEmpty
                  ? 'Any position ›'
                  : '${_roles.map((r) => r.code).join(' · ')} ›',
              style: bookingText(
                11,
                color: FieldrushAuthTheme.forest,
                bold: true,
              ),
            ),
          ),
        ],
      ),
      if (matches.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Text(
            _games.isEmpty
                ? 'No upcoming games are open yet. Check back soon.'
                : 'No upcoming game needs those positions yet. Go back and widen your picks.',
            style: bookingText(13),
          ),
        ),
      for (final game in matches) ...[
        _gameTile(game),
        const SizedBox(height: 9),
      ],
      if (sooner != null) ...[
        const SizedBox(height: 20),
        Center(
          child: Text(
            'OR PLAY SOONER',
            style: bookingText(10, color: const Color(0xFF8A6516), bold: true),
          ),
        ),
        const SizedBox(height: 12),
        _gameTile(sooner, anyPosition: true),
      ],
    ];
  }

  Widget _gameTile(OpenQueueGame game, {bool anyPosition = false}) {
    final role = fieldrushSuggestedRole(game, anyPosition ? {} : _roles, _now)!;
    final count = fieldrushOpenQueueRoles
        .where(
          (r) =>
              (anyPosition || _roles.isEmpty || _roles.contains(r)) &&
              game.canBookAt(r, _now),
        )
        .fold<int>(0, (n, r) => n + game.spotsFor(r));
    return Material(
      color: anyPosition ? const Color(0xFFFDFBF3) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: FieldrushAuthTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('booking-game-${game.id}${anyPosition ? '-sooner' : ''}'),
        onTap: () => _pick(game, anyPosition: anyPosition),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  BookingDateBadge(game: game),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Check-in ${game.displayTimeLabel}',
                          style: bookingHeading(16),
                        ),
                        Text(game.venue, style: bookingText(11)),
                        const SizedBox(height: 5),
                        Text(
                          '${anyPosition ? 'Out of position' : 'Your spot'} · ${bookingRoleName(role)}',
                          style: bookingText(11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        game.priceLabel,
                        style: bookingText(
                          12,
                          color: FieldrushAuthTheme.ink,
                          bold: true,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '$count ${count == 1 ? 'spot' : 'spots'}',
                        style: bookingText(
                          10,
                          color: FieldrushAuthTheme.forest,
                          bold: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (game.isUpcoming) ...[
                const SizedBox(height: 12),
                FieldrushCheckInNotice(game: game),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _review() {
    final game = _selectedGame;
    if (game == null) {
      return [
        Text('Pick an available game to continue.', style: bookingText(13)),
      ];
    }
    return [
      BookingPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 16,
              runSpacing: 8,
              children: [
                Text(
                  'CHECK-IN · ${game.displayTimeLabel}',
                  style: bookingText(
                    11,
                    color: FieldrushAuthTheme.forest,
                    bold: true,
                  ),
                ),
                Text(
                  '${game.capacity - game.confirmedCount} SPOTS LEFT',
                  style: bookingText(
                    10,
                    color: FieldrushAuthTheme.danger,
                    bold: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(game.displayCalendarDateLabel, style: bookingHeading(28)),
            const SizedBox(height: 8),
            Text(
              '${game.venue} · ${game.endsAt.difference(game.startsAt).inMinutes} min',
              style: bookingText(12),
            ),
            if (game.locationLabel case final String address) ...[
              const SizedBox(height: 6),
              Text(address, style: bookingText(12)),
            ],
            if (game.isUpcoming) ...[
              const SizedBox(height: 12),
              FieldrushCheckInNotice(game: game),
            ],
            const Divider(height: 32, color: FieldrushAuthTheme.border),
            if (_selectedRole != null)
              BookingValueRow('Your position', bookingRoleName(_selectedRole!)),
            if (widget.initialGame != null) ...[
              Text('YOUR POSITION', style: bookingText(10, bold: true)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final role in fieldrushOpenQueueRoles)
                    ChoiceChip(
                      key: ValueKey('booking-review-position-${role.code}'),
                      label: Text(
                        '${bookingRoleName(role)} · ${game.canBookAt(role, _now) ? '${game.spotsFor(role)} open' : 'Full'}',
                      ),
                      selected: _selectedRole == role,
                      onSelected: !game.canBookAt(role, _now)
                          ? null
                          : (_) => setState(() => _selectedRole = role),
                    ),
                ],
              ),
            ],
            BookingValueRow(
              'Squad so far',
              '${game.confirmedCount} of ${game.capacity}',
            ),
            BookingValueRow(
              'Format',
              '${game.hasConfigurableMinimum ? 'Up to ' : ''}${game.capacity ~/ 2}v${game.capacity ~/ 2}',
            ),
            BookingValueRow('Ends at', game.plannedEndTimeLabel),
            if (game.hasConfigurableMinimum)
              BookingValueRow('Players needed', game.minimumPlayersLabel),
            BookingValueRow('Match fee', game.priceLabel),
          ],
        ),
      ),
      const SizedBox(height: 14),
      FilledButton(
        key: const ValueKey('booking-continue-payment'),
        onPressed: !_availabilityReady || _selectedRole == null
            ? null
            : _checkout,
        child: const Text('Continue to payment'),
      ),
      const SizedBox(height: 9),
      OutlinedButton(
        onPressed: () => _goStep(2),
        style: _secondaryActionStyle,
        child: const Text('Pick another game'),
      ),
      const SizedBox(height: 12),
      Text(
        'Your spot is confirmed only after payment. Any discount or refundable reliability deposit is shown before you pay.',
        style: bookingText(11.5),
      ),
      const SizedBox(height: 6),
      Text(
        'Teams are drawn ${game.teamAssignmentLeadLabel} once the game is full.',
        style: bookingText(11.5),
      ),
    ];
  }

  Widget _confirmation(OpenQueueBooking booking) => ListView(
    padding: EdgeInsets.fromLTRB(
      16,
      18,
      16,
      widget.onNavigateTab == null ? 36 : 132,
    ),
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: _headerAction(label: 'Done', icon: Icons.close),
        ),
      ),
      const SizedBox(height: 14),
      const Align(
        alignment: Alignment.centerLeft,
        child: CircleAvatar(
          radius: 26,
          backgroundColor: FieldrushAuthTheme.forest,
          child: Icon(Icons.check, color: Colors.white, size: 30),
        ),
      ),
      const SizedBox(height: 18),
      Text('You’re in', style: bookingHeading(36)),
      const SizedBox(height: 10),
      Text(
        'Solo game · ${booking.game.confirmedCount} of ${booking.game.capacity} players in',
        style: bookingText(13),
      ),
      const SizedBox(height: 24),
      BookingPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              booking.game.displayCalendarDateLabel.toUpperCase(),
              style: bookingText(10, bold: true),
            ),
            const SizedBox(height: 10),
            Text(booking.game.displayTimeLabel, style: bookingHeading(34)),
            Text('CHECK-IN', style: bookingText(10, bold: true)),
            const SizedBox(height: 9),
            Text(booking.game.venue, style: bookingText(12)),
            if (booking.game.isUpcoming) ...[
              const SizedBox(height: 12),
              FieldrushCheckInNotice(game: booking.game),
            ],
            if (booking.game.locationLabel case final String address) ...[
              const SizedBox(height: 6),
              Text(address, style: bookingText(12)),
            ],
            const Divider(height: 32, color: FieldrushAuthTheme.border),
            BookingValueRow('POSITION', bookingRoleName(booking.role)),
            BookingValueRow(
              'PAID',
              bookingMoney(booking.amountPaidFils, booking.game.currency),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Text(
        'Manage your spot from the game page. We’ll show the exact policy refund before you cancel.',
        style: bookingText(11),
      ),
      const SizedBox(height: 20),
      FilledButton(
        key: const ValueKey('booking-view-game'),
        onPressed: () async {
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => FieldrushGameDetailScreen(
                repository: widget.repository,
                gameId: booking.gameId,
                initialGame: booking.game,
                onNavigateTab: widget.onNavigateTab,
                onJoin: (game) async {
                  await showFieldrushCheckout(
                    context: context,
                    repository: widget.repository,
                    game: game,
                  );
                },
              ),
            ),
          );
          if (mounted && ModalRoute.of(context)?.isCurrent == true) {
            Navigator.of(context).pop(booking);
          }
        },
        child: const Text('View game'),
      ),
      const SizedBox(height: 9),
      OutlinedButton(
        onPressed: _back,
        style: _secondaryActionStyle,
        child: const Text('Done'),
      ),
    ],
  );
}
