import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/dashboard_home.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
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
    final game = _game(daysFromToday: 0, confirmedCount: 8);

    await _pumpDashboard(tester, game);

    expect(find.text('MATCH PENDING'), findsOneWidget);
    expect(find.text('8 / 12 CONFIRMED'), findsOneWidget);
    expect(find.text('MATCH CONFIRMED'), findsNothing);
    expect(find.text('Midfielder · 8:30 PM'), findsOneWidget);
    expect(find.textContaining('TODAY ·'), findsOneWidget);
    expect(find.text('TFA, Saar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full home booking card shows confirmed count and TOMORROW', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final game = _game(daysFromToday: 1, confirmedCount: 12);

    await _pumpDashboard(tester, game);

    expect(find.text('MATCH CONFIRMED'), findsOneWidget);
    expect(find.text('12 / 12 CONFIRMED'), findsOneWidget);
    expect(find.text('MATCH PENDING'), findsNothing);
    expect(find.textContaining('TOMORROW ·'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setPhoneSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpDashboard(WidgetTester tester, OpenQueueGame game) async {
  final booking = OpenQueueBooking(
    id: 'booking',
    gameId: game.id,
    profileId: 'profile',
    role: OpenQueueRole.midfielder,
    status: 'CONFIRMED',
    amountPaidFils: game.priceFils,
    bookedAt: DateTime.now(),
    game: game,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DashboardHome(
          profileRepository: const _FakeProfileRepository(),
          clanRepository: const _FakeClanRepository(),
          fixtureRepository: const _FakeFixtureRepository(),
          leaderboardRepository: const _FakeLeaderboardRepository(),
          openQueueRepository: _FakeOpenQueueRepository(booking),
          onOpenClans: () {},
          onOpenFixtures: () {},
          onOpenRanks: () {},
          onOpenProfile: () {},
          onNavigateTab: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OpenQueueGame _game({required int daysFromToday, required int confirmedCount}) {
  final nowInBahrain = DateTime.now().toUtc().add(const Duration(hours: 3));
  final bahrainStart = DateTime.utc(
    nowInBahrain.year,
    nowInBahrain.month,
    nowInBahrain.day + daysFromToday,
    20,
    30,
  );
  final startsAt = bahrainStart.subtract(const Duration(hours: 3));
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
  );
}

class _FakeProfileRepository implements ProfileRepository {
  const _FakeProfileRepository();

  @override
  Future<PlayerProfile> getCurrentProfile() async => const PlayerProfile(
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

class _FakeOpenQueueRepository implements OpenQueueRepository {
  const _FakeOpenQueueRepository(this.booking);

  final OpenQueueBooking booking;

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async => booking;

  @override
  Future<List<OpenQueueGame>> listGames() async => [booking.game];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClanRepository implements ClanRepository {
  const _FakeClanRepository();

  @override
  Future<List<Clan>> listClans() async => const [];

  @override
  Future<ClanMembership?> getMyClanMembership() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFixtureRepository implements FixtureRepository {
  const _FakeFixtureRepository();

  @override
  Future<MyClanMembership?> getMyClanMembership() async => null;

  @override
  Future<List<Fixture>> listFixtures() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
