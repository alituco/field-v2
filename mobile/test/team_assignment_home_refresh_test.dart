import 'dart:async';

import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_party_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'assigned games refresh on resume and through live, final and reopen',
    (tester) async {
      final queue = _Queue()..bookings = [_booking(team: 'BLACK')];
      final ratings = _Ratings();
      await _show(tester, queue, ratings: ratings);
      final reads = queue.bookingReads;
      final ratingReads = ratings.reads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      queue.bookings = [_booking(team: 'BLACK', status: 'LIVE')];
      queue.fixtureGames = [queue.bookings.single.game];
      await tester.pump(const Duration(minutes: 2));
      expect(queue.bookingReads, reads);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Your game is live'), findsOneWidget);
      expect(find.byType(FieldrushSoloHero), findsNothing);
      expect(ratings.reads, ratingReads + 1);

      queue.bookings = [];
      queue.fixtureGames = [_booking(team: 'BLACK', status: 'FINAL').game];
      ratings.rating = 1236;
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(find.text('Your game is live'), findsNothing);
      expect(find.byType(FieldrushQuickGameCard), findsOneWidget);
      expect(
        tester
            .widget<FieldrushHomeRating>(find.byType(FieldrushHomeRating))
            .rating
            ?.skillRating,
        1236,
      );

      queue.bookings = [_booking(team: 'BLACK', status: 'LIVE')];
      queue.fixtureGames = [queue.bookings.single.game];
      await tester.pump(const Duration(seconds: 60));
      await tester.pumpAndSettle();
      expect(find.text('Your game is live'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('delayed start retains the confirmed booking and assigned team', (
    tester,
  ) async {
    final booking = _booking(team: 'BLACK', late: true);
    final queue = _Queue()
      ..bookings = hydrateUpcomingOpenQueueBookings(
        bookings: [booking],
        games: [],
      )
      ..fixtureGames = [booking.game];
    await _show(tester, queue);
    expect(_hero(tester).booking.id, booking.id);
    expect(_hero(tester).booking.assignedTeam, 'BLACK');
    expect(find.byType(FieldrushQuickGameCard), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'current fixture result removes stale booking while its read is pending',
    (tester) async {
      final queue = _Queue();
      final ratings = _Ratings();
      await _show(tester, queue, ratings: ratings);
      final pending = Completer<List<OpenQueueBooking>>();
      queue.nextBookingRead = pending.future;
      queue.fixtureGames = [_booking(team: 'BLACK', status: 'FINAL').game];
      ratings.rating = 1236;
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(find.byType(FieldrushSoloHero), findsNothing);
      expect(find.byType(FieldrushQuickGameCard), findsOneWidget);
      expect(
        tester
            .widget<FieldrushHomeRating>(find.byType(FieldrushHomeRating))
            .rating
            ?.skillRating,
        1236,
      );
      final reads = queue.bookingReads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        queue.bookingReads,
        reads,
        reason: 'resume coalesces with the existing refresh',
      );
      pending.complete([]);
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushSoloHero), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'completed booking is not resurrected by a stale live fixture feed',
    (tester) async {
      final queue = _Queue()
        ..bookings = [_booking(team: 'BLACK', status: 'LIVE')]
        ..fixtureGames = [_booking(team: 'BLACK', status: 'LIVE').game];
      await _show(tester, queue);
      final pending = Completer<List<OpenQueueGame>>();
      queue.bookings = [];
      queue.nextFixtureRead = pending.future;
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(find.text('Your game is live'), findsNothing);
      pending.complete([_booking(team: 'BLACK', status: 'LIVE').game]);
      await tester.pumpAndSettle();
      expect(find.text('Your game is live'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'fresh live booking is not downgraded by a stale pregame fixture feed',
    (tester) async {
      final queue = _Queue()
        ..bookings = [_booking(team: 'BLACK')]
        ..fixtureGames = [_booking(team: 'BLACK').game];
      await _show(tester, queue);
      final pending = Completer<List<OpenQueueGame>>();
      queue.bookings = [_booking(team: 'BLACK', status: 'LIVE')];
      queue.nextFixtureRead = pending.future;
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(find.text('Your game is live'), findsOneWidget);
      pending.complete([_booking(team: 'BLACK').game]);
      await tester.pumpAndSettle();
      expect(find.text('Your game is live'), findsOneWidget);
      expect(find.byType(FieldrushSoloHero), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reopened live booking wins over a same-batch final fixture snapshot',
    (tester) async {
      final queue = _Queue()..bookings = [];
      await _show(tester, queue);
      queue.bookings = [_booking(team: 'BLACK', status: 'LIVE')];
      queue.fixtureGames = [_booking(team: 'BLACK', status: 'FINAL').game];
      await tester.pump(const Duration(seconds: 60));
      await tester.pumpAndSettle();
      expect(find.text('Your game is live'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'older full-load failures cannot replace a successful automatic refresh',
    (tester) async {
      final queue = _Queue()..bookings = [_booking(team: 'BLACK')];
      final ratings = _Ratings();
      await _show(tester, queue, ratings: ratings);
      final oldFixtures = Completer<List<OpenQueueGame>>();
      final oldRating = Completer<PlayerRatingLeaderboardEntry>();
      queue.nextFixtureRead = oldFixtures.future;
      ratings.nextRead = oldRating.future;
      await _show(tester, queue, tick: 1, ratings: ratings);
      ratings.rating = 1236;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      oldFixtures.completeError(StateError('Old fixture failure'));
      oldRating.completeError(StateError('Old rating failure'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('fieldrush-home-scroll')),
        const Offset(0, -1800),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not refresh'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'new assignment read supersedes older full-load ${fails ? 'failure' : 'success'}',
      (tester) async {
        final queue = _Queue();
        await _show(tester, queue);
        final oldRead = Completer<List<OpenQueueBooking>>();
        queue.nextBookingRead = oldRead.future;
        await _show(tester, queue, tick: 1);
        final readsBeforeAssignment = queue.bookingReads;
        final partyReads = queue.partyReads;

        queue.bookings = [_booking(team: 'BLACK')];
        await tester.pump(const Duration(seconds: 20));
        await tester.pumpAndSettle();
        expect(queue.bookingReads, readsBeforeAssignment + 1);
        expect(_hero(tester).booking.assignedTeam, 'BLACK');

        if (fails) {
          oldRead.completeError(StateError('Old pre-assignment read failed'));
        } else {
          oldRead.complete([_booking()]);
        }
        await tester.pumpAndSettle();
        expect(_hero(tester).booking.assignedTeam, 'BLACK');
        expect(queue.partyReads, partyReads);
        await tester.drag(
          find.byKey(const Key('fieldrush-home-scroll')),
          const Offset(0, -1800),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Could not refresh bookings'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('new full-load booking read supersedes old assignment refresh', (
    tester,
  ) async {
    final queue = _Queue();
    await _show(tester, queue);
    final oldRead = Completer<List<OpenQueueBooking>>();
    queue.nextBookingRead = oldRead.future;
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    final readsBeforeLoad = queue.bookingReads;

    queue.bookings = [_booking(team: 'WHITE')];
    await _show(tester, queue, tick: 1);
    expect(queue.bookingReads, readsBeforeLoad + 1);
    expect(_hero(tester).booking.assignedTeam, 'WHITE');

    oldRead.complete([_booking()]);
    await tester.pumpAndSettle();
    expect(_hero(tester).booking.assignedTeam, 'WHITE');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hidden Home skips both due callback and assignment polling', (
    tester,
  ) async {
    final queue = _Queue();
    await _show(tester, queue, enabled: false);
    expect(queue.bookingReads, 1);
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(queue.bookingReads, 1);

    queue.bookings = [_booking(team: 'BLACK')];
    await _show(tester, queue);
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(queue.bookingReads, 2);
    expect(_hero(tester).booking.assignedTeam, 'BLACK');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final fails in [false, true]) {
    testWidgets(
      'superseded party ${fails ? 'failure' : 'invite'} cannot publish after assignment refresh',
      (tester) async {
        final queue = _Queue();
        await _show(tester, queue);
        final oldParty = Completer<OpenQueuePartyContext>();
        queue.nextPartyRead = oldParty.future;
        final previousReads = queue.partyReads;
        // A newly loaded saved deadline resets the notice's one-shot callback.
        // It starts the targeted refresh while this load's party read is still
        // pending, before the ordinary 12-second party timeout can expire.
        queue.nextBookingRead = Future.value([_booking()]);
        queue.bookings = [_booking(team: 'BLACK')];
        await _show(tester, queue, tick: 1);
        expect(queue.partyReads, previousReads + 1);
        expect(_hero(tester).booking.assignedTeam, 'BLACK');

        if (fails) {
          oldParty.completeError(StateError('Old party lookup failed'));
        } else {
          oldParty.complete(
            const OpenQueuePartyContext(
              gameId: 'game',
              gameStatus: 'OPEN',
              canUseParties: true,
              maxPartySize: 4,
              eligiblePlayers: [],
              receivedInvites: [
                OpenQueuePartyInvite(
                  membershipId: 'old-invite',
                  partyId: 'old-party',
                  invitedAt: null,
                  owner: OpenQueuePartyPlayer(
                    profileId: 'old-owner',
                    displayName: 'Stale inviter',
                    role: OpenQueueRole.attacker,
                  ),
                  acceptedCount: 1,
                  members: [],
                ),
              ],
            ),
          );
        }
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('fieldrush-home-scroll')),
          const Offset(0, -1800),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Stale inviter'), findsNothing);
        expect(
          find.textContaining('Could not refresh party invitations'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

FieldrushSoloHero _hero(WidgetTester tester) =>
    tester.widget<FieldrushSoloHero>(find.byType(FieldrushSoloHero));

Future<void> _show(
  WidgetTester tester,
  _Queue queue, {
  int tick = 0,
  bool enabled = true,
  _Ratings? ratings,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TickerMode(
          enabled: enabled,
          child: DashboardHome(
            activationTick: tick,
            profileRepository: _Profiles(),
            clanRepository: _Clans(),
            fixtureRepository: _Fixtures(),
            leaderboardRepository: ratings ?? _Ratings(),
            openQueueRepository: queue,
            onOpenRanks: () {},
            onOpenClans: () {},
            onOpenFixtures: () {},
            onOpenProfile: () {},
            onNavigateTab: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OpenQueueBooking _booking({
  String? team,
  String status = 'OPEN',
  bool late = false,
}) {
  final now = DateTime.now();
  final game = OpenQueueGame(
    id: 'game',
    status: status,
    venue: 'Phoenix Sports Park',
    startsAt: late
        ? now.subtract(const Duration(minutes: 1))
        : now.add(const Duration(hours: 2)),
    endsAt: now.add(const Duration(hours: 3)),
    timezone: 'America/Phoenix',
    priceFils: 10000,
    currency: 'USD',
    ageLabel: '18+',
    capacity: 14,
    confirmedCount: 12,
    participationRulesVersion: 's0-configurable-v1',
    minimumPlayers: 10,
    spots: const {OpenQueueRole.attacker: 2},
    myBookingId: 'booking',
    myBookingRole: OpenQueueRole.attacker,
    myBookingTeam: team,
    teamAssignmentAt: now.subtract(const Duration(minutes: 1)),
    teamsAssignedAt: team == null ? null : now,
  );
  return OpenQueueBooking(
    id: 'booking',
    gameId: game.id,
    profileId: 'me',
    role: OpenQueueRole.attacker,
    status: 'CONFIRMED',
    team: team,
    amountPaidFils: 10000,
    bookedAt: now.subtract(const Duration(days: 1)),
    game: game,
  );
}

class _Queue extends Fake
    implements OpenQueueRepository, OpenQueuePartyRepository {
  List<OpenQueueBooking> bookings = [_booking()];
  Future<List<OpenQueueBooking>>? nextBookingRead;
  Future<OpenQueuePartyContext>? nextPartyRead;
  int bookingReads = 0;
  int partyReads = 0;
  List<OpenQueueGame> fixtureGames = [];
  Future<List<OpenQueueGame>>? nextFixtureRead;

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() {
    bookingReads++;
    final next = nextBookingRead;
    nextBookingRead = null;
    return next ?? Future.value(bookings);
  }

  @override
  Future<OpenQueuePartyContext> getPartyContext(String gameId) async {
    partyReads++;
    final next = nextPartyRead;
    nextPartyRead = null;
    if (next != null) return next;
    return OpenQueuePartyContext(
      gameId: gameId,
      gameStatus: 'OPEN',
      canUseParties: false,
      maxPartySize: 4,
      receivedInvites: const [],
      eligiblePlayers: const [],
    );
  }

  @override
  Future<List<OpenQueueGame>> listGames() async => [];

  @override
  Future<List<OpenQueueGame>> listFixtureGames() {
    final next = nextFixtureRead;
    nextFixtureRead = null;
    return next ?? Future.value(fixtureGames);
  }
}

class _Profiles extends Fake implements ProfileRepository {
  @override
  Future<PlayerProfile> getCurrentProfile() async => const PlayerProfile(
    id: 'me',
    displayName: 'Dana',
    username: 'dana',
    bio: '',
    followingCount: 0,
    fansCount: 0,
    appearances: 0,
    goals: 0,
    assists: 0,
    highlights: [],
    career: [],
  );
}

class _Ratings extends Fake implements LeaderboardRepository {
  int reads = 0;
  int rating = 1200;
  Future<PlayerRatingLeaderboardEntry>? nextRead;
  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async {
    reads++;
    final pending = nextRead;
    nextRead = null;
    if (pending != null) return pending;
    return PlayerRatingLeaderboardEntry(
      rank: 0,
      profileId: 'me',
      displayName: 'Dana',
      username: 'dana',
      skillRating: rating,
      matchesPlayed: 0,
      wins: 0,
      draws: 0,
      losses: 0,
      lastChange: 0,
      region: 'phoenix',
    );
  }
}

class _Clans extends Fake implements ClanRepository {
  @override
  Future<List<Clan>> listClans() async => [];
  @override
  Future<ClanMembership?> getMyClanMembership() async => null;
}

class _Fixtures extends Fake implements FixtureRepository {
  @override
  Future<List<Fixture>> listFixtures() async => [];
  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;
}
