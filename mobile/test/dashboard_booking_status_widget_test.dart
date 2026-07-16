import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
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
  testWidgets('home booking card shows pending count and a prominent TODAY', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _game(
      daysFromToday: 0,
      confirmedCount: 8,
      staleAssignment: true,
    );

    await _pumpDashboard(tester, game, team: openQueueWhiteTeamId);

    expect(find.text('MATCH PENDING'), findsOneWidget);
    expect(find.text('8 / 12 CONFIRMED'), findsOneWidget);
    expect(find.text('MATCH CONFIRMED'), findsNothing);
    expect(find.text('Midfielder · 8:30 PM'), findsOneWidget);
    expect(find.textContaining('TODAY ·'), findsOneWidget);
    expect(find.text('TFA, Saar'), findsOneWidget);
    expect(find.byKey(const ValueKey('kit-instruction')), findsNothing);
    expect(find.byKey(const ValueKey('kit-assignment-updating')), findsNothing);
    expect(find.textContaining('WHITE ·'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full home booking card shows confirmed count and TOMORROW', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _game(daysFromToday: 1, confirmedCount: 12);

    await _pumpDashboard(tester, game, team: openQueueBlackTeamId);

    expect(find.text('MATCH CONFIRMED'), findsOneWidget);
    expect(find.text('12 / 12 CONFIRMED'), findsOneWidget);
    expect(find.text('MATCH PENDING'), findsNothing);
    expect(find.textContaining('TOMORROW ·'), findsOneWidget);
    expect(find.text('WEAR BLACK'), findsOneWidget);
    expect(find.byKey(const ValueKey('kit-instruction')), findsOneWidget);
    final card = tester.getRect(
      find.byKey(const ValueKey('home-solo-booking-booking')),
    );
    final action = tester.getRect(find.text('View booking  ›'));
    expect(card.bottom - action.bottom, lessThanOrEqualTo(34));
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmed home booking never guesses a missing kit color', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _game(daysFromToday: 2, confirmedCount: 12);

    await _pumpDashboard(tester, game);

    expect(find.text('MATCH CONFIRMED'), findsOneWidget);
    expect(find.text('KIT ASSIGNMENT UPDATING'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('kit-assignment-updating')),
      findsOneWidget,
    );
    expect(find.text('WEAR WHITE'), findsNothing);
    expect(find.text('WEAR BLACK'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one solo booking offers a second-game carousel page', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _game(daysFromToday: 2, confirmedCount: 8);

    await _pumpHome(tester, booking: _bookingFor(game));

    expect(find.text('YOUR SOLO GAMES'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-solo-carousel-page-1')),
      findsOneWidget,
    );
    expect(find.text('MATCH PENDING').hitTestable(), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('home-solo-bookings-carousel')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('home-solo-carousel-page-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-book-another-solo-game')),
      findsOneWidget,
    );
    expect(find.text('REGISTER FOR A SECOND GAME'), findsOneWidget);
    expect(find.text('FIND A GAME'), findsOneWidget);

    await tester.tap(find.text('REGISTER FOR A SECOND GAME'));
    await tester.pumpAndSettle();

    expect(find.text('OPEN QUEUE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no solo bookings preserves the Find Game hero', (tester) async {
    await _setPhoneSize(tester);

    await _pumpHome(tester);

    expect(find.text('READY FOR A MATCH?'), findsOneWidget);
    expect(find.text('FIND A GAME'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-solo-bookings-section')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('two solo bookings are kickoff ordered and individually open', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final today = _bahrainDateNow();
    final earlierGame = _fixtureGame(
      id: 'booked-earlier',
      date: today.add(const Duration(days: 2)),
      status: 'OPEN',
      confirmedCount: 8,
      myBookingId: 'booking-earlier',
      myBookingRole: OpenQueueRole.defender,
    );
    final laterGame = _fixtureGame(
      id: 'booked-later',
      date: today.add(const Duration(days: 5)),
      status: 'OPEN',
      confirmedCount: 9,
      myBookingId: 'booking-later',
      myBookingRole: OpenQueueRole.attacker,
    );
    final earlierBooking = _bookingFor(earlierGame);
    final laterBooking = _bookingFor(laterGame, role: OpenQueueRole.attacker);

    await _pumpHome(
      tester,
      booking: laterBooking,
      additionalBookings: [earlierBooking],
    );

    final earlierCard = find.byKey(
      ValueKey('home-solo-booking-${earlierBooking.id}'),
    );
    final laterCard = find.byKey(
      ValueKey('home-solo-booking-${laterBooking.id}'),
    );
    expect(find.text('YOUR SOLO GAMES'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-solo-carousel-page-1')),
      findsOneWidget,
    );
    expect(earlierCard, findsOneWidget);
    expect(earlierCard.hitTestable(), findsOneWidget);
    expect(laterCard.hitTestable(), findsNothing);
    expect(
      find.byKey(const ValueKey('home-book-another-solo-game')),
      findsNothing,
    );

    await tester.tap(earlierCard);
    await tester.pumpAndSettle();
    expect(find.text('BOOKING DETAILS'), findsOneWidget);
    expect(find.text(earlierGame.prominentDateLabel), findsOneWidget);

    Navigator.of(tester.element(find.text('BOOKING DETAILS'))).pop();
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('home-solo-bookings-carousel')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('home-solo-carousel-page-2')),
      findsOneWidget,
    );
    expect(earlierCard.hitTestable(), findsNothing);
    expect(laterCard.hitTestable(), findsOneWidget);

    await tester.tap(laterCard.hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('BOOKING DETAILS'), findsOneWidget);
    expect(find.text(laterGame.prominentDateLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending party invite is prominent and opens its booking details',
    (tester) async {
      await _setPhoneSize(tester);
      final game = _game(daysFromToday: 2, confirmedCount: 8);
      final booking = _bookingFor(game);
      final partyContext = _partyContextWithInvite(game);

      await _pumpHome(tester, booking: booking, partyContext: partyContext);

      final alert = find.byKey(ValueKey('home-party-invite-${game.id}'));
      expect(alert, findsOneWidget);
      expect(find.text('PARTY INVITE WAITING'), findsOneWidget);
      expect(find.text('Sami Nasser wants to team up'), findsOneWidget);
      expect(find.text('REVIEW'), findsOneWidget);
      expect(
        tester.getTopLeft(alert).dy,
        lessThan(tester.getTopLeft(find.text('MATCH PENDING')).dy),
      );

      await tester.tap(alert);
      await tester.pumpAndSettle();

      expect(find.text('BOOKING DETAILS'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('open-queue-party-invite')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('party invite alert remains visible while already grouped', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _game(daysFromToday: 3, confirmedCount: 8);
    final partyContext = _partyContextWithInvite(
      game,
      myParty: const OpenQueueParty(
        id: 'my-current-party',
        ownerProfileId: 'profile',
        isOwner: true,
        acceptedCount: 1,
        members: [],
      ),
    );

    await _pumpHome(
      tester,
      booking: _bookingFor(game),
      partyContext: partyContext,
    );

    final alert = find.byKey(ValueKey('home-party-invite-${game.id}'));
    expect(alert, findsOneWidget);

    await tester.tap(alert);
    await tester.pumpAndSettle();

    expect(find.text('BOOKING DETAILS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'notification opens the invited game when another booking is first',
    (tester) async {
      await _setPhoneSize(tester);
      final firstGame = _game(daysFromToday: 1, confirmedCount: 8);
      final invitedGame = _game(daysFromToday: 4, confirmedCount: 8);
      final invitedBooking = _bookingFor(invitedGame);
      final repository = _NotificationOpenQueueRepository(
        _bookingFor(firstGame),
        inviteBooking: invitedBooking,
        notification: OpenQueuePartyInviteNotification(
          id: 'notification-one',
          gameId: invitedGame.id,
          partyId: 'party-one',
          membershipId: 'invite-one',
          createdAt: DateTime.now(),
          isRead: false,
          inviter: const OpenQueuePartyNotificationInviter(
            profileId: 'sami',
            displayName: 'Sami Nasser',
            username: 'sami',
          ),
          gameStartsAt: invitedGame.startsAt,
          venue: invitedGame.venue,
          gameStatus: invitedGame.status,
        ),
        partyContext: _partyContextWithInvite(invitedGame),
      );

      await _pumpHome(tester, openQueueRepository: repository);

      final alert = find.byKey(ValueKey('home-party-invite-${invitedGame.id}'));
      expect(alert, findsOneWidget);

      await tester.tap(alert);
      await tester.pumpAndSettle();

      expect(repository.markedNotificationIds, ['notification-one']);
      expect(find.text('BOOKING DETAILS'), findsOneWidget);
      expect(find.text(invitedGame.prominentDateLabel), findsWidgets);
      expect(
        find.byKey(const ValueKey('open-queue-party-invite')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'matchday shows up next before recent and caps the feed at three',
    (tester) async {
      await _setPhoneSize(tester);
      final today = _bahrainDateNow();
      final openedFixtures = ValueNotifier(false);
      addTearDown(openedFixtures.dispose);
      final upcomingOne = _fixtureGame(
        id: 'upcoming-one',
        date: today.add(const Duration(days: 2)),
        status: 'OPEN',
        confirmedCount: 8,
      );
      final upcomingTwo = _fixtureGame(
        id: 'upcoming-two',
        date: today.add(const Duration(days: 3)),
        status: 'OPEN',
        confirmedCount: 8,
      );
      final upcomingThree = _fixtureGame(
        id: 'upcoming-three',
        date: today.add(const Duration(days: 4)),
        status: 'OPEN',
        confirmedCount: 8,
      );
      final recentOne = _fixtureGame(
        id: 'recent-one',
        date: today.subtract(const Duration(days: 1)),
        status: 'FINAL',
      );
      final recentTwo = _fixtureGame(
        id: 'recent-two',
        date: today.subtract(const Duration(days: 2)),
        status: 'FINAL',
      );

      await _pumpHome(
        tester,
        soloGames: [
          upcomingThree,
          recentTwo,
          upcomingTwo,
          recentOne,
          upcomingOne,
        ],
        onOpenFixtures: () => openedFixtures.value = true,
      );
      await tester.scrollUntilVisible(
        find.text('MATCHDAY'),
        300,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('MATCHDAY'), findsOneWidget);
      expect(find.text('All matches'), findsOneWidget);
      expect(find.text('ACTIVITY'), findsNothing);
      expect(find.text('NEXT MATCHDAY'), findsNothing);
      expect(find.text('LAST MATCHDAY'), findsNothing);
      expect(
        find.byKey(const ValueKey('home-matchday-up-next')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-matchday-recent')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('UP NEXT')).dy,
        lessThan(tester.getTopLeft(find.text('RECENT')).dy),
      );
      expect(
        find.byKey(const ValueKey('home-activity-solo-upcoming-one')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-activity-solo-upcoming-two')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-activity-solo-recent-one')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-activity-solo-upcoming-three')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-activity-solo-recent-two')),
        findsNothing,
      );
      expect(_homeActivityRows(), findsNWidgets(3));

      await tester.tap(find.text('All matches'));
      await tester.pump();
      expect(openedFixtures.value, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('matchday omits the solo game already shown in booking hero', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final today = _bahrainDateNow();
    final bookedGame = _fixtureGame(
      id: 'booked-game',
      date: today.add(const Duration(days: 2)),
      status: 'OPEN',
      confirmedCount: 8,
    );
    final nextGame = _fixtureGame(
      id: 'next-available-game',
      date: today.add(const Duration(days: 3)),
      status: 'OPEN',
      confirmedCount: 7,
    );

    await _pumpHome(
      tester,
      booking: _bookingFor(bookedGame),
      soloGames: [bookedGame, nextGame],
    );
    await tester.scrollUntilVisible(
      find.text('MATCHDAY'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('MATCH PENDING'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-activity-solo-booked-game')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('home-activity-solo-next-available-game')),
      findsOneWidget,
    );
    expect(_homeActivityRows(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('open solo match uses exact spots-left copy and join flow', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _fixtureGame(
      id: 'joinable-game',
      date: _bahrainDateNow().add(const Duration(days: 2)),
      status: 'OPEN',
      confirmedCount: 8,
      venue: '[SCHEDULE SEED] Solo Future 1',
    );

    await _pumpHome(tester, soloGames: [game]);

    final joinCta = find.byKey(
      const ValueKey('home-activity-join-joinable-game'),
    );
    await tester.scrollUntilVisible(
      joinCta,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Solo match · 4 spots left'), findsOneWidget);
    expect(find.text('JOIN'), findsOneWidget);
    expect(find.textContaining('8/12 JOINED'), findsNothing);
    expect(find.text(game.timeLabel), findsOneWidget);
    expect(find.text('Solo Future 1'), findsOneWidget);
    expect(find.textContaining('[SCHEDULE SEED]'), findsNothing);
    final headline = find.text('Solo match · 4 spots left');
    final time = find.text(game.timeLabel);
    final venue = find.text('Solo Future 1');
    expect(tester.widget<Text>(headline).style?.fontSize, 15);
    expect(
      tester.getTopLeft(headline).dy,
      lessThan(tester.getTopLeft(time).dy),
    );
    expect(tester.getTopLeft(time).dy, lessThan(tester.getTopLeft(venue).dy));

    await tester.drag(find.byType(ListView).first, const Offset(0, -100));
    await tester.pump();
    await tester.tap(joinCta);
    await tester.pumpAndSettle();
    expect(find.text('AVAILABLE SPOTS'), findsOneWidget);
    expect(find.text('8 of 12 confirmed'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('scored future game is recent and shows the player SR change', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final today = _bahrainDateNow();
    final scoredFutureGame = _fixtureGame(
      id: 'scored-future-game',
      date: today.add(const Duration(days: 10)),
      status: 'OPEN',
      confirmedCount: 8,
      whiteScore: 5,
      blackScore: 3,
    );
    final genuinelyUpcomingGame = _fixtureGame(
      id: 'genuinely-upcoming-game',
      date: today.add(const Duration(days: 2)),
      status: 'OPEN',
      confirmedCount: 8,
    );
    final previousGame = ProfilePreviousGame(
      id: scoredFutureGame.id,
      type: ProfileGameType.solo,
      playedAt: scoredFutureGame.startsAt,
      venue: scoredFutureGame.venue,
      homeName: 'White Team',
      homeTag: 'WHITE',
      homeEmblem: '⚪',
      awayName: 'Black Team',
      awayTag: 'BLACK',
      awayEmblem: '⚫',
      homeScore: 5,
      awayScore: 3,
      playerSide: 'WHITE',
      playerRole: 'DEF',
    );
    final ratingEvent = ProfileRatingEvent(
      id: 'rating-event',
      sourceType: 'OPEN_QUEUE',
      sourceId: scoredFutureGame.id,
      playedAt: scoredFutureGame.startsAt,
      opponentLabel: 'Black Team',
      side: 'WHITE',
      result: 'WIN',
      ratingBefore: 1200,
      ratingChange: 18,
      ratingAfter: 1218,
    );
    final profile = _profileWithMatch(
      previousGame: previousGame,
      ratingEvent: ratingEvent,
    );
    final detail = OpenQueueMatchDetail(
      game: scoredFutureGame,
      scorers: const [],
      timeline: const [],
      players: const [],
    );

    await _pumpHome(
      tester,
      profile: profile,
      soloGames: [scoredFutureGame, genuinelyUpcomingGame],
      matchDetails: {scoredFutureGame.id: detail},
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('home-matchday-recent')),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    final scoredRow = find.byKey(
      const ValueKey('home-activity-solo-scored-future-game'),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home-matchday-recent')),
        matching: scoredRow,
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home-matchday-up-next')),
        matching: scoredRow,
      ),
      findsNothing,
    );
    expect(find.textContaining('YOUR RESULT'), findsOneWidget);
    expect(find.textContaining('+18 SR'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-activity-join-scored-future-game')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact empty clan summary sits below Matchday', (tester) async {
    await _setPhoneSize(tester);
    final game = _fixtureGame(
      id: 'matchday-before-clan',
      date: _bahrainDateNow().add(const Duration(days: 2)),
      status: 'OPEN',
      confirmedCount: 8,
    );

    await _pumpHome(
      tester,
      soloGames: [game],
      clans: const [_testClan],
      clanMembership: const ClanMembership(clanId: 'home', role: 'member'),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('home-clan-summary-compact')),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(
      find.byKey(const ValueKey('home-clan-summary-compact')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('home-clan-compact')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-clan-summary-expanded')),
      findsNothing,
    );
    expect(find.text(_testClan.name), findsOneWidget);
    expect(find.text('No upcoming fixture'), findsNothing);
    expect(find.text('View Clan'), findsNothing);
    expect(
      tester.getTopLeft(find.text('MATCHDAY')).dy,
      lessThan(tester.getTopLeft(find.text('YOUR CLAN')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('replay-ready clan result shows highlights and opens Watch', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final streamStartedAt = DateTime.utc(2026, 7, 10, 16);
    final fixture = _clanFixture(
      id: 'clan-highlights',
      date: _bahrainDateNow().subtract(const Duration(days: 1)),
      status: FixtureStatus.finalResult,
      homeScore: 2,
      awayScore: 1,
      broadcast: FixtureBroadcast(
        status: 'REPLAY_READY',
        replayHlsUrl: 'https://example.com/clan-highlights.m3u8',
        streamStartedAt: streamStartedAt,
        streamStoppedAt: streamStartedAt.add(const Duration(hours: 1)),
      ),
      timeline: [
        _goalEvent(
          id: 'first-goal',
          minute: 12,
          occurredAt: streamStartedAt.add(const Duration(minutes: 12)),
        ),
        _goalEvent(
          id: 'second-goal',
          minute: 38,
          occurredAt: streamStartedAt.add(const Duration(minutes: 38)),
        ),
      ],
    );

    await _pumpHome(tester, fixtures: [fixture]);
    final resultRow = find.byKey(
      const ValueKey('home-activity-clan-clan-highlights'),
    );
    await tester.scrollUntilVisible(
      resultRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.textContaining('2 highlights ready'), findsOneWidget);
    expect(find.text('WATCH'), findsOneWidget);

    await tester.drag(find.byType(ListView).first, const Offset(0, -90));
    await tester.pump();
    await tester.tap(resultRow);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('fixture-section-watch')), findsOneWidget);
    expect(find.text('WATCH MATCH'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Disposes the video retry timer created by the unavailable test URL.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('only a valid future clan fixture expands the clan summary', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final today = _bahrainDateNow();
    final pastFixture = _clanFixture(
      id: 'past-clan-fixture',
      date: today.subtract(const Duration(days: 1)),
      status: FixtureStatus.scheduled,
    );
    final scoredStaleFixture = _clanFixture(
      id: 'scored-stale-clan-fixture',
      date: today.add(const Duration(days: 2)),
      status: FixtureStatus.scheduled,
      homeScore: 3,
      awayScore: 1,
    );
    final validFutureFixture = _clanFixture(
      id: 'valid-future-clan-fixture',
      date: today.add(const Duration(days: 5)),
      status: FixtureStatus.scheduled,
    );
    final joinableSolo = _fixtureGame(
      id: 'joinable-below-clan',
      date: today.add(const Duration(days: 2)),
      status: 'OPEN',
      confirmedCount: 8,
    );

    await _pumpHome(
      tester,
      fixtures: [pastFixture, scoredStaleFixture, validFutureFixture],
      soloGames: [joinableSolo],
      clans: const [_testClan],
      clanMembership: const ClanMembership(clanId: 'home', role: 'member'),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('home-clan-summary-expanded')),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(
      find.byKey(const ValueKey('home-clan-summary-expanded')),
      findsOneWidget,
    );
    expect(find.text('UPCOMING CLAN FIXTURE'), findsOneWidget);
    expect(find.text('vs Away Clan'), findsOneWidget);
    final upNext = find.byKey(const ValueKey('home-matchday-up-next'));
    final clanCard = find.byKey(const ValueKey('home-clan-summary-expanded'));
    final soloRow = find.byKey(
      const ValueKey('home-activity-solo-joinable-below-clan'),
    );
    expect(find.descendant(of: upNext, matching: clanCard), findsOneWidget);
    expect(find.descendant(of: upNext, matching: soloRow), findsOneWidget);
    expect(
      tester.getTopLeft(clanCard).dy,
      lessThan(tester.getTopLeft(soloRow).dy),
    );
    expect(
      find.byKey(
        const ValueKey('home-activity-clan-valid-future-clan-fixture'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('home-clan-summary-compact')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await _pumpHome(
      tester,
      fixtures: [pastFixture, scoredStaleFixture],
      clans: const [_testClan],
      clanMembership: const ClanMembership(clanId: 'home', role: 'member'),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('home-clan-summary-compact')),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(
      find.byKey(const ValueKey('home-clan-summary-compact')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-clan-summary-expanded')),
      findsNothing,
    );
    expect(find.text('UPCOMING CLAN FIXTURE'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setPhoneSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  OpenQueueGame game, {
  String? team,
}) async {
  final booking = OpenQueueBooking(
    id: 'booking',
    gameId: game.id,
    profileId: 'profile',
    role: OpenQueueRole.midfielder,
    status: 'CONFIRMED',
    amountPaidFils: game.priceFils,
    bookedAt: DateTime.now(),
    team: team,
    game: game,
  );
  await _pumpHome(tester, booking: booking);
}

Future<void> _pumpHome(
  WidgetTester tester, {
  PlayerProfile profile = _defaultProfile,
  OpenQueueBooking? booking,
  List<OpenQueueGame> soloGames = const [],
  Map<String, OpenQueueMatchDetail> matchDetails = const {},
  List<Fixture> fixtures = const [],
  List<Clan> clans = const [],
  ClanMembership? clanMembership,
  VoidCallback? onOpenFixtures,
  OpenQueuePartyContext? partyContext,
  OpenQueueRepository? openQueueRepository,
  List<OpenQueueBooking> additionalBookings = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DashboardHome(
          profileRepository: _FakeProfileRepository(profile),
          clanRepository: _FakeClanRepository(
            clans: clans,
            membership: clanMembership,
          ),
          fixtureRepository: _FakeFixtureRepository(fixtures),
          leaderboardRepository: const _FakeLeaderboardRepository(),
          openQueueRepository:
              openQueueRepository ??
              _FakeOpenQueueRepository(
                booking,
                fixtureGames: soloGames,
                matchDetails: matchDetails,
                partyContext: partyContext,
                additionalBookings: additionalBookings,
              ),
          onOpenClans: () {},
          onOpenFixtures: onOpenFixtures ?? () {},
          onOpenRanks: () {},
          onOpenProfile: () {},
          onNavigateTab: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _homeActivityRows() {
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    if (key is! ValueKey<String>) return false;
    return key.value.startsWith('home-activity-solo-') ||
        key.value.startsWith('home-activity-clan-');
  });
}

OpenQueueBooking _bookingFor(
  OpenQueueGame game, {
  OpenQueueRole role = OpenQueueRole.defender,
}) {
  return OpenQueueBooking(
    id: 'booking-${game.id}',
    gameId: game.id,
    profileId: 'profile',
    role: role,
    status: 'CONFIRMED',
    amountPaidFils: game.priceFils,
    bookedAt: DateTime.now(),
    game: game,
  );
}

OpenQueuePartyContext _partyContextWithInvite(
  OpenQueueGame game, {
  OpenQueueParty? myParty,
}) {
  const owner = OpenQueuePartyPlayer(
    profileId: 'sami',
    displayName: 'Sami Nasser',
    username: 'sami',
    role: OpenQueueRole.defender,
  );
  return OpenQueuePartyContext(
    gameId: game.id,
    gameStatus: game.status,
    canUseParties: true,
    maxPartySize: 4,
    receivedInvites: const [
      OpenQueuePartyInvite(
        membershipId: 'invite-one',
        partyId: 'party-one',
        invitedAt: null,
        owner: owner,
        acceptedCount: 1,
        members: [],
      ),
    ],
    eligiblePlayers: const [],
    myParty: myParty,
  );
}

PlayerProfile _profileWithMatch({
  required ProfilePreviousGame previousGame,
  required ProfileRatingEvent ratingEvent,
}) {
  return PlayerProfile(
    id: 'profile',
    displayName: 'Dana Alawi',
    username: 'dana',
    bio: '',
    followingCount: 0,
    fansCount: 0,
    appearances: 1,
    goals: 0,
    assists: 0,
    highlights: const [],
    career: const [],
    previousGames: [previousGame],
    playerRating: ProfilePlayerRating(
      skillRating: ratingEvent.ratingAfter,
      matchesPlayed: 1,
      wins: 1,
      losses: 0,
      draws: 0,
      lastChange: ratingEvent.ratingChange,
      region: 'bahrain',
      events: [ratingEvent],
    ),
  );
}

OpenQueueGame _game({
  required int daysFromToday,
  required int confirmedCount,
  bool staleAssignment = false,
}) {
  final nowInBahrain = DateTime.now().toUtc().add(const Duration(hours: 3));
  final bahrainStart = DateTime.utc(
    nowInBahrain.year,
    nowInBahrain.month,
    nowInBahrain.day + daysFromToday,
    20,
    30,
  );
  final startsAt = bahrainStart.subtract(const Duration(hours: 3));
  final hasAssignmentMetadata = confirmedCount == 12 || staleAssignment;
  return OpenQueueGame(
    id: 'game-$daysFromToday-$confirmedCount',
    status: confirmedCount == 12 ? 'FULL' : 'OPEN',
    venue: 'TFA, Saar',
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: 'Ages 16-20',
    capacity: 12,
    confirmedCount: confirmedCount,
    spots: const {},
    whiteAverageSr: hasAssignmentMetadata ? 1200 : null,
    blackAverageSr: hasAssignmentMetadata ? 1200 : null,
    matchAverageSr: hasAssignmentMetadata ? 1200 : null,
    teamSrSpread: hasAssignmentMetadata ? 0 : null,
    teamsAssignedAt: hasAssignmentMetadata ? DateTime.now() : null,
  );
}

DateTime _bahrainDateNow() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 3));
  return DateTime(now.year, now.month, now.day);
}

OpenQueueGame _fixtureGame({
  required String id,
  required DateTime date,
  required String status,
  int confirmedCount = 12,
  int capacity = 12,
  int? whiteScore,
  int? blackScore,
  String? myBookingId,
  OpenQueueRole? myBookingRole,
  String? myBookingTeam,
  String venue = 'TFA, Saar',
}) {
  final startsAt = DateTime.utc(date.year, date.month, date.day, 17, 30);
  return OpenQueueGame(
    id: id,
    status: status,
    venue: venue,
    startsAt: startsAt,
    endsAt: startsAt.add(const Duration(hours: 1)),
    timezone: 'Asia/Bahrain',
    priceFils: 3000,
    ageLabel: 'Ages 16-20',
    capacity: capacity,
    confirmedCount: confirmedCount,
    spots: status == 'OPEN'
        ? const {
            OpenQueueRole.goalkeeper: 1,
            OpenQueueRole.defender: 1,
            OpenQueueRole.midfielder: 1,
            OpenQueueRole.attacker: 1,
          }
        : const {},
    whiteScore: whiteScore ?? (status == 'FINAL' ? 4 : null),
    blackScore: blackScore ?? (status == 'FINAL' ? 3 : null),
    myBookingId: myBookingId,
    myBookingRole: myBookingRole,
    myBookingTeam: myBookingTeam,
  );
}

Fixture _clanFixture({
  required String id,
  required DateTime date,
  required FixtureStatus status,
  int? homeScore,
  int? awayScore,
  FixtureBroadcast? broadcast,
  List<FixtureTimelineEvent> timeline = const [],
}) {
  return Fixture(
    id: id,
    status: status,
    homeClanId: _homeFixtureClan.id,
    awayClanId: _awayFixtureClan.id,
    venue: 'TFA, Saar',
    day: _weekday(date.weekday),
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: date,
    createdBy: 'owner',
    homeClan: _homeFixtureClan,
    awayClan: _awayFixtureClan,
    homeScore: homeScore,
    awayScore: awayScore,
    broadcast: broadcast,
    timeline: timeline,
  );
}

FixtureTimelineEvent _goalEvent({
  required String id,
  required int minute,
  required DateTime occurredAt,
}) {
  return FixtureTimelineEvent(
    id: id,
    fixtureId: 'clan-highlights',
    eventType: 'GOAL',
    clanId: _homeFixtureClan.id,
    minute: minute,
    second: 0,
    createdAt: occurredAt,
    occurredAt: occurredAt,
  );
}

String _weekday(int weekday) {
  return const [
    'MONDAY',
    'TUESDAY',
    'WEDNESDAY',
    'THURSDAY',
    'FRIDAY',
    'SATURDAY',
    'SUNDAY',
  ][weekday - 1];
}

const _homeFixtureClan = FixtureClan(
  id: 'home',
  name: 'Home Clan',
  tag: 'HOME',
  emblem: '⚡',
  themeId: 'mint',
  patternId: 'solid',
  skillRating: 1200,
);

const _awayFixtureClan = FixtureClan(
  id: 'away',
  name: 'Away Clan',
  tag: 'AWAY',
  emblem: '🛡️',
  themeId: 'shadow',
  patternId: 'solid',
  skillRating: 1200,
);

const _testClan = Clan(
  id: 'home',
  name: 'Home Clan',
  tag: 'HOME',
  motto: 'Play together',
  emblem: '⚡',
  themeId: 'mint',
  patternId: 'solid',
  skillRating: 1200,
  wins: 2,
  losses: 1,
  memberCount: 12,
  createdBy: 'owner',
);

const _defaultProfile = PlayerProfile(
  id: 'profile',
  displayName: 'Dana Alawi',
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

class _FakeProfileRepository implements ProfileRepository {
  const _FakeProfileRepository([this.profile = _defaultProfile]);

  final PlayerProfile profile;

  @override
  Future<PlayerProfile> getCurrentProfile() async => profile;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLeaderboardRepository implements LeaderboardRepository {
  const _FakeLeaderboardRepository();

  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async => const PlayerRatingLeaderboardEntry(
    rank: 0,
    profileId: 'profile',
    displayName: 'Dana Alawi',
    username: 'dana',
    skillRating: 1200,
    matchesPlayed: 0,
    wins: 0,
    losses: 0,
    draws: 0,
    lastChange: 0,
    region: 'bahrain',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOpenQueueRepository
    implements
        OpenQueueRepository,
        OpenQueuePartyRepository,
        OpenQueueBookingLookupRepository {
  const _FakeOpenQueueRepository(
    this.booking, {
    this.fixtureGames = const [],
    this.matchDetails = const {},
    this.partyContext,
    this.additionalBookings = const [],
  });

  final OpenQueueBooking? booking;
  final List<OpenQueueGame> fixtureGames;
  final Map<String, OpenQueueMatchDetail> matchDetails;
  final OpenQueuePartyContext? partyContext;
  final List<OpenQueueBooking> additionalBookings;

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async => booking;

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async {
    final bookings = [
      if (booking case final value?) value,
      ...additionalBookings,
    ]..sort((left, right) => left.game.startsAt.compareTo(right.game.startsAt));
    return bookings;
  }

  @override
  Future<List<OpenQueueGame>> listGames() async => [
    if (booking case final value?) value.game,
    for (final value in additionalBookings) value.game,
  ];

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => fixtureGames;

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async =>
      matchDetails[gameId]!;

  @override
  Future<OpenQueuePartyContext> getPartyContext(String gameId) async {
    return partyContext ??
        OpenQueuePartyContext(
          gameId: gameId,
          gameStatus: booking?.game.status ?? 'OPEN',
          canUseParties: true,
          maxPartySize: 4,
          receivedInvites: const [],
          eligiblePlayers: const [],
        );
  }

  @override
  Future<OpenQueueBooking?> getMyUpcomingBookingForGame(String gameId) async {
    for (final candidate in [
      if (booking case final value?) value,
      ...additionalBookings,
    ]) {
      if (candidate.gameId == gameId) return candidate;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NotificationOpenQueueRepository extends _FakeOpenQueueRepository
    implements
        OpenQueuePartyNotificationRepository,
        OpenQueueBookingLookupRepository {
  _NotificationOpenQueueRepository(
    super.booking, {
    required this.inviteBooking,
    required this.notification,
    required super.partyContext,
  });

  final OpenQueueBooking inviteBooking;
  final OpenQueuePartyInviteNotification notification;
  final List<String> markedNotificationIds = [];

  @override
  Future<OpenQueueBooking?> getMyUpcomingBookingForGame(String gameId) async {
    return gameId == inviteBooking.gameId ? inviteBooking : null;
  }

  @override
  Future<List<OpenQueuePartyInviteNotification>>
  listPartyInviteNotifications() async => [notification];

  @override
  Future<void> markPartyInviteNotificationRead(String notificationId) async {
    markedNotificationIds.add(notificationId);
  }

  @override
  Stream<void> watchPartyInviteNotifications() => const Stream<void>.empty();
}

class _FakeClanRepository implements ClanRepository {
  const _FakeClanRepository({this.clans = const [], this.membership});

  final List<Clan> clans;
  final ClanMembership? membership;

  @override
  Future<List<Clan>> listClans() async => clans;

  @override
  Future<ClanMembership?> getMyClanMembership() async => membership;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFixtureRepository implements FixtureRepository {
  const _FakeFixtureRepository([this.fixtures = const []]);

  final List<Fixture> fixtures;

  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;

  @override
  Future<Fixture> getFixture(String fixtureId) async =>
      fixtures.firstWhere((fixture) => fixture.id == fixtureId);

  @override
  Future<List<Fixture>> listFixtures() async => fixtures;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
