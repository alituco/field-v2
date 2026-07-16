import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/fixtures/fixtures_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('match schedule policy uses Tuesday/Friday and the clan-only slot', () {
    expect(isFixtureMatchDay(DateTime(2026, 7, 14)), isTrue);
    expect(isFixtureMatchDay(DateTime(2026, 7, 17)), isTrue);
    expect(isFixtureMatchDay(DateTime(2026, 7, 16)), isFalse);
    expect(clanFixtureTimeSlots, const [FixtureTimeSlot.early]);
    expect(clanFixtureTimeSlots, isNot(contains(FixtureTimeSlot.late)));
  });

  testWidgets('Play offers Solo and Clan, and Solo starts position selection', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final fixtureRepository = _FakeFixtureRepository(
      const MyClanMembership(clan: _mintMavericks, role: 'leader'),
    );

    await _pumpFixtures(tester, fixtureRepository: fixtureRepository);

    expect(find.text('PLAY'), findsOneWidget);
    expect(find.text('HOST'), findsNothing);

    await tester.tap(find.text('PLAY'));
    await _pumpAsync(tester);

    expect(find.text('HOW DO YOU WANT TO PLAY?'), findsOneWidget);
    expect(find.text('Solo game'), findsOneWidget);
    expect(find.text('Clan game'), findsOneWidget);
    expect(
      find.textContaining('Tuesdays and Fridays, 8:30–9:30 PM'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('play-solo-choice')));
    await tester.pump(const Duration(milliseconds: 350));
    await _pumpAsync(tester);

    expect(find.text('WHERE DO YOU PLAY?'), findsOneWidget);
    expect(find.text('Choose your main position.'), findsOneWidget);
  });

  testWidgets('leader sees their clan before and throughout scheduling', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final fixtureRepository = _FakeFixtureRepository(
      const MyClanMembership(clan: _mintMavericks, role: 'leader'),
    );

    await _pumpFixtures(tester, fixtureRepository: fixtureRepository);
    await tester.tap(find.text('PLAY'));
    await _pumpAsync(tester);

    expect(
      find.textContaining('Tuesdays and Fridays, 7:00–8:00 PM'),
      findsOneWidget,
    );
    expect(find.text('LEADER · MINT'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('play-clan-choice')));
    await tester.pump(const Duration(milliseconds: 350));
    await _pumpAsync(tester);

    expect(find.text('CLAN GAME'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('clan-scheduling-banner')),
      findsOneWidget,
    );
    expect(find.text('SCHEDULING FOR'), findsOneWidget);
    expect(find.text('Mint Mavericks'), findsWidgets);
    expect(find.text('Host for Mint Mavericks'), findsOneWidget);

    await tester.tap(find.text('Host for Mint Mavericks'));
    await _pumpAsync(tester);

    expect(
      find.text(
        'Choose a Tuesday or Friday. Clan games always run from 7:00–8:00 PM.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Choose a match date'));
    await tester.pumpAndSettle();
    final nextFriday = _nextWeekday(DateTime.now(), DateTime.friday);
    final visibleMonth = _nextScheduledMatchDay(DateTime.now());
    if (nextFriday.month != visibleMonth.month ||
        nextFriday.year != visibleMonth.year) {
      await tester.tap(find.byIcon(Icons.chevron_right_rounded).last);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('${nextFriday.day}'));
    await tester.pumpAndSettle();

    expect(find.text(FixtureTimeSlot.early.label), findsOneWidget);
    expect(find.text(FixtureTimeSlot.late.label), findsNothing);
  });

  testWidgets('ordinary clan member is blocked with a clear reason', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final selectedTabs = <int>[];
    final fixtureRepository = _FakeFixtureRepository(
      const MyClanMembership(clan: _mintMavericks, role: 'member'),
    );

    await _pumpFixtures(
      tester,
      fixtureRepository: fixtureRepository,
      onNavigateTab: selectedTabs.add,
    );
    await tester.tap(find.text('PLAY'));
    await _pumpAsync(tester);

    expect(find.text('MEMBER · LOCKED'), findsOneWidget);
    expect(
      find.text(
        'Clan games run Tuesdays and Fridays, 7:00–8:00 PM. Only owners and leaders can schedule for Mint Mavericks.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('play-clan-choice')));
    await tester.pump(const Duration(milliseconds: 350));
    await _pumpAsync(tester);

    expect(find.text('Only owners and leaders can schedule'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('field-confirmation-dialog')),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Only the owner or a leader can schedule or join games for this clan',
      ),
      findsOneWidget,
    );
    expect(find.text('CLAN GAME'), findsNothing);

    await tester.tap(find.text('Go to Clans'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(selectedTabs, [2]);
  });

  testWidgets('player without a clan is told exactly what to do', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final fixtureRepository = _FakeFixtureRepository(null);

    await _pumpFixtures(tester, fixtureRepository: fixtureRepository);
    await tester.tap(find.text('PLAY'));
    await _pumpAsync(tester);

    expect(find.text('NO CLAN'), findsOneWidget);
    expect(
      find.text(
        'Clan games run Tuesdays and Fridays, 7:00–8:00 PM. Join or create a clan to schedule.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('play-clan-choice')));
    await tester.pump(const Duration(milliseconds: 350));
    await _pumpAsync(tester);

    expect(find.text('Join a clan first'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('field-confirmation-dialog')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Join or create a clan, then come back here'),
      findsOneWidget,
    );
  });

  testWidgets('clan access is checked again before the wizard opens', (
    tester,
  ) async {
    await _setPhoneSize(tester);
    final fixtureRepository = _FakeFixtureRepository.sequence([
      const MyClanMembership(clan: _mintMavericks, role: 'leader'),
      const MyClanMembership(clan: _mintMavericks, role: 'leader'),
      const MyClanMembership(clan: _mintMavericks, role: 'member'),
    ]);

    await _pumpFixtures(tester, fixtureRepository: fixtureRepository);
    await tester.tap(find.text('PLAY'));
    await _pumpAsync(tester);
    await tester.tap(find.byKey(const ValueKey('play-clan-choice')));
    await tester.pump(const Duration(milliseconds: 350));
    await _pumpAsync(tester);

    expect(find.text('You cannot schedule for Mint Mavericks'), findsOneWidget);
    expect(
      find.textContaining('only its owner or a leader can schedule'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('clan-scheduling-banner')), findsNothing);
    expect(find.text('Host for Mint Mavericks'), findsNothing);
  });

  testWidgets('Play choices do not overflow on a narrow phone', (tester) async {
    await _setPhoneSize(tester, size: const Size(320, 568));
    final fixtureRepository = _FakeFixtureRepository(
      const MyClanMembership(clan: _mintMavericks, role: 'member'),
    );

    await _pumpFixtures(tester, fixtureRepository: fixtureRepository);
    await tester.tap(find.text('PLAY'));
    await _pumpAsync(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('play-clan-choice')));
    await tester.pump();

    expect(find.text('Solo game'), findsOneWidget);
    expect(find.text('Clan game'), findsOneWidget);
    expect(find.text('MEMBER · LOCKED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setPhoneSize(
  WidgetTester tester, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpFixtures(
  WidgetTester tester, {
  required _FakeFixtureRepository fixtureRepository,
  ValueChanged<int>? onNavigateTab,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FixturesScreen(
          fixtureRepository: fixtureRepository,
          openQueueRepository: const _FakeOpenQueueRepository(),
          onNavigateTab: onNavigateTab,
        ),
      ),
    ),
  );
  await _pumpAsync(tester);
}

Future<void> _pumpAsync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

DateTime _nextWeekday(DateTime from, int weekday) {
  var date = DateTime(from.year, from.month, from.day);
  while (date.weekday != weekday) {
    date = date.add(const Duration(days: 1));
  }
  return date;
}

DateTime _nextScheduledMatchDay(DateTime from) {
  var date = DateTime(from.year, from.month, from.day);
  while (!isFixtureMatchDay(date)) {
    date = date.add(const Duration(days: 1));
  }
  return date;
}

const _mintMavericks = FixtureClan(
  id: 'mint-mavericks',
  name: 'Mint Mavericks',
  tag: 'MINT',
  emblem: '⚽',
  themeId: 'pitch',
  patternId: 'solid',
  skillRating: 1600,
);

class _FakeFixtureRepository implements FixtureRepository {
  _FakeFixtureRepository(this.membership) : _memberships = null;

  _FakeFixtureRepository.sequence(List<MyClanMembership?> memberships)
    : membership = null,
      _memberships = memberships;

  final MyClanMembership? membership;
  final List<MyClanMembership?>? _memberships;
  int _membershipCallCount = 0;

  @override
  Future<List<Fixture>> listFixtures() async => const [];

  @override
  Future<MyClanMembership?> getMyClanMembership() async {
    final memberships = _memberships;
    if (memberships == null || memberships.isEmpty) return membership;
    final index = _membershipCallCount.clamp(0, memberships.length - 1);
    _membershipCallCount++;
    return memberships[index];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOpenQueueRepository implements OpenQueueRepository {
  const _FakeOpenQueueRepository();

  @override
  Future<List<OpenQueueGame>> listGames() async => const [];

  @override
  Future<List<OpenQueueGame>> listFixtureGames() async => const [];

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) =>
      throw UnimplementedError();

  @override
  Future<OpenQueueBooking?> getMyUpcomingBooking() async => null;

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => const [];

  @override
  Future<OpenQueueBooking> bookGame({
    required OpenQueueGame game,
    required OpenQueueRole role,
    required String paymentMethod,
  }) => throw UnimplementedError();

  @override
  Future<OpenQueueBooking> cancelBooking(String bookingId) =>
      throw UnimplementedError();

  @override
  Future<OpenQueueCancellationPreview> previewCancellation(String bookingId) =>
      throw UnimplementedError();
}
