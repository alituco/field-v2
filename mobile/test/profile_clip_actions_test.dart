import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_clip_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('older clips without source metadata do not invent a match', () async {
    expect(await loadProfileClipFixture(_clip()), isNull);
  });

  test('clan clips load their exact original fixture', () async {
    final fixture = _fixture('clan-match');
    final repository = _FixtureRepository(fixture);
    final loaded = await loadProfileClipFixture(
      _clip(sourceType: ProfileHighlightSource.clan, matchId: 'clan-match'),
      fixtureRepository: repository,
    );
    expect(loaded, same(fixture));
    expect(repository.requestedId, 'clan-match');
  });

  test('solo clips use solo match metadata and preserve the replay', () async {
    final repository = _SoloRepository();
    final loaded = await loadProfileClipFixture(
      _clip(sourceType: ProfileHighlightSource.solo, matchId: 'solo-match'),
      openQueueRepository: repository,
    );
    expect(repository.requestedId, 'solo-match');
    expect(loaded?.id, 'solo-match');
    expect(loaded?.fullGamePlaybackUrl, 'https://cdn.example.com/replay.m3u8');
    expect(loaded?.homeClan.name, 'White Team');
  });

  test('a mismatched source response cannot open another match', () async {
    expect(
      await loadProfileClipFixture(
        _clip(sourceType: ProfileHighlightSource.clan, matchId: 'requested'),
        fixtureRepository: _FixtureRepository(_fixture('different')),
      ),
      isNull,
    );
  });

  testWidgets('public clip share sends its title and playable public link', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return 'dev.fluttercommunity.plus/share/dismissed';
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await _pumpShare(tester, _clip());
    await tester.tap(find.text('Share clip'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'share');
    final arguments = calls.single.arguments as Map;
    expect(
      arguments['text'],
      'Top corner finish\nhttps://cdn.example.com/clip.m3u8',
    );
    expect(arguments['subject'], 'Top corner finish');
    expect(arguments['originWidth'], greaterThan(0));
    expect(arguments['originHeight'], greaterThan(0));
  });

  testWidgets('private clips cannot expose playback links through sharing', (
    tester,
  ) async {
    var nativeCalls = 0;
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      nativeCalls += 1;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await _pumpShare(tester, _clip(isPublic: false));
    await tester.tap(find.text('Share clip'));
    await tester.pump();
    expect(nativeCalls, 0);
    expect(find.text('Make this clip public before sharing.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}

Future<void> _pumpShare(WidgetTester tester, ProfileHighlight highlight) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => shareProfileClip(context, highlight),
              child: const Text('Share clip'),
            ),
          ),
        ),
      ),
    );

ProfileHighlight _clip({
  bool isPublic = true,
  ProfileHighlightSource? sourceType,
  String? matchId,
}) => ProfileHighlight(
  id: 'clip-one',
  title: 'Top corner finish',
  thumbnailUrl: '',
  duration: '0:14',
  views: 7,
  videoUrl: 'https://cdn.example.com/clip.m3u8',
  isPublic: isPublic,
  sourceType: sourceType,
  sourceMatchId: matchId,
);

Fixture _fixture(String id) => Fixture(
  id: id,
  status: FixtureStatus.finalResult,
  homeClanId: 'home',
  venue: 'Field',
  day: 'SUNDAY',
  timeSlot: FixtureTimeSlot.late.label,
  matchDate: DateTime.utc(2026, 10, 18),
  createdBy: 'creator',
  homeClan: const FixtureClan(
    id: 'home',
    name: 'Home',
    tag: 'HOM',
    emblem: '⚽',
    themeId: 'pitch',
    patternId: 'solid',
    skillRating: 1500,
  ),
);

class _FixtureRepository implements FixtureRepository {
  _FixtureRepository(this.fixture);
  final Fixture fixture;
  String? requestedId;

  @override
  Future<Fixture> getFixture(String fixtureId) async {
    requestedId = fixtureId;
    return fixture;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SoloRepository implements OpenQueueRepository {
  String? requestedId;

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async {
    requestedId = gameId;
    return OpenQueueMatchDetail(
      game: OpenQueueGame(
        id: gameId,
        status: 'FINAL',
        venue: 'Field',
        startsAt: DateTime.utc(2026, 10, 19, 3, 30),
        endsAt: DateTime.utc(2026, 10, 19, 4, 30),
        timezone: 'America/Phoenix',
        priceFils: 8000,
        ageLabel: '18+',
        capacity: 14,
        confirmedCount: 14,
        spots: const {},
      ),
      scorers: const [],
      timeline: const [],
      videoUrl: 'https://cdn.example.com/replay.m3u8',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
