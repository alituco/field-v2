import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import '../ui/fieldrush_toast.dart';

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
import '../profile/fieldrush_payment_history_screen.dart';
import '../reliability/reliability_repository.dart';
import '../reliability/reliability_status_card.dart';
import '../ranking/fieldrush_divisions_screen.dart';
import 'fieldrush_home_widgets.dart';
import 'activity_revision.dart';
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

class _DashboardHomeState extends State<DashboardHome>
    with WidgetsBindingObserver {
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
  int _bookingsReadGeneration = 0;
  int _fixturesReadGeneration = 0;
  int _ratingsReadGeneration = 0;
  int _gameReadVersion = 0;
  int _bookingsSnapshotVersion = 0;
  int _fixturesSnapshotVersion = 0;
  bool _activityOpen = false;
  final Set<String> _openingPhoneNotificationIds = {};
  StreamSubscription<void>? _partySubscription;
  Timer? _gameRefreshTimer;
  bool _refreshingCurrentGame = false;
  int _idleRefreshTicks = 0;
  FieldrushCity _city = FieldrushCity.phoenix;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ratingTrack = widget.ratingTrackController?.value ?? RatingTrack.outfield;
    widget.ratingTrackController?.addListener(_syncRatingTrack);
    fieldrushCityRevision.addListener(_load);
    fieldrushActivityRevision.addListener(_load);
    fieldrushActivityOpenRequested.addListener(_openRequestedActivity);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _openRequestedActivity(),
    );
    _load();
    _gameRefreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_canRefreshCurrentGame) return;
      final active =
          _bookings.isNotEmpty ||
          _fixtureGames.any(
            (game) => game.hasMyBooking && game.isActiveReservation,
          );
      // Keep completed/reopened matches and SR current too, without polling
      // an idle Home as frequently as a player's active game.
      if (active || ++_idleRefreshTicks >= 3) {
        _idleRefreshTicks = 0;
        unawaited(_refreshCurrentGame());
      }
    });
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
    WidgetsBinding.instance.removeObserver(this);
    widget.ratingTrackController?.removeListener(_syncRatingTrack);
    fieldrushActivityRevision.removeListener(_load);
    fieldrushActivityOpenRequested.removeListener(_openRequestedActivity);
    _partySubscription?.cancel();
    _gameRefreshTimer?.cancel();
    fieldrushCityRevision.removeListener(_load);
    super.dispose();
  }

  bool get _canRefreshCurrentGame {
    if (!mounted ||
        !TickerMode.valuesOf(context).enabled ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return false;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _canRefreshCurrentGame) {
      _idleRefreshTicks = 0;
      unawaited(_refreshCurrentGame());
    }
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

  void _openDivisions() {
    final navigator = Navigator.of(context);
    navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushDivisionsScreen(
          rating: _ratings?.forTrack(_ratingTrack) ?? _rating,
          prediction: _ratings?.predictionFor(_ratingTrack),
          track: _ratingTrack,
          season: _season,
          cityName: _ratings?.primaryCityName ?? _rating?.region,
          onOpenRanks: () {
            navigator.pop();
            widget.onOpenRanks();
          },
          onNavigateTab: (index) {
            navigator.pop();
            widget.onNavigateTab(index);
          },
        ),
      ),
    );
  }

  List<OpenQueueBooking> _activeBookings(List<OpenQueueBooking> rows) =>
      rows
          .where(
            (booking) =>
                booking.status.toUpperCase() == 'CONFIRMED' &&
                booking.game.isActiveReservation,
          )
          .toList()
        ..sort((a, b) {
          final at = DateTime.now();
          final aBlocks = a.game.blocksNewBookingAt(at);
          final bBlocks = b.game.blocksNewBookingAt(at);
          if (aBlocks != bBlocks) return aBlocks ? -1 : 1;
          return a.game.startsAt.compareTo(b.game.startsAt);
        });

  Future<void> _refreshCurrentGame() async {
    if (_refreshingCurrentGame || !_canRefreshCurrentGame) {
      return;
    }
    _refreshingCurrentGame = true;
    final version = _loadVersion;
    final bookingsGeneration = ++_bookingsReadGeneration;
    final fixturesGeneration = ++_fixturesReadGeneration;
    final ratingsGeneration = ++_ratingsReadGeneration;
    final gameVersion = ++_gameReadVersion;
    bool current() => mounted && version == _loadVersion;
    Future<void> section(Future<void> Function() read) async {
      try {
        await read();
      } catch (_) {
        // Preserve usable content during a transient failure. Pull-to-refresh
        // exposes errors; automatic refreshes retry without interrupting play.
      }
    }

    try {
      await Future.wait<void>([
        section(() async {
          final rows = await widget.openQueueRepository
              .getMyUpcomingBookings()
              .timeout(const Duration(seconds: 12));
          if (current() && bookingsGeneration == _bookingsReadGeneration) {
            setState(() {
              _bookings = _activeBookings(rows);
              _bookingsSnapshotVersion = gameVersion;
            });
          }
        }),
        section(() async {
          final games = await widget.openQueueRepository
              .listFixtureGames()
              .timeout(const Duration(seconds: 12));
          if (current() && fixturesGeneration == _fixturesReadGeneration) {
            setState(() {
              _fixtureGames = games;
              _fixturesSnapshotVersion = gameVersion;
            });
          }
        }),
        section(
          () => _loadRatings(
            () => current() && ratingsGeneration == _ratingsReadGeneration,
          ),
        ),
      ]);
    } finally {
      _refreshingCurrentGame = false;
    }
  }

  Future<void> _loadRatings(bool Function() current) async {
    const timeout = Duration(seconds: 12);
    final season = await loadActiveLeaderboardSeason(
      widget.leaderboardRepository,
    ).timeout(timeout);
    if (!current()) return;
    setState(() {
      if (_season?.id != season.id) {
        _ratings = null;
        _rating = null;
      }
      _season = season;
    });
    final repository = widget.leaderboardRepository;
    if (repository is TrackLeaderboardRepository) {
      final ratings = await (repository as TrackLeaderboardRepository)
          .loadPlayerRatings(season: season)
          .timeout(timeout);
      if (current()) {
        setState(() {
          _ratings = ratings;
          _rating = ratings.forTrack(_ratingTrack);
        });
      }
    } else {
      final rating = await repository
          .loadCurrentPlayerRating(season)
          .timeout(timeout);
      if (current()) {
        setState(() {
          _ratings = null;
          _rating = rating;
        });
      }
    }
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    final bookingGeneration = ++_bookingsReadGeneration;
    final fixturesGeneration = ++_fixturesReadGeneration;
    final ratingsGeneration = ++_ratingsReadGeneration;
    final gameVersion = ++_gameReadVersion;
    final navigationProfile = FieldNavigationProfileScope.beginRead(context);
    setState(() {
      // Keep a valid feed visible while refreshing it in the background.
      _loading = _profile == null;
      _error = null;
    });
    const coreTimeout = Duration(seconds: 30);
    const extraTimeout = Duration(seconds: 12);
    bool current() => mounted && version == _loadVersion;
    bool bookingsCurrent() =>
        current() && bookingGeneration == _bookingsReadGeneration;
    void publish(VoidCallback change) {
      if (current()) setState(change);
    }

    final failures = <String>{};
    void failed(String label) {
      if (!current()) return;
      failures.add(label);
      setState(() {
        _error =
            'Could not refresh ${failures.join(', ')}. Pull down to try again.';
      });
    }

    Future<void> section(
      String label,
      Future<void> Function() read, {
      bool Function()? stillCurrent,
    }) async {
      try {
        await read();
      } catch (_) {
        if (stillCurrent?.call() ?? true) failed(label);
      }
    }

    // A pending season, city, clip/history or discovery read must not hold
    // already-booked games and actionable party invitations behind a skeleton.
    final Future<List<OpenQueueBooking>?> bookingsRead = () async {
      try {
        final rows = await widget.openQueueRepository
            .getMyUpcomingBookings()
            .timeout(coreTimeout);
        final bookings = _activeBookings(rows);
        if (!bookingsCurrent()) return null;
        publish(() {
          _bookings = bookings;
          _bookingsSnapshotVersion = gameVersion;
        });
        return bookings;
      } catch (_) {
        if (!bookingsCurrent()) return null;
        failed('bookings');
        return _bookings;
      }
    }();
    final openQueue = widget.openQueueRepository;
    await Future.wait<void>([
      () async {
        try {
          final repository = widget.profileRepository;
          final profile =
              await (repository is ProfileSummaryRepository
                      ? (repository as ProfileSummaryRepository)
                            .getCurrentProfileSummary()
                      : repository.getCurrentProfile())
                  .timeout(coreTimeout);
          if (!current()) return;
          navigationProfile?.complete(profile);
          setState(() {
            _profile = profile;
            _loading = false;
          });
        } catch (_) {
          failed('your profile');
          publish(() => _loading = false);
        }
      }(),
      section('party invitations', () async {
        final bookings = await bookingsRead;
        if (bookings == null || !bookingsCurrent()) return;
        try {
          final party = await _loadParty(bookings).timeout(extraTimeout);
          if (bookingsCurrent()) publish(() => _party = party);
        } catch (_) {
          if (bookingsCurrent()) rethrow;
        }
      }),
      section(
        'rating',
        () => _loadRatings(
          () => current() && ratingsGeneration == _ratingsReadGeneration,
        ),
        stillCurrent: () => ratingsGeneration == _ratingsReadGeneration,
      ),
      section('available games', () async {
        final cityRepository =
            widget.cityRepository ??
            (openQueue is SupabaseOpenQueueRepository
                ? SupabaseFieldrushCityRepository()
                : null);
        final city = cityRepository == null
            ? FieldrushCity.phoenix
            : await cityRepository.loadPreferredCity().timeout(extraTimeout);
        if (!current()) return;
        final games =
            await (openQueue is OpenQueueCityRepository
                    ? (openQueue as OpenQueueCityRepository).listCityGames(
                        city.id,
                      )
                    : openQueue is OpenQueueMarketRepository
                    ? (openQueue as OpenQueueMarketRepository).listMarketGames(
                        city.timezone,
                      )
                    : openQueue.listGames())
                .timeout(extraTimeout);
        publish(() {
          _city = city;
          _games = games;
        });
      }),
      section(
        'live games',
        () async {
          final games = await openQueue.listFixtureGames().timeout(
            extraTimeout,
          );
          if (fixturesGeneration == _fixturesReadGeneration) {
            publish(() {
              _fixtureGames = games;
              _fixturesSnapshotVersion = gameVersion;
            });
          }
        },
        stillCurrent: () => fixturesGeneration == _fixturesReadGeneration,
      ),
      section('clan games', () async {
        final data = await Future.wait<Object?>([
          widget.clanRepository.listClans(),
          widget.clanRepository.getMyClanMembership(),
          widget.fixtureRepository.getMyClanMembership(),
          widget.fixtureRepository.listFixtures(),
        ]).timeout(extraTimeout);
        if (!current()) return;
        final clans = data[0] as List<Clan>;
        final membership = data[1] as ClanMembership?;
        final fixtures = data[3] as List<Fixture>;
        final clan = clans.where((c) => c.id == membership?.clanId).firstOrNull;
        publish(() {
          _clan = clan;
          _membership = data[2] as MyClanMembership?;
          _fixtures = fixtures;
          _rosters.clear();
        });
        final repository = widget.fixtureRepository;
        if (clan == null || repository is! FixtureReliabilityRosterRepository) {
          return;
        }
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
            section('clan roster', () async {
              final roster =
                  await (repository as FixtureReliabilityRosterRepository)
                      .getMyFixtureReliabilityRoster(fixture.id)
                      .timeout(extraTimeout);
              publish(() => _rosters[fixture.id] = roster);
            }),
        ]);
      }),
      if (widget.discoveryRepository != null)
        section('activity', () async {
          final notifications = await widget.discoveryRepository!
              .notifications()
              .timeout(extraTimeout);
          publish(() => _notifications = notifications);
        }),
    ]);
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
    Object? lastError;
    var authoritativeReadSucceeded = false;
    var fallbackReadCount = 0;
    var fallbackReadFailed = false;
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
          if (booking != null && booking.game.blocksNewBooking) {
            return _PartyNotice(booking, notice.inviter.displayName, notice.id);
          }
        }
        authoritativeReadSucceeded = true;
      } catch (error) {
        lastError = error;
        /* The booking-scoped API is a rollout-safe fallback. */
      }
    }
    if (repo is OpenQueuePartyRepository) {
      for (final booking in bookings) {
        if (!booking.game.blocksNewBooking) continue;
        try {
          final context = await (repo as OpenQueuePartyRepository)
              .getPartyContext(booking.gameId);
          fallbackReadCount++;
          if (context.gameId == booking.gameId &&
              context.receivedInvites.isNotEmpty) {
            return _PartyNotice(
              booking,
              context.receivedInvites.first.owner.displayName,
              null,
            );
          }
        } catch (error) {
          lastError = error;
          fallbackReadFailed = true;
          /* Invitations must not block the rest of Home. */
        }
      }
    }
    if (!authoritativeReadSucceeded &&
        lastError != null &&
        (fallbackReadCount == 0 || fallbackReadFailed)) {
      throw lastError;
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

  Future<void> _openBooking(
    OpenQueueBooking booking, {
    bool focusLineup = false,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushGameDetailScreen(
          repository: widget.openQueueRepository,
          gameId: booking.gameId,
          initialGame: booking.game,
          initiallyFocusLineup: focusLineup,
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
        showFieldrushToast(
          context,
          userFacingError(
            error,
            fallback: 'Could not open this game. Try again.',
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
      if (item.opensPaymentHistory) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => const FieldrushPaymentHistoryScreen(),
          ),
        );
        return;
      }
      if (item.opensReliability) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => Theme(
              data: FieldrushAuthTheme.theme(context),
              child: Scaffold(
                backgroundColor: FieldrushAuthTheme.cream,
                appBar: AppBar(title: const Text('Reliability')),
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    ReliabilityStatusCard(
                      repository: SupabaseReliabilityRepository(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        return;
      }
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
      await showFieldrushModal<void>(
        context: context,
        builder: (context) => FieldrushModal(
          key: const Key('home-notification-details'),
          title: item.title,
          content: SelectableText(item.body, style: FieldrushModal.bodyStyle),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'Could not open this notification. Try again.',
        ),
      );
    }
  }

  void _openRequestedActivity() {
    if (!mounted || !fieldrushActivityOpenRequested.value) return;
    final request = fieldrushNotificationOpenRequest;
    clearFieldrushActivityOpenRequest();
    if (request != null) {
      unawaited(_openPhoneNotification(request));
      return;
    }
    if (!_activityOpen) unawaited(_discovery());
  }

  Future<void> _openPhoneNotification(
    FieldrushNotificationOpenRequest request,
  ) async {
    if (_openingPhoneNotificationIds.contains(request.notificationId)) return;
    final repository = widget.discoveryRepository;
    if (repository is! HomeNotificationLookupRepository) {
      if (!_activityOpen) await _discovery();
      return;
    }
    final lookup = repository as HomeNotificationLookupRepository;
    if (lookup.signedInProfileId != request.userId) return;
    _openingPhoneNotificationIds.add(request.notificationId);
    try {
      final item = await lookup
          .notificationById(request.notificationId)
          .timeout(const Duration(seconds: 8));
      if (!mounted || lookup.signedInProfileId != request.userId) return;
      if (item == null) {
        if (!_activityOpen) await _discovery();
        return;
      }
      // Read receipts are best effort; a network hiccup must not prevent the
      // player opening an already authenticated canonical notification.
      unawaited(
        repository!
            .markRead(item.id)
            .timeout(const Duration(seconds: 8))
            .catchError((Object _) {}),
      );
      notifyFieldrushActivityChanged();
      await _openNotification(item);
    } catch (_) {
      if (mounted &&
          lookup.signedInProfileId == request.userId &&
          !_activityOpen) {
        await _discovery();
      }
    } finally {
      _openingPhoneNotificationIds.remove(request.notificationId);
    }
  }

  Future<void> _discovery({bool search = false}) async {
    final repo = widget.discoveryRepository;
    if (repo == null || (!search && _activityOpen)) return;
    if (!search) _activityOpen = true;
    try {
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
    } finally {
      if (!search) _activityOpen = false;
    }
    if (mounted) await _load();
  }

  List<_UpcomingHomeGame> get _upcoming {
    // A successful current fixture read can update a cached booking even when
    // the supplemental booking request stalls. Older feeds cannot undo a newer
    // reservation or a newly reopened game.
    final currentGames = _fixturesSnapshotVersion > _bookingsSnapshotVersion
        ? {for (final game in _fixtureGames) game.id: game}
        : <String, OpenQueueGame>{};
    final bookings = _activeBookings([
      for (final booking in _bookings)
        booking.copyWith(
          game:
              booking.game.status == 'LIVE' &&
                  const [
                    'OPEN',
                    'FULL',
                  ].contains(currentGames[booking.gameId]?.status)
              ? null
              : currentGames[booking.gameId],
        ),
    ]);
    final list = <_UpcomingHomeGame>[
      for (final booking in bookings)
        if (booking.game.status == 'LIVE' ||
            booking.game.hasPendingOperationalResolution)
          _UpcomingHomeGame.live(booking.game)
        else
          _UpcomingHomeGame.solo(booking),
      if (_fixturesSnapshotVersion > _bookingsSnapshotVersion)
        for (final game in _fixtureGames)
          if (game.myBookingId != null &&
              (game.status.toUpperCase() == 'LIVE' ||
                  game.hasPendingOperationalResolution) &&
              !bookings.any((b) => b.gameId == game.id))
            _UpcomingHomeGame.live(game),
      for (final fixture in _fixtures)
        if (_clan != null &&
            (fixture.homeClanId == _clan!.id ||
                fixture.awayClanId == _clan!.id) &&
            _isUpcomingClan(fixture))
          _UpcomingHomeGame.clan(fixture),
    ];
    list.sort((a, b) {
      if (a.blocksNewBooking != b.blocksNewBooking) {
        return a.blocksNewBooking ? -1 : 1;
      }
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
                      onSeeTeam: () =>
                          _openBooking(first.booking!, focusLineup: true),
                      onAssignmentDue: () => unawaited(_refreshCurrentGame()),
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
                      startsAt:
                          item.booking?.game.displayStartsAt ?? item.startsAt,
                      isCheckIn: item.booking?.game.isUpcoming ?? false,
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
                      onTap: _openDivisions,
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
                            'Your booked game · ${party.booking.game.isUpcoming ? 'Check-in ' : ''}${party.booking.game.displayTimeLabel}',
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
      title: item.liveGame!.hasPendingOperationalResolution
          ? item.liveGame!.operationalStatusLabel ?? 'Match under review'
          : item.blocksNewBooking
          ? 'Your game is live'
          : 'Awaiting match result',
      body: !item.blocksNewBooking
          ? '${item.liveGame!.venue} · You can book another game while this match is being resolved.'
          : '${item.liveGame!.venue} · ${item.liveGame!.whiteScore ?? 0} – ${item.liveGame!.blackScore ?? 0}',
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
      ((liveGame ?? booking?.game)?.status.toUpperCase() == 'LIVE' &&
          !(liveGame ?? booking?.game)!.hasPendingOperationalResolution &&
          blocksNewBooking);
  bool get blocksNewBooking =>
      fixture != null || (liveGame ?? booking?.game)!.blocksNewBooking;
  String get label => fixture == null
      ? !(liveGame ?? booking?.game)!.blocksNewBooking
            ? 'Solo game · ${(liveGame ?? booking?.game)!.operationalStatusLabel ?? 'Awaiting result'}'
            : 'Solo game'
      : '${fixture!.homeClan.name} vs ${fixture!.awayClan?.name ?? 'Opponent TBC'}';
}
