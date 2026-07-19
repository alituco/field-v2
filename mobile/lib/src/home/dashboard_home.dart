import 'dart:async';

import 'package:flutter/material.dart';

import '../clans/clan.dart';
import '../clans/clan_detail_screen.dart';
import '../clans/clan_repository.dart';
import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_detail_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../fixtures/fixtures_screen.dart';
import '../leaderboard/leaderboard.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../open_queue/open_queue.dart';
import '../open_queue/open_queue_booking_screen.dart';
import '../open_queue/open_queue_kit_indicator.dart';
import '../open_queue/open_queue_party_repository.dart';
import '../open_queue/open_queue_repository.dart';
import '../open_queue/open_queue_review_screen.dart';
import '../open_queue/open_queue_screen.dart';
import '../profile/profile.dart';
import '../profile/profile_repository.dart';

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
  });

  final int activationTick;
  final ProfileRepository profileRepository;
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final LeaderboardRepository leaderboardRepository;
  final OpenQueueRepository openQueueRepository;
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
  LeaderboardSeason _ratingSeason = activeLeaderboardSeason;
  List<OpenQueueBooking> _bookings = const [];
  OpenQueueBooking? _partyInviteBooking;
  _HomePartyInviteNotice? _partyInviteNotice;
  int _openQueuePlayerCount = 0;
  List<Clan> _clans = const [];
  Clan? _myClan;
  ClanMembership? _clanMembership;
  MyClanMembership? _fixtureMembership;
  List<Fixture> _fixtures = const [];
  List<OpenQueueGame> _soloFixtureGames = const [];
  Map<String, OpenQueueMatchDetail> _recentSoloDetails = const {};
  bool _loading = true;
  String? _error;
  StreamSubscription<void>? _partyNotificationSubscription;
  Timer? _partyNotificationReloadDebounce;

  OpenQueueBooking? get _booking => _bookings.isEmpty ? null : _bookings.first;

  @override
  void initState() {
    super.initState();
    _watchPartyNotifications();
    _load();
  }

  @override
  void didUpdateWidget(covariant DashboardHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activationTick != widget.activationTick) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _partyNotificationReloadDebounce?.cancel();
    unawaited(_partyNotificationSubscription?.cancel());
    super.dispose();
  }

  void _watchPartyNotifications() {
    final repository = widget.openQueueRepository;
    if (repository is! OpenQueuePartyNotificationRepository) return;
    final notificationRepository =
        repository as OpenQueuePartyNotificationRepository;
    _partyNotificationSubscription = notificationRepository
        .watchPartyInviteNotifications()
        .listen(
          (_) {
            _partyNotificationReloadDebounce?.cancel();
            _partyNotificationReloadDebounce = Timer(
              const Duration(milliseconds: 250),
              () {
                if (mounted) unawaited(_load());
              },
            );
          },
          onError: (_) {
            // Realtime is supplemental. Pull-to-refresh and navigation
            // reloads still surface every persisted invitation.
          },
        );
  }

  Future<void> _load() async {
    final ratingSeason = activeLeaderboardSeason;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<dynamic>([
        widget.profileRepository.getCurrentProfile(),
        widget.leaderboardRepository.loadCurrentPlayerRating(ratingSeason),
        widget.openQueueRepository.getMyUpcomingBookings(),
        widget.openQueueRepository.listGames(),
        widget.clanRepository.listClans(),
        widget.clanRepository.getMyClanMembership(),
        widget.fixtureRepository.getMyClanMembership(),
        widget.fixtureRepository.listFixtures(),
        widget.openQueueRepository.listFixtureGames(),
      ]);
      if (!mounted) return;
      final profile = results[0] as PlayerProfile;
      final rating = results[1] as PlayerRatingLeaderboardEntry;
      final bookings =
          (results[2] as List<OpenQueueBooking>).toList(growable: false)..sort(
            (left, right) => left.game.startsAt.compareTo(right.game.startsAt),
          );
      final booking = bookings.isEmpty ? null : bookings.first;
      final games = results[3] as List<OpenQueueGame>;
      final clans = results[4] as List<Clan>;
      final membership = results[5] as ClanMembership?;
      final soloFixtureGames = results[8] as List<OpenQueueGame>;
      final soloFixtureIds = {for (final game in soloFixtureGames) game.id};
      final recentSoloGames =
          profile.previousGames
              .where((game) => game.isSolo && soloFixtureIds.contains(game.id))
              .toList()
            ..sort((left, right) => right.playedAt.compareTo(left.playedAt));
      final recentSoloIds = recentSoloGames
          .map((game) => game.id)
          .toSet()
          .take(2);
      final partyInviteFuture = _loadPartyInvite(booking);
      final detailEntries =
          await Future.wait<MapEntry<String, OpenQueueMatchDetail>?>([
            for (final gameId in recentSoloIds)
              () async {
                try {
                  final detail = await widget.openQueueRepository
                      .getMatchDetail(gameId);
                  return MapEntry(gameId, detail);
                } catch (_) {
                  return null;
                }
              }(),
          ]);
      final partyInvite = await partyInviteFuture;
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _rating = rating;
        _ratingSeason = ratingSeason;
        _bookings = bookings;
        _partyInviteBooking = partyInvite.booking;
        _partyInviteNotice = partyInvite.notice;
        _openQueuePlayerCount = games.fold<int>(
          0,
          (total, game) => total + game.confirmedCount,
        );
        _clans = clans;
        _clanMembership = membership;
        _fixtureMembership = results[6] as MyClanMembership?;
        _myClan = membership == null
            ? null
            : clans.cast<Clan?>().firstWhere(
                (clan) => clan?.id == membership.clanId,
                orElse: () => null,
              );
        _fixtures = results[7] as List<Fixture>;
        _soloFixtureGames = soloFixtureGames;
        _recentSoloDetails = {
          for (final entry in detailEntries)
            if (entry != null) entry.key: entry.value,
        };
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(
          error,
          fallback: 'We could not load your home feed.',
        );
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<_HomePartyInviteLoad> _loadPartyInvite(
    OpenQueueBooking? booking,
  ) async {
    final repository = widget.openQueueRepository;
    final notificationRepository =
        repository is OpenQueuePartyNotificationRepository
        ? repository as OpenQueuePartyNotificationRepository
        : null;
    if (notificationRepository != null) {
      try {
        final notifications = await notificationRepository
            .listPartyInviteNotifications();
        if (notifications.isNotEmpty) {
          final notification = notifications.first;
          OpenQueueBooking? inviteBooking =
              booking?.gameId == notification.gameId ? booking : null;
          final bookingLookup = repository is OpenQueueBookingLookupRepository
              ? repository as OpenQueueBookingLookupRepository
              : null;
          if (inviteBooking == null && bookingLookup != null) {
            inviteBooking = await bookingLookup.getMyUpcomingBookingForGame(
              notification.gameId,
            );
          }
          if (inviteBooking != null) {
            return _HomePartyInviteLoad(
              booking: inviteBooking,
              notice: _HomePartyInviteNotice(
                gameId: notification.gameId,
                notificationId: notification.id,
                inviterName: notification.inviter.displayName,
                dateLabel: inviteBooking.game.prominentDateLabel,
                timeLabel: inviteBooking.game.startTimeLabel,
              ),
            );
          }
        }
      } catch (_) {
        // Older local databases may not have the notification RPC yet. The
        // booking-scoped party context below remains a safe compatibility
        // fallback during migration rollout.
      }
    }
    if (booking == null) return const _HomePartyInviteLoad();
    final partyRepository = repository is OpenQueuePartyRepository
        ? repository as OpenQueuePartyRepository
        : null;
    if (partyRepository == null) return const _HomePartyInviteLoad();
    try {
      final context = await partyRepository.getPartyContext(booking.gameId);
      if (context.gameId != booking.gameId || context.receivedInvites.isEmpty) {
        return const _HomePartyInviteLoad();
      }
      final invite = context.receivedInvites.first;
      return _HomePartyInviteLoad(
        booking: booking,
        notice: _HomePartyInviteNotice(
          gameId: booking.gameId,
          inviterName: invite.owner.displayName,
          dateLabel: booking.game.prominentDateLabel,
          timeLabel: booking.game.startTimeLabel,
        ),
      );
    } catch (_) {
      // Party alerts are supplemental; a temporary alert failure must never
      // prevent the player's booking and Home feed from loading.
      return const _HomePartyInviteLoad();
    }
  }

  Future<void> _openQueue() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OpenQueueScreen(
          repository: widget.openQueueRepository,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openBooking(OpenQueueBooking booking) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OpenQueueBookingScreen(
          repository: widget.openQueueRepository,
          booking: booking,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openPartyInvite() async {
    final booking = _partyInviteBooking ?? _booking;
    if (booking == null) return;
    final notice = _partyInviteNotice;
    final repository = widget.openQueueRepository;
    final notificationRepository =
        repository is OpenQueuePartyNotificationRepository
        ? repository as OpenQueuePartyNotificationRepository
        : null;
    final notificationId = notice?.notificationId;
    if (notificationId != null && notificationRepository != null) {
      try {
        await notificationRepository.markPartyInviteNotificationRead(
          notificationId,
        );
      } catch (_) {
        // Reading the invite must not be blocked by a notification receipt.
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OpenQueueBookingScreen(
          repository: widget.openQueueRepository,
          booking: booking,
          onNavigateTab: widget.onNavigateTab,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openClan() async {
    final clan = _myClan;
    if (clan == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ClanDetailScreen(
          clan: clan,
          clanRepository: widget.clanRepository,
          fixtureRepository: widget.fixtureRepository,
          currentMembership: _clanMembership,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openFixture(
    Fixture fixture, {
    bool initiallyShowWatch = false,
    FixturePlayerRatingUpdate? playerRatingUpdate,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FixtureDetailScreen(
          fixture: fixture,
          fixtureRepository: widget.fixtureRepository,
          clanRepository: widget.clanRepository,
          myClanMembership: _fixtureMembership,
          initiallyShowWatch: initiallyShowWatch,
          playerRatingUpdate: playerRatingUpdate,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openSoloGame(OpenQueueGame game) async {
    final status = game.status.toUpperCase();
    if (status == 'FULL' ||
        status == 'LIVE' ||
        status == 'FINAL' ||
        game.isFull) {
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

  Future<void> _openSoloMatchDetail(
    OpenQueueGame game, {
    bool initiallyShowWatch = false,
    FixturePlayerRatingUpdate? playerRatingUpdate,
  }) async {
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
            initiallyShowWatch: initiallyShowWatch,
            playerRatingUpdate: playerRatingUpdate ?? detail.viewerRatingUpdate,
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

  Future<void> _openActivity(_HomeActivityItem item) {
    final ratingUpdate = item.fixturePlayerRatingUpdate;
    final fixture = item.fixture;
    if (fixture != null) {
      return _openFixture(
        fixture,
        initiallyShowWatch: item.shouldOpenWatch,
        playerRatingUpdate: ratingUpdate,
      );
    }
    if (item.canJoinSolo) return _openSoloGame(item.soloGame!);
    return _openSoloMatchDetail(
      item.soloGame!,
      initiallyShowWatch: item.shouldOpenWatch,
      playerRatingUpdate: ratingUpdate,
    );
  }

  _HomeMatchdayFeed get _matchdayFeed {
    final profile = _profile;
    final previousById = <String, ProfilePreviousGame>{
      for (final game
          in profile?.previousGames ?? const <ProfilePreviousGame>[])
        game.id: game,
    };
    final ratingById = <String, ProfileRatingEvent>{
      for (final event
          in profile?.playerRating?.events ?? const <ProfileRatingEvent>[])
        event.sourceId: event,
    };
    final myClanId = _myClan?.id;
    final items = <_HomeActivityItem>[
      for (final fixture in _fixtures)
        if (!fixture.isCancelled)
          _HomeActivityItem.clan(
            fixture,
            previousGame: previousById[fixture.id],
            ratingEvent: ratingById[fixture.id],
            isMyClanMatch:
                myClanId != null &&
                (fixture.homeClanId == myClanId ||
                    fixture.awayClanId == myClanId),
          ),
      for (final game in _soloFixtureGames)
        if (game.status.toUpperCase() != 'CANCELLED')
          _HomeActivityItem.solo(
            game,
            previousGame: previousById[game.id],
            ratingEvent: ratingById[game.id],
            detail: _recentSoloDetails[game.id],
          ),
    ];

    final bookingGameIds = _bookings.map((booking) => booking.gameId).toSet();
    final featuredClanFixtureId = _nextClanFixture?.id;
    final upNext = items.where((item) {
      if (bookingGameIds.contains(item.id) ||
          (item.fixture != null && item.id == featuredClanFixtureId) ||
          item.isCompleted ||
          item.isCancelled) {
        return false;
      }
      if (item.isLive) {
        return _sameCalendarDate(item.matchDate, _bahrainTodayDate()) &&
            item.isRelevantLive;
      }
      if (item.matchDate.isBefore(_bahrainTodayDate())) return false;
      return item.isUpcomingForViewer;
    }).toList()..sort(_compareUpcomingActivity);

    final recent =
        items
            .where(
              (item) => !bookingGameIds.contains(item.id) && item.isCompleted,
            )
            .toList()
          ..sort(_compareRecentActivity);
    return _limitMatchdayFeed(
      upNext: upNext,
      recent: recent,
      maxItems: featuredClanFixtureId == null ? 3 : 2,
    );
  }

  Fixture? get _nextClanFixture {
    final clan = _myClan;
    if (clan == null) return null;
    final today = _bahrainTodayDate();
    final candidates = _fixtures.where((fixture) {
      final involvesClan =
          fixture.homeClanId == clan.id || fixture.awayClanId == clan.id;
      if (!involvesClan || fixture.isFinal || fixture.isCancelled) return false;
      if (fixture.isLive) {
        return _sameCalendarDate(fixture.matchDate, today);
      }
      if (fixture.homeScore != null || fixture.awayScore != null) return false;
      return !_calendarDate(fixture.matchDate).isBefore(today);
    }).toList()..sort((a, b) => a.matchDate.compareTo(b.matchDate));
    return candidates.isEmpty ? null : candidates.first;
  }

  @override
  Widget build(BuildContext context) {
    final myClan = _myClan;
    final nextClanFixture = _nextClanFixture;
    return FieldHeaderOverlay(
      header: const FieldPageHeader(title: 'Field'),
      child: RefreshIndicator(
        color: fieldEmerald600,
        edgeOffset: fieldPageHeaderExtent(context),
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: fieldHeaderAwarePadding(context, top: 16, bottom: 124),
          children: [
            if (_loading && _profile == null) ...[
              const FieldSkeletonBox(height: 150, borderRadius: 24),
              const SizedBox(height: 16),
              const FieldSkeletonBox(height: 245, borderRadius: 24),
              const SizedBox(height: 16),
              const FieldSkeletonBox(height: 170, borderRadius: 24),
            ] else if (_error != null && _profile == null)
              _HomeError(message: _error!, onRetry: _load)
            else ...[
              _PlayerRatingCard(
                profile: _profile!,
                rating: _rating,
                season: _ratingSeason,
                onTap: widget.onOpenProfile,
                onRanks: widget.onOpenRanks,
              ),
              const SizedBox(height: 18),
              if (_partyInviteNotice case final notice?) ...[
                _HomePartyInviteAlert(notice: notice, onTap: _openPartyInvite),
                const SizedBox(height: 10),
              ],
              if (_bookings.isNotEmpty)
                _SoloBookingsSection(
                  bookings: _bookings,
                  onBooking: _openBooking,
                  onBookAnother: _openQueue,
                )
              else
                _FindGameHero(
                  onTap: _openQueue,
                  playerCount: _openQueuePlayerCount,
                ),
              const SizedBox(height: 22),
              _ActivitySection(
                feed: _matchdayFeed,
                onSeeAll: widget.onOpenFixtures,
                onMatch: _openActivity,
                featuredClan: myClan != null && nextClanFixture != null
                    ? _MyClanSection(
                        clan: myClan,
                        nextFixture: nextClanFixture,
                        regionalRank: _regionalClanRank(myClan),
                        showSectionLabel: false,
                        onTap: () => _openFixture(
                          nextClanFixture,
                          initiallyShowWatch: nextClanFixture.isLive,
                        ),
                      )
                    : null,
              ),
              if (myClan != null && nextClanFixture == null) ...[
                const SizedBox(height: 23),
                _MyClanSection(
                  clan: myClan,
                  nextFixture: null,
                  regionalRank: _regionalClanRank(myClan),
                  onTap: _openClan,
                ),
              ] else if (myClan == null) ...[
                const SizedBox(height: 23),
                _FindClanSection(
                  recruitingCount: _clans
                      .where((clan) => clan.memberCount < 20)
                      .length,
                  onTap: widget.onOpenClans,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: fieldGray400, fontSize: 11),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  int _regionalClanRank(Clan clan) {
    final ranked =
        _clans.where((candidate) => candidate.region == clan.region).toList()
          ..sort((a, b) => b.skillRating.compareTo(a.skillRating));
    final index = ranked.indexWhere((candidate) => candidate.id == clan.id);
    return index < 0 ? 0 : index + 1;
  }
}

class _PlayerRatingCard extends StatelessWidget {
  const _PlayerRatingCard({
    required this.profile,
    required this.rating,
    required this.season,
    required this.onTap,
    required this.onRanks,
  });

  final PlayerProfile profile;
  final PlayerRatingLeaderboardEntry? rating;
  final LeaderboardSeason season;
  final VoidCallback onTap;
  final VoidCallback onRanks;

  @override
  Widget build(BuildContext context) {
    final value = rating?.skillRating ?? 1200;
    final ratingChange = rating?.lastChange ?? 0;
    final tier = playerRatingTier(value);
    final next = playerRatingNextTierTarget(value);
    final isMaxTier = value >= next;
    final progressStart = next == 800
        ? 0
        : next == 1200
        ? 800
        : next == 1600
        ? 1200
        : next == 2000
        ? 1600
        : 2000;
    final progress = ((value - progressStart) / (next - progressStart)).clamp(
      0.0,
      1.0,
    );
    final gamesNeeded =
        rating?.gamesNeededToRank ?? minimumPlayerLeaderboardMatches;
    final rankLabel = rating?.isRanked == true
        ? '#${rating!.rank} in Bahrain · ${season.label}'
        : '$gamesNeeded rated game${gamesNeeded == 1 ? '' : 's'} to enter ${season.label} rankings';

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Container(
          padding: const EdgeInsets.all(19),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: fieldGray100),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0D111827),
                blurRadius: 12,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFFF59E0B),
                                Color(0xFFFCD34D),
                                Color(0xFFD97706),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(15),
                            child: ColoredBox(
                              color: Colors.white,
                              child:
                                  profile.avatarUrl?.trim().isNotEmpty == true
                                  ? Image.network(
                                      profile.avatarUrl!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Center(
                                        child: Text(
                                          profile.initials,
                                          style: const TextStyle(
                                            color: fieldGray700,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                                    )
                                  : Center(
                                      child: Text(
                                        profile.initials,
                                        style: const TextStyle(
                                          color: fieldGray700,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: -2,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: fieldGray900,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              tier.toUpperCase(),
                              style: const TextStyle(
                                color: Color(0xFFFCD34D),
                                fontSize: 7,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PLAYER RATING',
                          style: TextStyle(
                            color: fieldEmerald600,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '$value',
                              style: const TextStyle(
                                color: fieldGray900,
                                fontSize: 31,
                                height: 1.1,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${ratingChange >= 0 ? '+' : ''}$ratingChange',
                                style: TextStyle(
                                  color: ratingChange < 0
                                      ? Colors.redAccent
                                      : fieldEmerald600,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          rankLabel,
                          maxLines: 2,
                          style: const TextStyle(
                            color: fieldGray500,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: onRanks,
                    borderRadius: BorderRadius.circular(16),
                    child: const Column(
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFFFBBF24), Color(0xFFF97316)],
                            ),
                            borderRadius: BorderRadius.all(Radius.circular(14)),
                          ),
                          child: SizedBox(
                            width: 42,
                            height: 42,
                            child: Icon(
                              Icons.emoji_events_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'RANKS',
                          style: TextStyle(
                            color: fieldGray400,
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    tier,
                    style: const TextStyle(
                      color: fieldGray400,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    isMaxTier
                        ? 'Max tier'
                        : 'Next tier · ${next - value} to go',
                    style: const TextStyle(
                      color: fieldGray400,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: progress,
                  color: const Color(0xFFF59E0B),
                  backgroundColor: fieldGray100,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FindGameHero extends StatelessWidget {
  const _FindGameHero({required this.onTap, required this.playerCount});
  final VoidCallback onTap;
  final int playerCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(23),
      decoration: BoxDecoration(
        gradient: const RadialGradient(
          center: Alignment.topRight,
          radius: 1.45,
          colors: [Color(0xFF159F72), Color(0xFF047857), Color(0xFF07352A)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33065F46),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.circle, color: Color(0xFFBEF264), size: 8),
              SizedBox(width: 7),
              Text(
                'RANKED OPEN QUEUE · LIVE',
                style: TextStyle(
                  color: fieldEmerald200,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'READY FOR A MATCH?',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              height: 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose your position, see balanced 6-a-side games, then book your spot.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFD1FAE5),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(62),
              backgroundColor: Colors.white,
              foregroundColor: fieldEmerald800,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: const CircleAvatar(
              radius: 16,
              backgroundColor: fieldEmerald600,
              child: Icon(Icons.bolt_rounded, color: Colors.white, size: 18),
            ),
            label: const Text(
              'FIND A GAME',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 40,
                height: 18,
                child: Stack(
                  children: [
                    for (var index = 0; index < 3; index++)
                      Positioned(
                        left: index * 11,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: fieldEmerald200,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: fieldEmerald800,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '$playerCount player${playerCount == 1 ? '' : 's'} already booked',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: fieldEmerald200,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
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

class _HomePartyInviteLoad {
  const _HomePartyInviteLoad({this.booking, this.notice});

  final OpenQueueBooking? booking;
  final _HomePartyInviteNotice? notice;
}

class _HomePartyInviteNotice {
  const _HomePartyInviteNotice({
    required this.gameId,
    required this.inviterName,
    required this.dateLabel,
    required this.timeLabel,
    this.notificationId,
  });

  final String gameId;
  final String? notificationId;
  final String inviterName;
  final String dateLabel;
  final String timeLabel;
}

class _HomePartyInviteAlert extends StatelessWidget {
  const _HomePartyInviteAlert({required this.notice, required this.onTap});

  final _HomePartyInviteNotice notice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: ValueKey('home-party-invite-${notice.gameId}'),
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            border: Border.all(color: fieldEmerald200, width: 1.4),
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1410B981),
                blurRadius: 18,
                offset: Offset(0, 7),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(
                  color: fieldEmerald50,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.group_add_rounded,
                  color: fieldEmerald700,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PARTY INVITE WAITING',
                      style: TextStyle(
                        color: fieldEmerald700,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${notice.inviterName} wants to team up',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${notice.dateLabel} · ${notice.timeLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray500,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'REVIEW',
                    style: TextStyle(
                      color: fieldEmerald700,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .6,
                    ),
                  ),
                  SizedBox(height: 2),
                  Icon(
                    Icons.arrow_forward_rounded,
                    color: fieldEmerald700,
                    size: 19,
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

class _SoloBookingsSection extends StatefulWidget {
  const _SoloBookingsSection({
    required this.bookings,
    required this.onBooking,
    required this.onBookAnother,
  });

  final List<OpenQueueBooking> bookings;
  final ValueChanged<OpenQueueBooking> onBooking;
  final VoidCallback onBookAnother;

  @override
  State<_SoloBookingsSection> createState() => _SoloBookingsSectionState();
}

class _SoloBookingsSectionState extends State<_SoloBookingsSection> {
  static const maxBookings = 2;
  static const carouselHeight = 272.0;

  late final PageController _pageController;
  int _currentPage = 0;

  List<OpenQueueBooking> get _orderedBookings {
    final ordered = [...widget.bookings]
      ..sort((left, right) {
        final kickoff = left.game.startsAt.compareTo(right.game.startsAt);
        return kickoff != 0 ? kickoff : left.id.compareTo(right.id);
      });
    return ordered.take(maxBookings).toList(growable: false);
  }

  String _bookingSignature(List<OpenQueueBooking> bookings) {
    final ordered = [...bookings]
      ..sort((left, right) {
        final kickoff = left.game.startsAt.compareTo(right.game.startsAt);
        return kickoff != 0 ? kickoff : left.id.compareTo(right.id);
      });
    return ordered.map((booking) => booking.id).join('|');
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void didUpdateWidget(covariant _SoloBookingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_bookingSignature(oldWidget.bookings) ==
        _bookingSignature(widget.bookings)) {
      return;
    }
    _currentPage = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bookings = _orderedBookings;
    return Column(
      key: const ValueKey('home-solo-bookings-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'YOUR SOLO GAMES',
          style: TextStyle(
            color: fieldGray600,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: carouselHeight,
          child: PageView.builder(
            key: const ValueKey('home-solo-bookings-carousel'),
            controller: _pageController,
            itemCount: maxBookings,
            allowImplicitScrolling: true,
            clipBehavior: Clip.none,
            physics: const BouncingScrollPhysics(),
            onPageChanged: (page) => setState(() => _currentPage = page),
            itemBuilder: (context, index) {
              if (index < bookings.length) {
                final booking = bookings[index];
                return _ConfirmedQueueHero(
                  booking: booking,
                  onTap: () => widget.onBooking(booking),
                );
              }
              return _BookSecondSoloGameCard(onTap: widget.onBookAnother);
            },
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          key: ValueKey('home-solo-carousel-page-${_currentPage + 1}'),
          label: 'Solo games page ${_currentPage + 1} of $maxBookings',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var index = 0; index < maxBookings; index++) ...[
                AnimatedContainer(
                  key: ValueKey('home-solo-carousel-dot-$index'),
                  duration: const Duration(milliseconds: 180),
                  width: index == _currentPage ? 18 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: index == _currentPage
                        ? fieldEmerald600
                        : fieldGray200,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                if (index < maxBookings - 1) const SizedBox(width: 6),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BookSecondSoloGameCard extends StatelessWidget {
  const _BookSecondSoloGameCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Register for a second solo game',
      child: Material(
        key: const ValueKey('home-book-another-solo-game'),
        color: fieldEmerald50,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              border: Border.all(color: fieldEmerald200, width: 1.5),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: const BoxDecoration(
                    color: fieldEmerald600,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.add_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'REGISTER FOR A SECOND GAME',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: fieldGray900,
                    fontSize: 18,
                    height: 1.15,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 9),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'FIND A GAME',
                      style: TextStyle(
                        color: fieldEmerald700,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .7,
                      ),
                    ),
                    SizedBox(width: 5),
                    Icon(
                      Icons.arrow_forward_rounded,
                      color: fieldEmerald700,
                      size: 17,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfirmedQueueHero extends StatelessWidget {
  const _ConfirmedQueueHero({required this.booking, required this.onTap});
  final OpenQueueBooking booking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final game = booking.game;
    final isConfirmed = game.isUpcomingMatchConfirmed;
    // An active booking means this player already occupies at least one place,
    // even if a stale aggregate briefly comes back as zero.
    final confirmedCount = game.confirmedCount.clamp(1, game.capacity);
    final playersNeeded = (game.capacity - confirmedCount).clamp(
      0,
      game.capacity,
    );
    final statusLabel = isConfirmed
        ? 'MATCH IS ON'
        : playersNeeded == 0
        ? 'FINALIZING MATCH'
        : 'WAITING FOR $playersNeeded ${playersNeeded == 1 ? 'PLAYER' : 'PLAYERS'}';
    final accent = isConfirmed ? fieldEmerald100 : const Color(0xFFFFF3C4);
    final matchAverage = game.hasActiveTeamAssignment
        ? game.matchAverageSr
        : null;

    return Container(
      key: ValueKey('home-solo-booking-${booking.id}'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: isConfirmed
                ? const Color(0x4410B981)
                : const Color(0x44F59E0B),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topLeft,
              radius: 1.4,
              colors: isConfirmed
                  ? const [fieldEmerald500, fieldEmerald600, Color(0xFF0B3D2E)]
                  : const [
                      Color(0xFFF59E0B),
                      Color(0xFFD97706),
                      Color(0xFFB45309),
                    ],
            ),
          ),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isConfirmed
                            ? Icons.check_circle_rounded
                            : Icons.hourglass_top_rounded,
                        color: Colors.white,
                        size: 19,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          statusLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: accent,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.24),
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$confirmedCount/${game.capacity}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (isConfirmed)
                    Row(
                      children: [
                        Icon(Icons.verified_rounded, color: accent, size: 14),
                        const SizedBox(width: 5),
                        Text(
                          'YOUR SPOT IS RESERVED',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.92),
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .8,
                          ),
                        ),
                      ],
                    )
                  else
                    Text(
                      'Your booking is reserved',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.86),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  const SizedBox(height: 13),
                  Text(
                    '${_homeBookingDateLabel(game)} · ${game.startTimeLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      height: 1.05,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        Icons.location_on_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          _homeBookingVenueLabel(game.venue),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 11),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          booking.role.label.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .5,
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (matchAverage != null)
                        Text(
                          'AVG RATING $matchAverage',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .3,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 11),
                  if (isConfirmed && game.isTeamAssignmentDue)
                    OpenQueueKitIndicator(booking: booking, compact: true)
                  else
                    _PendingHomeKitSummary(
                      assignmentDue: game.isTeamAssignmentDue,
                      assignmentLeadLabel: game.teamAssignmentLeadLabel,
                    ),
                  const Spacer(),
                  Text(
                    isConfirmed ? 'Match details  ›' : 'Booking details  ›',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingHomeKitSummary extends StatelessWidget {
  const _PendingHomeKitSummary({
    required this.assignmentDue,
    required this.assignmentLeadLabel,
  });

  final bool assignmentDue;
  final String assignmentLeadLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('pending-kit-info-panel'),
      height: 50,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: OpenQueueJerseyIcon(
              color: Colors.white.withValues(alpha: 0.82),
              size: 20,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'KIT',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.68),
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  assignmentDue
                      ? 'Assigned when match is full'
                      : 'Assigned $assignmentLeadLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w800,
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

String _homeBookingDateLabel(OpenQueueGame game) {
  if (game.isToday) return 'TODAY';
  if (game.isTomorrow) return 'TOMORROW';
  return game.calendarDateLabel;
}

String _homeBookingVenueLabel(String venue) {
  final raw = venue.trim();
  final isInternalSeed =
      raw.startsWith('[SCHEDULE SEED]') || raw.startsWith('[OQ MOCK]');
  final cleaned = raw
      .replaceFirst(RegExp(r'^\[(?:SCHEDULE SEED|OQ MOCK)\]\s*'), '')
      .trim();
  if (isInternalSeed &&
      RegExp(r'^(?:Solo|Clan) (?:Future|History)\b').hasMatch(cleaned)) {
    return 'TFA, Saar';
  }
  return cleaned.isEmpty ? 'Venue TBC' : cleaned;
}

class _MyClanSection extends StatelessWidget {
  const _MyClanSection({
    required this.clan,
    required this.nextFixture,
    required this.regionalRank,
    required this.onTap,
    this.showSectionLabel = true,
  });
  final Clan clan;
  final Fixture? nextFixture;
  final int regionalRank;
  final VoidCallback onTap;
  final bool showSectionLabel;

  @override
  Widget build(BuildContext context) {
    final rankLine = [
      clan.rank.label,
      if (regionalRank > 0) '#$regionalRank Bahrain' else 'Bahrain',
    ].join(' · ');
    final fixture = nextFixture;
    final fixtureAccent = fixture?.isLive == true
        ? const Color(0xFFF87171)
        : fieldEmerald500;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showSectionLabel) ...[
          const _HomeSectionLabel('YOUR CLAN'),
          const SizedBox(height: 10),
        ],
        Material(
          key: ValueKey(
            fixture == null
                ? 'home-clan-summary-compact'
                : 'home-clan-summary-expanded',
          ),
          color: Colors.white,
          borderRadius: BorderRadius.circular(fixture == null ? 20 : 24),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(fixture == null ? 20 : 24),
            child: Container(
              key: ValueKey(
                fixture == null ? 'home-clan-compact' : 'home-clan-expanded',
              ),
              padding: EdgeInsets.all(fixture == null ? 14 : 17),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(fixture == null ? 20 : 24),
                border: Border.all(color: fieldGray100),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [clan.theme.from, clan.theme.to],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Center(
                          child: Text(
                            clan.emblem,
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
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
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              rankLine,
                              style: const TextStyle(
                                color: fieldGray600,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: fieldGray400,
                      ),
                    ],
                  ),
                  if (fixture != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: fieldGray900,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.sports_soccer_rounded,
                              color: fixtureAccent,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  fixture.isLive
                                      ? 'LIVE CLAN FIXTURE'
                                      : 'UPCOMING CLAN FIXTURE',
                                  style: TextStyle(
                                    color: fixtureAccent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  fixture.homeClanId == clan.id
                                      ? 'vs ${fixture.awayClan?.name ?? 'Opponent TBD'}'
                                      : 'at ${fixture.homeClan.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 16,
                                  runSpacing: 7,
                                  children: [
                                    _InlineMatchMeta(
                                      icon: Icons.calendar_today_rounded,
                                      label: _relativeDateLabel(
                                        fixture.matchDate,
                                      ),
                                      color: fieldGray300,
                                    ),
                                    _InlineMatchMeta(
                                      icon: Icons.schedule_rounded,
                                      label: _fixtureStart(fixture),
                                      color: fieldGray300,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 7),
                                _LocationMatchMeta(
                                  label: _displayVenue(fixture.venue),
                                  color: fieldGray300,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FindClanSection extends StatelessWidget {
  const _FindClanSection({required this.recruitingCount, required this.onTap});
  final int recruitingCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _HomeSectionLabel('FIND YOUR CLAN'),
        const SizedBox(height: 10),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: fieldGray100),
              ),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: const Icon(
                      Icons.groups_rounded,
                      color: fieldBlue600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Join a Clan',
                          style: TextStyle(
                            color: fieldGray900,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          '$recruitingCount clans are currently recruiting',
                          style: const TextStyle(
                            color: fieldGray500,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: fieldGray300),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeMatchdayFeed {
  const _HomeMatchdayFeed({required this.upNext, required this.recent});

  final List<_HomeActivityItem> upNext;
  final List<_HomeActivityItem> recent;

  bool get isEmpty => upNext.isEmpty && recent.isEmpty;
}

class _HomeActivityItem {
  const _HomeActivityItem._({
    this.fixture,
    this.soloGame,
    this.previousGame,
    this.ratingEvent,
    this.soloDetail,
    this.isMyClanMatch = false,
  });

  factory _HomeActivityItem.clan(
    Fixture fixture, {
    ProfilePreviousGame? previousGame,
    ProfileRatingEvent? ratingEvent,
    bool isMyClanMatch = false,
  }) {
    return _HomeActivityItem._(
      fixture: fixture,
      previousGame: previousGame,
      ratingEvent: ratingEvent,
      isMyClanMatch: isMyClanMatch,
    );
  }

  factory _HomeActivityItem.solo(
    OpenQueueGame game, {
    ProfilePreviousGame? previousGame,
    ProfileRatingEvent? ratingEvent,
    OpenQueueMatchDetail? detail,
  }) {
    return _HomeActivityItem._(
      soloGame: game,
      previousGame: previousGame,
      ratingEvent: ratingEvent,
      soloDetail: detail,
    );
  }

  final Fixture? fixture;
  final OpenQueueGame? soloGame;
  final ProfilePreviousGame? previousGame;
  final ProfileRatingEvent? ratingEvent;
  final OpenQueueMatchDetail? soloDetail;
  final bool isMyClanMatch;

  bool get isSolo => soloGame != null;
  bool get isMyMatch => previousGame != null || soloGame?.hasMyBooking == true;

  bool get canJoinSolo {
    final game = soloGame;
    if (game == null) return false;
    return game.isUpcomingReservation &&
        status == FixtureStatus.open &&
        !game.isFull &&
        !game.hasMyBooking;
  }

  String get id => fixture?.id ?? soloGame!.id;

  DateTime get matchDate {
    final clanFixture = fixture;
    if (clanFixture != null) return _calendarDate(clanFixture.matchDate);
    final startsAt = soloGame!.bahrainStartsAt;
    return DateTime(startsAt.year, startsAt.month, startsAt.day);
  }

  FixtureStatus get status {
    final clanFixture = fixture;
    if (clanFixture != null) {
      if (clanFixture.isLive) return FixtureStatus.live;
      if (clanFixture.homeScore != null || clanFixture.awayScore != null) {
        return FixtureStatus.finalResult;
      }
      return clanFixture.status;
    }
    final game = soloGame!;
    if (game.status.toUpperCase() == 'LIVE') return FixtureStatus.live;
    if (game.hasRecordedScore) return FixtureStatus.finalResult;
    return switch (game.status.toUpperCase()) {
      'FULL' => FixtureStatus.scheduled,
      'FINAL' => FixtureStatus.finalResult,
      'CANCELLED' => FixtureStatus.cancelled,
      _ when game.isFull => FixtureStatus.scheduled,
      _ => FixtureStatus.open,
    };
  }

  int get sortMinutes {
    final game = soloGame;
    if (game != null) {
      final startsAt = game.bahrainStartsAt;
      return startsAt.hour * 60 + startsAt.minute;
    }
    return fixture!.timeSlot.startsWith('8:30') ? 20 * 60 + 30 : 19 * 60;
  }

  DateTime get sortDateTime => matchDate.add(Duration(minutes: sortMinutes));

  bool get isCompleted => status == FixtureStatus.finalResult;
  bool get isCancelled => status == FixtureStatus.cancelled;
  bool get isLive => status == FixtureStatus.live;
  bool get isRelevantLive => isMyMatch || isMyClanMatch || isSolo;

  bool get isUpcomingForViewer {
    if (isSolo) return soloGame!.hasMyBooking || canJoinSolo;
    return isMyClanMatch;
  }

  int get remainingSpots {
    final game = soloGame;
    if (game == null) return 0;
    return (game.capacity - game.confirmedCount)
        .clamp(0, game.capacity)
        .toInt();
  }

  Fixture? get playbackFixture => fixture ?? soloDetail?.toFixture();

  bool get hasFullMatch => playbackFixture?.fullGamePlaybackUrl != null;

  int get highlightCount {
    final playback = playbackFixture;
    if (playback == null || playback.fullGamePlaybackUrl == null) return 0;
    return playback.highlightMoments.length;
  }

  bool get highlightsReady => highlightCount > 0;
  bool get shouldOpenWatch => isLive || highlightsReady || hasFullMatch;

  FixturePlayerRatingUpdate? get fixturePlayerRatingUpdate {
    final event = ratingEvent;
    if (event != null) {
      return FixturePlayerRatingUpdate(
        ratingBefore: event.ratingBefore,
        ratingChange: event.ratingChange,
        ratingAfter: event.ratingAfter,
        result: event.result,
        scoreMargin: event.scoreMargin,
        marginMultiplier: event.marginMultiplier,
        baseRatingChange: event.baseRatingChange,
        marginBonusApplied: event.marginBonusApplied,
      );
    }
    final soloUpdate = soloDetail?.viewerRatingUpdate;
    if (soloUpdate != null) return soloUpdate;
    final clanFixture = fixture;
    if (clanFixture == null) return null;
    for (final player in [
      ...clanFixture.homeLineup,
      ...clanFixture.awayLineup,
    ]) {
      final ratingBefore = player.displayedRating;
      final ratingChange = player.ratingChange;
      if (!player.isMe || ratingBefore == null || ratingChange == null) {
        continue;
      }
      return FixturePlayerRatingUpdate(
        ratingBefore: ratingBefore,
        ratingChange: ratingChange,
        ratingAfter: ratingBefore + ratingChange,
      );
    }
    return null;
  }

  int get upcomingPriority {
    if (isLive) return 0;
    if (soloGame?.hasMyBooking == true) return 1;
    if (canJoinSolo) return 2;
    if (isMyClanMatch) return 3;
    return 4;
  }

  int get recentPriority {
    if (previousGame != null && highlightsReady) return 0;
    if (previousGame != null) return 1;
    if (isMyClanMatch) return 2;
    if (highlightsReady) return 3;
    return 4;
  }

  String get matchup {
    final played = previousGame;
    if (played != null) {
      return '${played.homeTag}  ${played.homeScore}–${played.awayScore}  ${played.awayTag}';
    }
    final clanFixture = fixture;
    if (clanFixture != null) {
      final away = clanFixture.awayClan?.tag ?? 'TBD';
      if (isCompleted || isLive) {
        return '${clanFixture.homeClan.tag}  ${clanFixture.homeScore ?? 0}–${clanFixture.awayScore ?? 0}  $away';
      }
      return '${clanFixture.homeClan.tag} vs $away';
    }
    final game = soloGame!;
    if (isCompleted || isLive) {
      return 'WHITE  ${game.whiteScore ?? 0}–${game.blackScore ?? 0}  BLACK';
    }
    if (canJoinSolo) {
      return 'Solo match · $remainingSpots ${remainingSpots == 1 ? 'spot' : 'spots'} left';
    }
    if (game.hasMyBooking) {
      final role = game.myBookingRole?.label;
      final assignedTeam = game.hasActiveTeamAssignment
          ? switch (game.myBookingTeam) {
              openQueueWhiteTeamId => 'White team',
              openQueueBlackTeamId => 'Black team',
              _ => null,
            }
          : null;
      final parts = [
        if (role != null) role,
        if (assignedTeam != null) assignedTeam,
      ];
      return parts.isEmpty ? 'Your solo match' : parts.join(' · ');
    }
    return 'Solo match';
  }

  String get venue => fixture?.venue ?? soloGame!.venue;

  String get timeLabel {
    final game = soloGame;
    return game?.timeLabel ?? _fixtureStart(fixture!);
  }

  String get typeLabel => isSolo ? 'SOLO' : 'CLAN';

  String get eyebrowLabel {
    return switch (status) {
      FixtureStatus.live => 'LIVE NOW',
      FixtureStatus.finalResult when previousGame != null => 'YOUR RESULT',
      FixtureStatus.finalResult when isMyClanMatch => 'CLAN RESULT',
      FixtureStatus.finalResult => 'RESULT',
      _ when soloGame?.hasMyBooking == true => 'YOUR MATCH',
      _ when canJoinSolo => 'OPEN SOLO MATCH',
      _ when isMyClanMatch => 'YOUR CLAN',
      _ => 'UPCOMING',
    };
  }

  String get detailLabel {
    if (!isCompleted) return '';

    final ratingUpdate = fixturePlayerRatingUpdate;
    final parts = <String>[
      if (ratingUpdate != null) _signedSr(ratingUpdate.ratingChange),
      if (highlightsReady)
        '$highlightCount ${highlightCount == 1 ? 'highlight' : 'highlights'} ready'
      else if (hasFullMatch)
        'Full match ready'
      else
        'Full time',
    ];
    return parts.join(' · ');
  }

  String get dateLabel => _relativeDateLabel(matchDate);

  String get venueLabel => _displayVenue(venue);

  String get actionLabel {
    if (canJoinSolo) return 'JOIN';
    if (isLive) return 'LIVE';
    if (shouldOpenWatch) return 'WATCH';
    return 'VIEW';
  }
}

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({
    required this.feed,
    required this.onSeeAll,
    required this.onMatch,
    this.featuredClan,
  });
  final _HomeMatchdayFeed feed;
  final VoidCallback onSeeAll;
  final ValueChanged<_HomeActivityItem> onMatch;
  final Widget? featuredClan;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _HomeSectionLabel('MATCHDAY'),
            const Spacer(),
            TextButton.icon(
              onPressed: onSeeAll,
              icon: const Icon(Icons.chevron_right_rounded, size: 16),
              iconAlignment: IconAlignment.end,
              label: const Text('All matches'),
              style: TextButton.styleFrom(foregroundColor: fieldEmerald600),
            ),
          ],
        ),
        const SizedBox(height: 5),
        if (feed.isEmpty && featuredClan == null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: fieldGray100),
            ),
            child: const Text(
              'No matchday activity yet.',
              style: TextStyle(color: fieldGray500),
            ),
          )
        else ...[
          if (feed.upNext.isNotEmpty || featuredClan != null)
            Column(
              key: const ValueKey('home-matchday-up-next'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 3, bottom: 7),
                  child: Text(
                    'UP NEXT',
                    style: TextStyle(
                      color: fieldGray600,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                if (featuredClan case final clan?) clan,
                if (featuredClan != null && feed.upNext.isNotEmpty)
                  const SizedBox(height: 16),
                if (feed.upNext.isNotEmpty)
                  _ActivityGroup(
                    label: 'UP NEXT',
                    showLabel: false,
                    items: feed.upNext,
                    onMatch: onMatch,
                  ),
              ],
            ),
          if ((feed.upNext.isNotEmpty || featuredClan != null) &&
              feed.recent.isNotEmpty)
            const SizedBox(height: 22),
          if (feed.recent.isNotEmpty)
            _ActivityGroup(
              key: const ValueKey('home-matchday-recent'),
              label: 'RECENT',
              items: feed.recent,
              onMatch: onMatch,
            ),
        ],
      ],
    );
  }
}

class _ActivityGroup extends StatelessWidget {
  const _ActivityGroup({
    super.key,
    required this.label,
    required this.items,
    required this.onMatch,
    this.showLabel = true,
  });

  final String label;
  final List<_HomeActivityItem> items;
  final ValueChanged<_HomeActivityItem> onMatch;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel)
          Padding(
            padding: const EdgeInsets.only(left: 3, bottom: 7),
            child: Text(
              label,
              style: const TextStyle(
                color: fieldGray600,
                fontSize: 11.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: fieldGray100),
            boxShadow: [
              BoxShadow(
                color: fieldGray900.withValues(alpha: 0.035),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var index = 0; index < items.length; index++) ...[
                _ActivityRow(
                  item: items[index],
                  onTap: () => onMatch(items[index]),
                ),
                if (index != items.length - 1)
                  const Divider(height: 1, indent: 71, color: fieldGray100),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item, required this.onTap});
  final _HomeActivityItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isWatch = item.shouldOpenWatch && !item.canJoinSolo;
    final accentColor = item.isLive
        ? const Color(0xFFDC2626)
        : item.canJoinSolo
        ? fieldEmerald600
        : item.isCompleted
        ? (isWatch ? fieldBlue600 : fieldGray600)
        : fieldEmerald700;
    final accentBackground = item.isLive
        ? const Color(0xFFFEF2F2)
        : item.canJoinSolo
        ? fieldEmerald50
        : item.isCompleted
        ? (isWatch ? const Color(0xFFEFF6FF) : fieldGray100)
        : fieldEmerald50;
    final icon = item.isLive || isWatch
        ? Icons.play_arrow_rounded
        : item.isCompleted
        ? Icons.sports_score_rounded
        : item.isSolo
        ? Icons.person_rounded
        : Icons.shield_rounded;

    return Semantics(
      button: true,
      label:
          '${item.eyebrowLabel}. ${item.matchup}. ${item.detailLabel}. ${item.dateLabel}. ${item.timeLabel}. ${item.venueLabel}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey(
            'home-activity-${item.isSolo ? 'solo' : 'clan'}-${item.id}',
          ),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: accentBackground,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: accentColor, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.eyebrowLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accentColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.75,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        item.matchup,
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 15,
                          height: 1.2,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (item.detailLabel.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          item.detailLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: fieldGray700,
                            fontSize: 11.5,
                            height: 1.3,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      _InlineMatchMeta(
                        icon: Icons.calendar_today_rounded,
                        label: item.dateLabel,
                        color: fieldGray600,
                      ),
                      if (!item.isCompleted) ...[
                        const SizedBox(height: 7),
                        _InlineMatchMeta(
                          icon: Icons.schedule_rounded,
                          label: item.timeLabel,
                          color: fieldGray600,
                        ),
                      ],
                      const SizedBox(height: 7),
                      _LocationMatchMeta(
                        label: item.venueLabel,
                        color: fieldGray600,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  key: item.canJoinSolo
                      ? ValueKey('home-activity-join-${item.id}')
                      : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: item.actionLabel == 'VIEW'
                        ? fieldGray100
                        : accentColor,
                    borderRadius: BorderRadius.circular(11),
                    boxShadow: item.canJoinSolo
                        ? [
                            BoxShadow(
                              color: fieldEmerald500.withValues(alpha: 0.24),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.canJoinSolo || item.shouldOpenWatch) ...[
                        Icon(
                          item.canJoinSolo
                              ? Icons.bolt_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 14,
                        ),
                        const SizedBox(width: 2),
                      ],
                      Text(
                        item.actionLabel,
                        style: TextStyle(
                          color: item.actionLabel == 'VIEW'
                              ? fieldGray700
                              : Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.55,
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
    );
  }
}

class _InlineMatchMeta extends StatelessWidget {
  const _InlineMatchMeta({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 5),
        Flexible(
          fit: FlexFit.loose,
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              height: 1.25,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _LocationMatchMeta extends StatelessWidget {
  const _LocationMatchMeta({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.location_on_outlined, color: color, size: 14),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              height: 1.3,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeSectionLabel extends StatelessWidget {
  const _HomeSectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: fieldGray500,
        fontSize: 12,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.25,
      ),
    );
  }
}

class _HomeError extends StatelessWidget {
  const _HomeError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_rounded, color: fieldGray400, size: 38),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

String _fixtureStart(Fixture fixture) {
  return fixture.timeSlot.split(' - ').first;
}

int _compareUpcomingActivity(_HomeActivityItem left, _HomeActivityItem right) {
  if (left.isLive != right.isLive) return left.isLive ? -1 : 1;
  final leftIsBooked = left.soloGame?.hasMyBooking == true;
  final rightIsBooked = right.soloGame?.hasMyBooking == true;
  if (leftIsBooked != rightIsBooked) return leftIsBooked ? -1 : 1;
  final time = left.sortDateTime.compareTo(right.sortDateTime);
  if (time != 0) return time;
  final priority = left.upcomingPriority.compareTo(right.upcomingPriority);
  if (priority != 0) return priority;
  if (left.canJoinSolo && right.canJoinSolo) {
    final availability = left.remainingSpots.compareTo(right.remainingSpots);
    if (availability != 0) return availability;
  }
  return left.id.compareTo(right.id);
}

int _compareRecentActivity(_HomeActivityItem left, _HomeActivityItem right) {
  final today = _bahrainTodayDate();
  int freshness(_HomeActivityItem item) {
    final age = today.difference(item.matchDate).inDays.clamp(0, 1 << 20);
    if (age <= 7) return 0;
    if (age <= 30) return 1;
    return 2;
  }

  final freshnessOrder = freshness(left).compareTo(freshness(right));
  if (freshnessOrder != 0) return freshnessOrder;
  final priority = left.recentPriority.compareTo(right.recentPriority);
  if (priority != 0) return priority;
  final time = right.sortDateTime.compareTo(left.sortDateTime);
  return time != 0 ? time : left.id.compareTo(right.id);
}

_HomeMatchdayFeed _limitMatchdayFeed({
  required List<_HomeActivityItem> upNext,
  required List<_HomeActivityItem> recent,
  int maxItems = 3,
}) {
  if (upNext.isEmpty) {
    return _HomeMatchdayFeed(
      upNext: const [],
      recent: recent.take(maxItems).toList(),
    );
  }
  if (recent.isEmpty) {
    return _HomeMatchdayFeed(
      upNext: upNext.take(maxItems).toList(),
      recent: const [],
    );
  }

  final upNextLimit = maxItems <= 2 ? 1 : 2;
  final visibleUpNext = upNext.take(upNextLimit).toList();
  final visibleRecent = recent.take(maxItems - visibleUpNext.length).toList();
  return _HomeMatchdayFeed(upNext: visibleUpNext, recent: visibleRecent);
}

DateTime _bahrainTodayDate() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 3));
  return DateTime(now.year, now.month, now.day);
}

DateTime _calendarDate(DateTime value) {
  return DateTime(value.year, value.month, value.day);
}

bool _sameCalendarDate(DateTime left, DateTime right) {
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

String _relativeDateLabel(DateTime date) {
  final today = _bahrainTodayDate();
  final tomorrow = today.add(const Duration(days: 1));
  if (_sameCalendarDate(date, today)) return 'TODAY';
  if (_sameCalendarDate(date, tomorrow)) return 'TOMORROW';
  return _compactMatchDate(date);
}

String _displayVenue(String venue) {
  final cleaned = venue
      .replaceFirst(RegExp(r'^\[SCHEDULE SEED\]\s*'), '')
      .trim();
  return cleaned.isEmpty ? 'Venue TBC' : cleaned;
}

String _compactMatchDate(DateTime value) {
  const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
  const months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];
  return '${weekdays[value.weekday - 1]}, ${months[value.month - 1]} ${value.day}';
}

String _signedSr(int value) {
  if (value > 0) return '+$value SR';
  if (value < 0) return '−${value.abs()} SR';
  return '0 SR';
}
