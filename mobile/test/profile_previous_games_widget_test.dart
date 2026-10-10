import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_detail_screen.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('public player profile hides baseline SR during placement', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileId: 'placement-player',
            profileRepository: _FakeProfileRepository(
              PlayerProfile(
                id: 'placement-player',
                displayName: 'New P.',
                username: 'new.p',
                bio: '',
                followingCount: 0,
                fansCount: 0,
                appearances: 0,
                goals: 0,
                assists: 0,
                highlights: const [],
                career: const [],
                previousGames: const [],
                playerRating: const ProfilePlayerRating(
                  skillRating: 1200,
                  matchesPlayed: 0,
                  wins: 0,
                  losses: 0,
                  draws: 0,
                  lastChange: 0,
                  region: 'phoenix',
                  events: [],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('profile-player-rating-card')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('PLACEMENT'), findsOneWidget);
    expect(find.text('0/2 placement games'), findsOneWidget);
    expect(find.text('????'), findsOneWidget);
    expect(find.text('1200'), findsNothing);
    expect(find.text('DIVISION 4'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('career history keeps its row id separate from its clan id', () {
    final entry = ProfileCareerEntry.fromJson({
      'id': 'career-row',
      'clan_id': 'clan-id',
      'clan_name': 'Mint Mavericks',
      'tag': 'MMAV',
      'emblem': '⚡',
      'period': '2026 - Present',
      'apps': 3,
      'goals': 1,
      'is_current': true,
    });

    expect(entry.id, 'career-row');
    expect(entry.clanId, 'clan-id');
  });

  test('Player SR history parses every frozen calculation input', () {
    final rating = ProfilePlayerRating.fromJson({
      'skill_rating': 1242,
      'matches_played': 1,
      'wins': 1,
      'losses': 0,
      'draws': 0,
      'last_change': 12,
      'region': 'bahrain',
      'events': [
        {
          'event_id': 'event-one',
          'source_type': 'OPEN_QUEUE',
          'source_id': 'game-one',
          'played_at': '2026-07-10T17:30:00Z',
          'opponent_label': 'Black Team',
          'side': 'WHITE',
          'result': 'WIN',
          'rating_before': 1230,
          'rating_change': 12,
          'rating_after': 1242,
          'rating_at_match_start': '1229',
          'team_average_rating': '1231.50',
          'opponent_average_rating': '1234.25',
          'expected_score': '0.492804',
          'calculation_version': 'PLAYER_ELO_V2_MARGIN',
          'score_margin': '3',
          'margin_multiplier': '1.10',
          'base_rating_change': '11',
          'margin_bonus_applied': '1',
        },
      ],
    });

    expect(rating.events.single.ratingAtMatchStart, 1229);
    expect(rating.events.single.teamAverageRating, 1231.5);
    expect(rating.events.single.opponentAverageRating, 1234.25);
    expect(rating.events.single.expectedScore, 0.492804);
    expect(rating.events.single.scoreMargin, 3);
    expect(rating.events.single.marginMultiplier, 1.1);
    expect(rating.events.single.baseRatingChange, 11);
    expect(rating.events.single.marginBonusApplied, 1);
  });

  test('match outcome is calculated from the player historical side', () {
    expect(_clanHistoryGame('home-win', 1).outcome, ProfileGameOutcome.win);
    expect(
      _clanHistoryGame(
        'away-win',
        1,
        playerSide: 'AWAY',
        homeScore: 1,
        awayScore: 2,
      ).outcome,
      ProfileGameOutcome.win,
    );
    expect(
      _clanHistoryGame(
        'white-loss',
        1,
        playerSide: 'WHITE',
        homeScore: 1,
        awayScore: 2,
      ).outcome,
      ProfileGameOutcome.loss,
    );
    expect(
      _clanHistoryGame(
        'black-win',
        1,
        playerSide: 'BLACK',
        homeScore: 1,
        awayScore: 2,
      ).outcome,
      ProfileGameOutcome.win,
    );
    expect(
      _clanHistoryGame('draw', 1, homeScore: 2, awayScore: 2).outcome,
      ProfileGameOutcome.draw,
    );
    expect(_clanHistoryGame('unknown', 1, playerSide: '').outcome, isNull);
  });

  testWidgets('Career precedes a collapsible Match History at the bottom', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final game = OpenQueueGame(
      id: 'solo-history',
      status: 'FINAL',
      venue: 'TFA, Saar',
      startsAt: DateTime.utc(2026, 7, 10, 17, 30),
      endsAt: DateTime.utc(2026, 7, 10, 18, 30),
      timezone: 'Asia/Bahrain',
      priceFils: 3000,
      ageLabel: 'All ages',
      capacity: 12,
      confirmedCount: 12,
      spots: const {},
      whiteScore: 4,
      blackScore: 3,
    );
    final detail = OpenQueueMatchDetail(
      game: game,
      scorers: const [],
      timeline: const [],
      broadcast: const FixtureBroadcast(status: 'REPLAY_READY'),
    );
    final profile = PlayerProfile(
      id: 'profile-one',
      displayName: 'Player One',
      username: 'player.one',
      bio: '',
      followingCount: 0,
      fansCount: 0,
      appearances: 2,
      goals: 1,
      assists: 0,
      clan: const ProfileClan(
        id: 'mint-mavericks',
        name: 'Mint Mavericks',
        tag: 'MMAV',
        emblem: '⚡',
        themeId: 'mint',
        patternId: 'solid',
        skillRating: 9999,
      ),
      highlights: const [],
      career: const [
        ProfileCareerEntry(
          id: 'career-one',
          clanId: 'mint-mavericks',
          clanName: 'Mint Mavericks',
          tag: 'MINT',
          emblem: '⚡',
          period: '2026 - Present',
          apps: 5,
          goals: 1,
          isCurrent: true,
        ),
      ],
      playerRating: ProfilePlayerRating(
        skillRating: 1242,
        matchesPlayed: 3,
        wins: 2,
        losses: 1,
        draws: 0,
        lastChange: 12,
        region: 'bahrain',
        events: [
          ProfileRatingEvent(
            id: 'rating-event-one',
            sourceType: 'OPEN_QUEUE',
            sourceId: game.id,
            playedAt: game.startsAt,
            opponentLabel: 'Black Team',
            side: 'WHITE',
            result: 'WIN',
            ratingBefore: 1230,
            ratingChange: 12,
            ratingAfter: 1242,
            ratingAtMatchStart: 1230,
            teamAverageRating: 1232,
            opponentAverageRating: 1234,
            expectedScore: 0.49,
            calculationVersion: 'PLAYER_ELO_V2_MARGIN',
            scoreMargin: 3,
            marginMultiplier: 1.1,
            baseRatingChange: 11,
            marginBonusApplied: 1,
          ),
        ],
      ),
      previousGames: [
        ProfilePreviousGame(
          id: game.id,
          type: ProfileGameType.solo,
          playedAt: game.startsAt,
          venue: game.venue,
          homeName: 'White Team',
          homeTag: 'WHITE',
          homeEmblem: '⚪',
          awayName: 'Black Team',
          awayTag: 'BLACK',
          awayEmblem: '⚫',
          homeScore: 4,
          awayScore: 3,
          playerSide: 'WHITE',
          playerRole: 'ATT',
        ),
        ProfilePreviousGame(
          id: 'clan-history',
          type: ProfileGameType.clan,
          playedAt: DateTime.utc(2026, 7, 7),
          venue: 'TFA, Saar',
          homeName: 'Mint Mavericks',
          homeTag: 'MINT',
          homeEmblem: '⚽',
          awayName: 'Riffa Raiders',
          awayTag: 'RIF',
          awayEmblem: '🛡️',
          homeScore: 2,
          awayScore: 1,
          playerSide: 'HOME',
        ),
        _clanHistoryGame('clan-history-2', 3, playerSide: 'AWAY'),
        _clanHistoryGame('clan-history-3', 1, homeScore: 2, awayScore: 2),
        _clanHistoryGame('clan-history-4', 6),
      ],
    );

    var signOutCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepository: _FakeProfileRepository(profile),
            clanRepository: const _FakeClanRepository(),
            fixtureRepository: const _FakeFixtureRepository(),
            openQueueRepository: _FakeOpenQueueRepository(detail),
            onSignOut: () => signOutCount += 1,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('PLAYER RATING'), findsOneWidget);
    expect(find.text('DIVISION 4'), findsOneWidget);
    expect(find.text('3 rated games'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-player-rating-progress')),
      findsOneWidget,
    );
    expect(find.text('CAREER'), findsOneWidget);
    expect(find.text('SR HISTORY'), findsNothing);
    expect(find.text('PREVIOUS GAMES'), findsNothing);
    expect(find.text('+12 SR'), findsNothing);
    expect(find.byTooltip('Sign out'), findsOneWidget);
    expect(find.byTooltip('Share profile'), findsNothing);
    expect(find.text(profile.clan!.rank.label.toUpperCase()), findsNothing);

    expect(
      find.byKey(const ValueKey('profile-clan-mint-mavericks')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('profile-clan-mint-mavericks')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ClanDetailScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(ClanDetailScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('profile-career-clan-career-one')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(
      find.byKey(const ValueKey('profile-career-clan-career-one')),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ClanDetailScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(ClanDetailScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byTooltip('Sign out'));
    expect(signOutCount, 1);

    await tester.scrollUntilVisible(
      find.text('MATCH HISTORY'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('MATCH HISTORY'), findsOneWidget);
    expect(find.text('VIEW MORE'), findsOneWidget);
    expect(find.text('WHITE vs BLACK'), findsOneWidget);
    expect(find.text('MINT vs RIF'), findsNWidgets(2));
    expect(find.text('4 - 3'), findsOneWidget);
    expect(find.text('WIN'), findsNWidgets(2));
    expect(find.text('LOSS'), findsOneWidget);
    expect(find.text('DRAW'), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-game-result-solo-history')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-previous-game-clan-history-4')),
      findsNothing,
    );

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('VIEW MORE'));
    await tester.pumpAndSettle();
    expect(find.text('SHOW LESS'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-previous-game-clan-history-4')),
      findsOneWidget,
    );
    expect(find.text('DRAW'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-game-result-clan-history-3')),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('profile-previous-game-solo-history')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(
      find.byKey(const ValueKey('profile-previous-game-solo-history')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('SOLO MATCH'), findsOneWidget);
    expect(find.text('White Team'), findsOneWidget);
    expect(find.text('Black Team'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixture-section-timeline')),
      findsOneWidget,
    );
    expect(find.text('WATCH MATCH'), findsNothing);
    expect(find.text('TFA, Saar'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fixture-player-rating-update')),
      findsOneWidget,
    );
    expect(find.text('PLAYER RATING UPDATE'), findsOneWidget);
    expect(find.text('1230'), findsOneWidget);
    expect(find.text('1242'), findsOneWidget);
    expect(find.text('+12 SR'), findsOneWidget);
    expect(find.text('3-GOAL WIN BONUS'), findsOneWidget);
    expect(
      find.text('+1 SR included in this update · standard result +11 SR'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('fixture-section-watch')));
    await tester.pumpAndSettle();
    expect(find.text('WATCH MATCH'), findsOneWidget);
    expect(find.text('PLAYER RATING UPDATE'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

ProfilePreviousGame _clanHistoryGame(
  String id,
  int day, {
  String playerSide = 'HOME',
  int homeScore = 2,
  int awayScore = 1,
}) {
  return ProfilePreviousGame(
    id: id,
    type: ProfileGameType.clan,
    playedAt: DateTime.utc(2026, 7, day),
    venue: 'TFA, Saar',
    homeName: 'Mint Mavericks',
    homeTag: 'MINT',
    homeEmblem: '⚡',
    awayName: 'Riffa Raiders',
    awayTag: 'RIF',
    awayEmblem: '🛡️',
    homeScore: homeScore,
    awayScore: awayScore,
    playerSide: playerSide,
  );
}

class _FakeProfileRepository implements ProfileRepository {
  const _FakeProfileRepository(this.profile);

  final PlayerProfile profile;

  @override
  String get currentUserId => 'viewer';

  @override
  Future<PlayerProfile> getCurrentProfile() async => profile;

  @override
  Future<PlayerProfile> getProfile(String profileId) async => profile;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFixtureRepository implements FixtureRepository {
  const _FakeFixtureRepository();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClanRepository implements ClanRepository {
  const _FakeClanRepository();

  static const clan = Clan(
    id: 'mint-mavericks',
    name: 'Mint Mavericks',
    tag: 'MMAV',
    motto: 'Play together.',
    emblem: '⚡',
    themeId: 'mint',
    patternId: 'solid',
    skillRating: 1199,
    wins: 2,
    losses: 1,
    memberCount: 1,
    createdBy: 'profile-one',
  );

  @override
  Future<ClanMembership?> getMyClanMembership() => Future.delayed(
    const Duration(milliseconds: 50),
    () => const ClanMembership(clanId: 'mint-mavericks', role: 'leader'),
  );

  @override
  Future<List<Clan>> listClans() =>
      Future.delayed(const Duration(milliseconds: 50), () => const [clan]);

  @override
  Future<List<Fixture>> listClanFixtures(String clanId) async => const [];

  @override
  Future<List<ClanMember>> listClanMembers(String clanId) async => const [];

  @override
  Future<List<ClanJoinRequest>> listPendingJoinRequests(String clanId) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOpenQueueRepository implements OpenQueueRepository {
  const _FakeOpenQueueRepository(this.detail);

  final OpenQueueMatchDetail detail;

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async => detail;

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
