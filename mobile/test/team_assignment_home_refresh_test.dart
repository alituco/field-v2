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
            leaderboardRepository: _Ratings(),
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

OpenQueueBooking _booking({String? team}) {
  final now = DateTime.now();
  final game = OpenQueueGame(
    id: 'game',
    status: 'OPEN',
    venue: 'Phoenix Sports Park',
    startsAt: now.add(const Duration(hours: 2)),
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
  Future<List<OpenQueueGame>> listFixtureGames() async => [];
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
  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async => const PlayerRatingLeaderboardEntry(
    rank: 0,
    profileId: 'me',
    displayName: 'Dana',
    username: 'dana',
    skillRating: 1200,
    matchesPlayed: 0,
    wins: 0,
    draws: 0,
    losses: 0,
    lastChange: 0,
    region: 'phoenix',
  );
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
