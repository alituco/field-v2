import 'dart:async';

import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/home/fieldrush_home_widgets.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/open_queue/team_assignment_notice.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final sample in [
    (label: 'unbooked', booked: false, status: 'OPEN', review: false),
    (label: 'live', booked: true, status: 'LIVE', review: false),
    (label: 'final', booked: true, status: 'FINAL', review: false),
    (label: 'cancelled', booked: true, status: 'CANCELLED', review: false),
    (label: 'under review', booked: true, status: 'OPEN', review: true),
  ]) {
    testWidgets('detail hides assignment ticket for ${sample.label} games', (
      tester,
    ) async {
      final game = _game(
        booked: sample.booked,
        status: sample.status,
        review: sample.review,
      );
      final queue = _Queue(game: game, booked: sample.booked);
      await _showDetail(tester, queue);

      expect(find.byType(FieldrushTeamAssignmentNotice), findsNothing);
      expect(
        find.byKey(const ValueKey('team-assignment-see-team')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final team in ['WHITE', 'BLACK']) {
    testWidgets('detail refresh resolves pending assignment to $team', (
      tester,
    ) async {
      final queue = _Queue(game: _game());
      await _showDetail(tester, queue);
      expect(find.byType(FieldrushTeamAssignmentNotice), findsOneWidget);
      expect(find.text('ASSIGNMENT UPDATING'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('team-assignment-see-team')),
        findsNothing,
      );
      final detailReads = queue.detailReads;

      queue.game = _game(team: team);
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();

      expect(queue.detailReads, greaterThan(detailReads));
      final notice = tester.widget<FieldrushTeamAssignmentNotice>(
        find.byType(FieldrushTeamAssignmentNotice),
      );
      expect(notice.team, team);
      expect(notice.game.hasActiveTeamAssignment, isTrue);
      expect(find.text("YOU'RE ON"), findsOneWidget);
      expect(
        find.byKey(const ValueKey('team-assignment-see-team')),
        findsOneWidget,
      );
      expect(find.text('ASSIGNMENT UPDATING'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'Home assignment refresh updates bookings and SR without reloading profile',
    (tester) async {
      final queue = _Queue(game: _game());
      final ratings = _Ratings();
      final profiles = _Profiles();
      await _showHome(tester, queue, ratings: ratings, profiles: profiles);
      expect(find.byType(FieldrushSoloHero), findsOneWidget);
      expect(find.text('ASSIGNMENT UPDATING'), findsOneWidget);
      final bookingReads = queue.bookingReads;
      final ratingReads = ratings.reads;
      final profileReads = profiles.reads;

      queue.game = _game(team: 'BLACK');
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();

      expect(queue.bookingReads, greaterThan(bookingReads));
      expect(ratings.reads, ratingReads + 1);
      expect(profiles.reads, profileReads);
      expect(
        tester
            .widget<FieldrushSoloHero>(find.byType(FieldrushSoloHero))
            .booking
            .assignedTeam,
        'BLACK',
      );
      expect(
        find.byKey(const ValueKey('team-assignment-see-team')),
        findsOneWidget,
      );
      expect(find.text('ASSIGNMENT UPDATING'), findsNothing);
      expect(find.byKey(const Key('home-loading')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Home See team opens its booked game with the lineup in view', (
    tester,
  ) async {
    final queue = _Queue(game: _game(team: 'WHITE'));
    await _showHome(tester, queue);
    final action = find.byKey(const ValueKey('team-assignment-see-team'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
    expect(
      tester
          .widget<FieldrushGameDetailScreen>(
            find.byType(FieldrushGameDetailScreen),
          )
          .gameId,
      queue.game.id,
    );
    expect(find.text('LOBBY AVERAGE').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('detail See team scrolls to the lineup without another route', (
    tester,
  ) async {
    final queue = _Queue(game: _game(team: 'BLACK'));
    await _showDetail(tester, queue);
    final action = find.byKey(const ValueKey('team-assignment-see-team'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
    expect(find.text('LOBBY AVERAGE').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('initial lineup focus does not wait for booking enrichment', (
    tester,
  ) async {
    final response = Completer<List<OpenQueueBooking>>();
    final queue = _Queue(game: _game(team: 'WHITE'))
      ..bookingResponse = response.future;
    await _show(
      tester,
      FieldrushGameDetailScreen(
        repository: queue,
        gameId: queue.game.id,
        initiallyFocusLineup: true,
      ),
    );

    expect(response.isCompleted, isFalse);
    expect(find.text('LOBBY AVERAGE').hitTestable(), findsOneWidget);
    expect(find.text('Loading lineup'), findsNothing);
    expect(tester.takeException(), isNull);

    response.complete([queue.booking]);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'See team reaches an offscreen lineup on short screens at 2x text',
    (tester) async {
      final queue = _Queue(game: _game(team: 'BLACK'));
      await _show(
        tester,
        FieldrushGameDetailScreen(repository: queue, gameId: queue.game.id),
        height: 568,
        textScale: 2,
      );
      expect(find.text('LOBBY AVERAGE').hitTestable(), findsNothing);

      final action = find.byKey(const ValueKey('team-assignment-see-team'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();

      expect(find.text('LOBBY AVERAGE').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'fresh detail side wins during a same-booking rebalance lookup failure',
    (tester) async {
      final queue = _Queue(game: _game(team: 'WHITE'));
      await _showDetail(tester, queue);
      expect(
        tester
            .widget<FieldrushTeamAssignmentNotice>(
              find.byType(FieldrushTeamAssignmentNotice),
            )
            .team,
        'WHITE',
      );
      final previousBookingId = queue.booking.id;
      final response = Completer<List<OpenQueueBooking>>();
      queue
        ..game = _game(team: 'BLACK')
        ..bookingResponse = response.future;
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();

      expect(queue.booking.id, previousBookingId);
      expect(response.isCompleted, isFalse);
      expect(
        tester
            .widget<FieldrushTeamAssignmentNotice>(
              find.byType(FieldrushTeamAssignmentNotice),
            )
            .team,
        'BLACK',
      );

      response.completeError(StateError('Booking enrichment unavailable'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FieldrushTeamAssignmentNotice>(
              find.byType(FieldrushTeamAssignmentNotice),
            )
            .team,
        'BLACK',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stalled enrichment times out so later detail polling can recover',
    (tester) async {
      final response = Completer<List<OpenQueueBooking>>();
      final queue = _Queue(game: _game(team: 'WHITE'))
        ..bookingResponse = response.future;
      await _showDetail(tester, queue);
      final detailReads = queue.detailReads;
      queue
        ..game = _game(team: 'BLACK')
        ..bookingResponse = null;

      // Release the optional read's bound first, then reach the next poll.
      await tester.pump(const Duration(seconds: 12));
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(queue.detailReads, greaterThan(detailReads));
      expect(
        tester
            .widget<FieldrushTeamAssignmentNotice>(
              find.byType(FieldrushTeamAssignmentNotice),
            )
            .team,
        'BLACK',
      );
      expect(response.isCompleted, isFalse);
      expect(tester.takeException(), isNull);
      response.complete([]);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Future<void> _showDetail(WidgetTester tester, _Queue queue) => _show(
  tester,
  FieldrushGameDetailScreen(repository: queue, gameId: queue.game.id),
);

Future<void> _showHome(
  WidgetTester tester,
  _Queue queue, {
  _Ratings? ratings,
  _Profiles? profiles,
}) => _show(
  tester,
  Scaffold(
    body: DashboardHome(
      profileRepository: profiles ?? _Profiles(),
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
);

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  double height = 844,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(390, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

OpenQueueGame _game({
  bool booked = true,
  String status = 'OPEN',
  bool review = false,
  String? team,
}) {
  final now = DateTime.now();
  return OpenQueueGame(
    id: 'game',
    status: status,
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
    myBookingId: booked ? 'booking' : null,
    myBookingRole: booked ? OpenQueueRole.attacker : null,
    myBookingTeam: team,
    teamAssignmentAt: now.subtract(const Duration(minutes: 1)),
    teamsAssignedAt: team == null ? null : now,
    operationalState: review
        ? MatchOperationalState.underReview
        : MatchOperationalState.normal,
  );
}

class _Queue extends Fake implements OpenQueueRepository {
  _Queue({required this.game, this.booked = true});
  OpenQueueGame game;
  final bool booked;
  Future<List<OpenQueueBooking>>? bookingResponse;
  int bookingReads = 0;
  int detailReads = 0;

  OpenQueueBooking get booking => OpenQueueBooking(
    id: 'booking',
    gameId: game.id,
    profileId: 'me',
    role: OpenQueueRole.attacker,
    status: 'CONFIRMED',
    team: game.myBookingTeam,
    amountPaidFils: 10000,
    bookedAt: DateTime.now().subtract(const Duration(days: 1)),
    game: game,
  );

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async {
    detailReads++;
    return OpenQueueMatchDetail(
      game: game,
      scorers: const [],
      timeline: const [],
      players: [
        if (booked)
          OpenQueuePlayer(
            id: 'me',
            displayName: 'Dana',
            role: OpenQueueRole.attacker,
            team: game.myBookingTeam ?? '',
            played: false,
            isMe: true,
          ),
      ],
    );
  }

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async {
    bookingReads++;
    if (bookingResponse != null) return bookingResponse!;
    return [if (booked) booking];
  }

  @override
  Future<List<OpenQueueGame>> listGames() async => [];

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => [];
}

class _Profiles extends Fake implements ProfileRepository {
  int reads = 0;
  @override
  Future<PlayerProfile> getCurrentProfile() async {
    reads++;
    return const PlayerProfile(
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
}

class _Ratings extends Fake implements LeaderboardRepository {
  int reads = 0;
  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async {
    reads++;
    return const PlayerRatingLeaderboardEntry(
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
