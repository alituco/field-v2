import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/field_loading.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../clans/clan.dart';
import '../clans/clan_repository.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_detail_screen.dart';
import '../fixtures/fixture_reliability_roster.dart';
import '../fixtures/fixture_repository.dart';
import '../leaderboard/leaderboard.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../leaderboard/fieldrush_rating_tracks.dart';
import '../leaderboard/fieldrush_seasons.dart';
import '../markets/fieldrush_city.dart';
import '../markets/fieldrush_city_repository.dart';
import '../open_queue/open_queue.dart';
import '../open_queue/fieldrush_booking_flow.dart';
import '../open_queue/fieldrush_checkout_sheet.dart';
import '../open_queue/fieldrush_game_detail_screen.dart';
import '../open_queue/open_queue_party_repository.dart';
import '../open_queue/open_queue_repository.dart';
import '../profile/profile.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import 'fieldrush_home_widgets.dart';
import 'home_discovery_repository.dart';
import 'home_discovery_screen.dart';
import 'navigation_profile_scope.dart';

class DashboardHome extends StatefulWidget {
  const DashboardHome({
    super.key,
    this.activationTick = 0,
    required this.profileRepository,
    required this.clanRepository,
    required this.fixtureRepository,
    required this.leaderboardRepository,
    required this.openQueueRepository,
    required this.onOpenClans,
    required this.onOpenFixtures,
    required this.onOpenRanks,
    required this.onOpenProfile,
    required this.onNavigateTab,
    this.discoveryRepository,
    this.cityRepository,
    this.ratingTrackController,
  });
  final int activationTick;
  final ProfileRepository profileRepository;
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final LeaderboardRepository leaderboardRepository;
  final OpenQueueRepository openQueueRepository;
  final HomeDiscoveryRepository? discoveryRepository;
  final FieldrushCityRepository? cityRepository;
  final ValueNotifier<RatingTrack>? ratingTrackController;
  final VoidCallback onOpenClans;
  final VoidCallback onOpenFixtures;
  final VoidCallback onOpenRanks;
  final VoidCallback onOpenProfile;
  final ValueChanged<int> onNavigateTab;

  @override
  State<DashboardHome> createState() => _DashboardHomeState();
}

class _DashboardHomeState extends State<DashboardHome> {
  PlayerProfile? _profile;
  PlayerRatingLeaderboardEntry? _rating;
  FieldrushPlayerRatings? _ratings;
  RatingTrack _ratingTrack = RatingTrack.outfield;
  LeaderboardSeason? _season;
  List<OpenQueueBooking> _bookings = [];
  List<OpenQueueGame> _games = [];
  List<OpenQueueGame> _fixtureGames = [];
  List<Fixture> _fixtures = [];
  Clan? _clan;
  MyClanMembership? _membership;
  final _rosters = <String, FixtureReliabilityRoster>{};
  List<HomeNotification> _notifications = [];
  _PartyNotice? _party;
  bool _loading = true;
  String? _error;
  int _loadVersion = 0;
  StreamSubscription<void>? _partySubscription;
  FieldrushCity _city = FieldrushCity.phoenix;

  @override
  void initState() {
    super.initState();
    _ratingTrack = widget.ratingTrackController?.value ?? RatingTrack.outfield;
    widget.ratingTrackController?.addListener(_syncRatingTrack);
    fieldrushCityRevision.addListener(_load);
    _load();
    final repo = widget.openQueueRepository;
    if (repo is OpenQueuePartyNotificationRepository) {
      _partySubscription = (repo as OpenQueuePartyNotificationRepository)
          .watchPartyInviteNotifications()
          .listen((_) {
            if (mounted) _load();
          }, onError: (Object _, StackTrace __) {});
    }
  }

  @override
  void didUpdateWidget(covariant DashboardHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ratingTrackController != widget.ratingTrackController) {
      oldWidget.ratingTrackController?.removeListener(_syncRatingTrack);
      widget.ratingTrackController?.addListener(_syncRatingTrack);
      _syncRatingTrack();
    }
    if (oldWidget.activationTick != widget.activationTick) _load();
  }

  @override
  void dispose() {
    widget.ratingTrackController?.removeListener(_syncRatingTrack);
    _partySubscription?.cancel();
    fieldrushCityRevision.removeListener(_load);
    super.dispose();
  }

  void _syncRatingTrack() {
    if (!mounted) return;
    setState(() {
      _ratingTrack =
          widget.ratingTrackController?.value ?? RatingTrack.outfield;
      if (_ratings != null) _rating = _ratings!.forTrack(_ratingTrack);
    });
  }

  void _chooseRatingTrack(RatingTrack track) {
    if (widget.ratingTrackController != null) {
      widget.ratingTrackController!.value = track;
    } else {
      setState(() {
        _ratingTrack = track;
        _rating = _ratings?.forTrack(track);
      });
    }
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    final navigationProfile = FieldNavigationProfileScope.beginRead(context);
    setState(() {
      // Keep a valid feed visible while refreshing it in the background.
      _loading = _profile == null;
      _error = null;
    });
    try {
      final season = await loadActiveLeaderboardSeason(
        widget.leaderboardRepository,
      );
      if (!mounted || version != _loadVersion) return;
      final openQueue = widget.openQueueRepository;
      final cityRepository =
          widget.cityRepository ??
          (openQueue is SupabaseOpenQueueRepository
              ? SupabaseFieldrushCityRepository()
              : null);
      final city = cityRepository == null
          ? FieldrushCity.phoenix
          : await cityRepository.loadPreferredCity();
      if (!mounted || version != _loadVersion) return;
      final failures = <String>[];
      Future<T?> optional<T>(String label, Future<T> future) async {
        try {
          return await future;
        } catch (_) {
          failures.add(label);
          return null;
        }
      }

      final data = await Future.wait<Object?>([
        widget.profileRepository.getCurrentProfile(),
        optional(
          'rating',
          widget.leaderboardRepository is TrackLeaderboardRepository
              ? (widget.leaderboardRepository as TrackLeaderboardRepository)
                    .loadPlayerRatings(season: season)
              : widget.leaderboardRepository.loadCurrentPlayerRating(season),
        ),
        optional(
          'bookings',
          widget.openQueueRepository.getMyUpcomingBookings(),
        ),
        optional(
          'available games',
          openQueue is OpenQueueCityRepository
              ? (openQueue as OpenQueueCityRepository).listCityGames(city.id)
              : openQueue is OpenQueueMarketRepository
              ? (openQueue as OpenQueueMarketRepository).listMarketGames(
                  city.timezone,
                )
              : openQueue.listGames(),
        ),
        optional('clans', widget.clanRepository.listClans()),
        optional<ClanMembership?>(
          'clan membership',
          widget.clanRepository.getMyClanMembership(),
        ),
        optional<MyClanMembership?>(
          'fixture membership',
          widget.fixtureRepository.getMyClanMembership(),
        ),
        optional('clan games', widget.fixtureRepository.listFixtures()),
        optional('live games', widget.openQueueRepository.listFixtureGames()),
        if (widget.discoveryRepository != null)
          optional('activity', widget.discoveryRepository!.notifications()),
      ]);
      if (!mounted || version != _loadVersion) return;
      final profile = data[0] as PlayerProfile;
      final bookings =
          (data[2] as List<OpenQueueBooking>? ?? [])
              .where(
                (b) =>
                    b.status.toUpperCase() == 'CONFIRMED' &&
                    ![
                      'CANCELLED',
                      'FINAL',
                    ].contains(b.game.status.toUpperCase()) &&
                    !b.game.hasPendingOperationalResolution,
              )
              .toList()
            ..sort((a, b) => a.game.startsAt.compareTo(b.game.startsAt));
      final membership = data[5] as ClanMembership?;
      final clans = data[4] as List<Clan>? ?? [];
      final fixtures = data[7] as List<Fixture>? ?? [];
      final clan = clans.where((c) => c.id == membership?.clanId).firstOrNull;
      final rosterRepo = widget.fixtureRepository;
      final rosters = <String, FixtureReliabilityRoster>{};
      if (clan != null && rosterRepo is FixtureReliabilityRosterRepository) {
        final candidates =
            fixtures
                .where(
                  (f) =>
                      (f.homeClanId == clan.id || f.awayClanId == clan.id) &&
                      _isUpcomingClan(f),
                )
                .toList()
              ..sort(
                (a, b) => a.scheduledStartAt.compareTo(b.scheduledStartAt),
              );
        await Future.wait([
          for (final fixture in candidates.take(3))
            () async {
              final roster = await optional(
                'clan roster',
                (rosterRepo as FixtureReliabilityRosterRepository)
                    .getMyFixtureReliabilityRoster(fixture.id),
              );
              if (roster != null) rosters[fixture.id] = roster;
            }(),
        ]);
      }
      final party = await _loadParty(bookings);
      if (!mounted || version != _loadVersion) return;
      navigationProfile?.complete(profile);
      setState(() {
        _profile = profile;
        _city = city;
        _ratings = data[1] is FieldrushPlayerRatings
            ? data[1] as FieldrushPlayerRatings
            : null;
        _rating =
            _ratings?.forTrack(_ratingTrack) ??
            (data[1] is PlayerRatingLeaderboardEntry
                ? data[1] as PlayerRatingLeaderboardEntry
                : null);
        _season = season;
        _bookings = bookings;
        _games = data[3] as List<OpenQueueGame>? ?? [];
        _fixtureGames = data[8] as List<OpenQueueGame>? ?? [];
        _fixtures = fixtures;
        _clan = clan;
        _membership = data[6] as MyClanMembership?;
        _rosters
          ..clear()
          ..addAll(rosters);
        _party = party;
        _notifications = data.length > 9
            ? data[9] as List<HomeNotification>? ?? []
            : [];
        if (failures.isNotEmpty) {
          _error =
              'Could not refresh ${failures.toSet().join(', ')}. Pull down to try again.';
        }
      });
    } catch (error) {
      if (mounted && version == _loadVersion) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'We could not load your home feed.',
          ),
        );
      }
    } finally {
      if (mounted && version == _loadVersion) setState(() => _loading = false);
    }
  }

  bool _isUpcomingClan(Fixture fixture) =>
      !fixture.isCancelled &&
      !fixture.isFinal &&
      !fixture.hasPendingOperationalResolution &&
      (fixture.isLive ||
          (!fixture.scheduledStartAt.isBefore(DateTime.now()) &&
              fixture.homeScore == null &&
              fixture.awayScore == null));

  Future<_PartyNotice?> _loadParty(List<OpenQueueBooking> bookings) async {
    final repo = widget.openQueueRepository;
    if (repo is OpenQueuePartyNotificationRepository) {
      try {
        for (final notice
            in await (repo as OpenQueuePartyNotificationRepository)
                .listPartyInviteNotifications()) {
          var booking = bookings
              .where((b) => b.gameId == notice.gameId)
              .firstOrNull;
          if (booking == null && repo is OpenQueueBookingLookupRepository) {
            booking = await (repo as OpenQueueBookingLookupRepository)
                .getMyUpcomingBookingForGame(notice.gameId);
          }
          if (booking != null) {
            return _PartyNotice(booking, notice.inviter.displayName, notice.id);
          }
        }
      } catch (_) {
        /* The booking-scoped API is a rollout-safe fallback. */
      }
    }
    if (repo is OpenQueuePartyRepository) {
      for (final booking in bookings) {
        try {
          final context = await (repo as OpenQueuePartyRepository)
              .getPartyContext(booking.gameId);
          if (context.gameId == booking.gameId &&
              context.receivedInvites.isNotEmpty) {
            return _PartyNotice(
              booking,
              context.receivedInvites.first.owner.displayName,
              null,
            );
          }
        } catch (_) {
          /* Invitations must not block the rest of Home. */
        }
      }
    }
    return null;
  }

  Future<void> _openParty() async {
    final party = _party;
    if (party == null) return;
    final repo = widget.openQueueRepository;
    if (party.notificationId != null &&
        repo is OpenQueuePartyNotificationRepository) {
      try {
        await (repo as OpenQueuePartyNotificationRepository)
            .markPartyInviteNotificationRead(party.notificationId!);
      } catch (_) {}
    }
    if (mounted) await _openBooking(party.booking);
  }

  Future<void> _openBooking(OpenQueueBooking booking) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushGameDetailScreen(
          repository: widget.openQueueRepository,
          gameId: booking.gameId,
          initialGame: booking.game,
          profileRepository: widget.profileRepository,
          onNavigateTab: widget.onNavigateTab,
          onJoin: (game) async {
            await showFieldrushCheckout(
              context: context,
              repository: widget.openQueueRepository,
              game: game,
            );
          },
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openGame(
    OpenQueueGame game, [
    Set<OpenQueueRole>? roles,
  ]) async {
    if (roles == null || game.isFull) {
      await _openSoloMatch(game);
      return;
    }
    await Navigator.of(context).push<OpenQueueBooking>(
      MaterialPageRoute(
        builder: (_) => FieldrushBookingFlow(
          repository: widget.openQueueRepository,
          initialRoles: roles,
          startAtGames: true,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openSoloMatch(OpenQueueGame game) =>
      _openSoloMatchById(game.id);

  Future<void> _openSoloMatchById(String gameId) async {
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => FieldrushGameDetailScreen(
            repository: widget.openQueueRepository,
            gameId: gameId,
            profileRepository: widget.profileRepository,
            onNavigateTab: widget.onNavigateTab,
            onJoin: (game) async {
              await showFieldrushCheckout(
                context: context,
                repository: widget.openQueueRepository,
                game: game,
              );
            },
          ),
        ),
      );
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              userFacingError(
                error,
                fallback: 'Could not open this game. Try again.',
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _openFixture(Fixture fixture) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FixtureDetailScreen(
          fixture: fixture,
          fixtureRepository: widget.fixtureRepository,
          clanRepository: widget.clanRepository,
          profileRepository: widget.profileRepository,
          myClanMembership: _membership,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openNotification(HomeNotification item) async {
    try {
      final gameId = item.openQueueGameId;
      if (gameId != null) {
        final booking = _bookings
            .where((booking) => booking.gameId == gameId)
            .firstOrNull;
        if (booking != null) {
          await _openBooking(booking);
        } else {
          // Historical and cancelled games need not appear in today's feed.
          // An activity item opens match details, not a new booking checkout.
          await _openSoloMatchById(gameId);
        }
        return;
      }

      final fixtureId = item.fixtureId;
      if (fixtureId != null) {
        final fixture =
            _fixtures.where((fixture) => fixture.id == fixtureId).firstOrNull ??
            await widget.fixtureRepository.getFixture(fixtureId);
        if (mounted) await _openFixture(fixture);
        return;
      }

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('home-notification-details'),
          title: Text(item.title),
          content: SingleChildScrollView(child: SelectableText(item.body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userFacingError(
              error,
              fallback: 'Could not open this notification. Try again.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _discovery({bool search = false}) async {
    final repo = widget.discoveryRepository;
    if (repo == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HomeDiscoveryScreen(
          repository: repo,
          search: search,
          onPlayer: (id) async {
            await Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => ProfileScreen(
                  profileId: id,
                  profileRepository: widget.profileRepository,
                  clanRepository: widget.clanRepository,
                  fixtureRepository: widget.fixtureRepository,
                  openQueueRepository: widget.openQueueRepository,
                ),
              ),
            );
          },
          onNotification: _openNotification,
        ),
      ),
    );
    if (mounted) await _load();
  }

  List<_UpcomingHomeGame> get _upcoming {
    final list = <_UpcomingHomeGame>[
      for (final booking in _bookings) _UpcomingHomeGame.solo(booking),
      for (final game in _fixtureGames)
        if (game.myBookingId != null &&
            game.status.toUpperCase() == 'LIVE' &&
            !game.hasPendingOperationalResolution &&
            !_bookings.any((b) => b.gameId == game.id))
          _UpcomingHomeGame.live(game),
      for (final fixture in _fixtures)
        if (_clan != null &&
            (fixture.homeClanId == _clan!.id ||
                fixture.awayClanId == _clan!.id) &&
            _isUpcomingClan(fixture))
          _UpcomingHomeGame.clan(fixture),
    ];
    list.sort((a, b) {
      if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
      return a.startsAt.compareTo(b.startsAt);
    });
    return list;
  }

  Future<void> _openUpcoming(_UpcomingHomeGame item) {
    if (item.booking != null) return _openBooking(item.booking!);
    if (item.fixture != null) return _openFixture(item.fixture!);
    return _openSoloMatch(item.liveGame!);
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final upcoming = _upcoming;
    final first = upcoming.firstOrNull;
    final bookedIds = _bookings.map((b) => b.gameId).toSet();
    final available = _games
        .where(
          (g) =>
              !bookedIds.contains(g.id) &&
              g.myBookingId == null &&
              g.belongsToCity(_city.id, _city.timezone) &&
              !g.hasPendingOperationalResolution &&
              g.supportedRoles.any(g.canBook),
        )
        .toList();
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: ColoredBox(
        color: FieldrushAuthTheme.cream,
        child: SafeArea(
          bottom: false,
          child: FieldRefreshIndicator(
            onRefresh: _load,
            color: FieldrushAuthTheme.forest,
            child: ListView(
              key: const Key('fieldrush-home-scroll'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 132),
              children: [
                if (_loading && profile == null)
                  const _HomeLoading()
                else if (profile == null)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Text(_error ?? 'Could not load Home.'),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  )
                else ...[
                  FieldrushHomeHeader(
                    profile: profile,
                    rating: _rating,
                    ratingUnavailable: _rating == null,
                    onProfile: widget.onOpenProfile,
                    onSearch: () => _discovery(search: true),
                    onActivity: _discovery,
                    hasUnread:
                        _party != null ||
                        _notifications.any((n) => n.readAt == null),
                  ),
                  if (first?.booking != null)
                    FieldrushSoloHero(
                      booking: first!.booking!,
                      onTap: () => _openUpcoming(first),
                    )
                  else if (first?.fixture != null)
                    _clanCard(first!)
                  else if (first?.liveGame != null)
                    _liveCard(first!)
                  else ...[
                    FieldrushQuickGameCard(
                      games: available,
                      onPlay: (game, roles) => _openGame(game, roles),
                    ),
                    FieldrushOpenNights(games: available, onGame: _openGame),
                  ],
                  for (final item in upcoming.skip(1).take(2))
                    FieldrushAlsoBooked(
                      key: ValueKey('home-also-booked-${item.id}'),
                      title: item.label,
                      startsAt: item.startsAt,
                      gameTimezone:
                          item.booking?.game.timezone ??
                          item.liveGame?.timezone ??
                          'Asia/Bahrain',
                      onTap: () => _openUpcoming(item),
                    ),
                  if (_rating == null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: _noticeCard(
                        key: const Key('home-rating-unavailable'),
                        title: 'Rating unavailable',
                        body: 'Your current-season rating could not be loaded.',
                        action: 'Try again',
                        onTap: _load,
                      ),
                    )
                  else
                    FieldrushHomeRating(
                      profile: profile,
                      rating: _rating,
                      ratings: _ratings,
                      track: _ratingTrack,
                      onTrack: _ratings == null ? null : _chooseRatingTrack,
                      season: _season,
                      onTap: widget.onOpenRanks,
                    ),
                  if (_party case final party?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: _noticeCard(
                        key: ValueKey(
                          'home-party-invite-${party.booking.gameId}',
                        ),
                        title: '${party.inviter} invited you to a party',
                        body:
                            'Your booked game · ${party.booking.game.startTimeLabel}',
                        action: 'View invitation',
                        onTap: _openParty,
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: FieldrushAuthTheme.danger,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _clanCard(_UpcomingHomeGame item) {
    final fixture = item.fixture!;
    final roster = _rosters[fixture.id];
    final selected =
        roster?.selectedMembers.any((m) => m.profileId == _profile?.id) ??
        false;
    return FieldrushClanHero(
      key: ValueKey('home-clan-game-${fixture.id}'),
      fixture: fixture,
      clan: _clan!,
      selectedCount: roster?.confirmedCount,
      isSelected: selected,
      onTap: () => _openFixture(fixture),
    );
  }

  Widget _liveCard(_UpcomingHomeGame item) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
    child: _noticeCard(
      key: ValueKey('home-live-game-${item.id}'),
      title: 'Your game is live',
      body:
          '${item.liveGame!.venue} · ${item.liveGame!.whiteScore ?? 0} – ${item.liveGame!.blackScore ?? 0}',
      action: 'Match details',
      onTap: () => _openUpcoming(item),
      green: true,
    ),
  );

  Widget _noticeCard({
    Key? key,
    required String title,
    required String body,
    required String action,
    required VoidCallback onTap,
    bool green = false,
  }) => Container(
    key: key,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: green ? FieldrushAuthTheme.forest : Colors.white,
      borderRadius: BorderRadius.circular(22),
      border: green ? null : Border.all(color: FieldrushAuthTheme.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: 'Outfit',
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: green ? Colors.white : FieldrushAuthTheme.ink,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: green ? const Color(0xFFE4F0D5) : FieldrushAuthTheme.muted,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            backgroundColor: green ? Colors.white : FieldrushAuthTheme.forest,
            foregroundColor: green ? FieldrushAuthTheme.forest : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            minimumSize: const Size.fromHeight(50),
          ),
          child: Text(
            action,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    ),
  );
}

class _HomeLoading extends StatelessWidget {
  const _HomeLoading();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading Home',
    liveRegion: true,
    child: const ExcludeSemantics(
      child: Padding(
        key: ValueKey('home-loading-skeleton'),
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                FieldSkeleton(width: 48, height: 48, radius: 24),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FieldSkeleton(width: 92, height: 12),
                      SizedBox(height: 9),
                      FieldSkeleton(width: 158, height: 24),
                    ],
                  ),
                ),
                FieldSkeleton(width: 36, height: 36, radius: 18),
              ],
            ),
            SizedBox(height: 28),
            FieldSkeleton(height: 218, radius: 24),
            SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: FieldSkeleton(width: 140, height: 16),
            ),
            SizedBox(height: 14),
            FieldSkeleton(height: 148, radius: 24),
            SizedBox(height: 16),
            FieldSkeleton(height: 112, radius: 24),
          ],
        ),
      ),
    ),
  );
}

class _PartyNotice {
  const _PartyNotice(this.booking, this.inviter, this.notificationId);
  final OpenQueueBooking booking;
  final String inviter;
  final String? notificationId;
}

class _UpcomingHomeGame {
  _UpcomingHomeGame.solo(OpenQueueBooking value)
    : booking = value,
      fixture = null,
      liveGame = null;
  _UpcomingHomeGame.clan(Fixture value)
    : booking = null,
      fixture = value,
      liveGame = null;
  _UpcomingHomeGame.live(OpenQueueGame value)
    : booking = null,
      fixture = null,
      liveGame = value;
  final OpenQueueBooking? booking;
  final Fixture? fixture;
  final OpenQueueGame? liveGame;
  String get id => booking?.gameId ?? fixture?.id ?? liveGame!.id;
  DateTime get startsAt =>
      booking?.game.startsAt ?? fixture?.scheduledStartAt ?? liveGame!.startsAt;
  bool get isLive =>
      fixture?.isLive ??
      (liveGame != null || booking?.game.status.toUpperCase() == 'LIVE');
  String get label => fixture == null
      ? 'Solo game'
      : '${fixture!.homeClan.name} vs ${fixture!.awayClan?.name ?? 'Opponent TBC'}';
}
