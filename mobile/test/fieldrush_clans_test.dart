import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_detail_screen.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/clans/clans_screen.dart';
import 'package:field/src/clans/create_clan_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/home_discovery_repository.dart';
import 'package:field/src/home/home_discovery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _clan = Clan(
  id: 'desert',
  name: 'Desert Rattlers',
  tag: 'DR',
  motto: '',
  emblem: '⚽',
  themeId: 'pitch',
  patternId: 'solid',
  skillRating: 1500,
  wins: 0,
  losses: 0,
  memberCount: 1,
  createdBy: 'owner',
  marketCityId: 'phoenix',
  cityName: 'Phoenix',
);

void main() {
  testWidgets(
    'the simple creator persists color and returns to the real clan roster',
    (tester) async {
      final repository = _Clans();
      await _pump(
        tester,
        ClansScreen(clanRepository: repository, fixtureRepository: _Fixtures()),
      );
      expect(find.text('Start a clan'), findsOneWidget);
      await _capture(tester, 'clans-empty');
      await tester.tap(find.byKey(const ValueKey('clans-create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('clan-create-name')),
        'Desert Rattlers',
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('clan-create-tag')))
            .controller!
            .text,
        'DR',
      );
      await tester.tap(find.byKey(const ValueKey('clan-color-electric')));
      await tester.pumpAndSettle();
      await _capture(tester, 'clan-create');
      await tester.tap(find.byKey(const ValueKey('clan-create-submit')));
      await tester.pumpAndSettle();
      expect(repository.creates, 1);
      expect(repository.createdTheme, 'electric');
      expect(find.text('Desert Rattlers'), findsOneWidget);
      expect(find.text('COMING SOON'), findsOneWidget);
      expect(find.byKey(const ValueKey('clan-member-owner')), findsOneWidget);
      expect(find.byKey(const ValueKey('clan-join-requests')), findsOneWidget);
      expect(find.text('Skill Rating'), findsNothing);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'clan-roster');
    },
  );

  testWidgets('captain accepts a join request and the roster updates', (
    tester,
  ) async {
    final repository = _Clans(owned: true)
      ..requests = [
        const ClanJoinRequest(
          id: 'request',
          clanId: 'desert',
          profileId: 'applicant',
          displayName: 'Dana M.',
          username: 'dana',
          status: 'PENDING',
        ),
      ];
    await _pump(
      tester,
      ClanDetailScreen(
        clan: _clan,
        clanRepository: repository,
        fixtureRepository: _Fixtures(),
        currentMembership: repository.membership,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('clan-join-requests')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('clan-approve-request')));
    await tester.pumpAndSettle();
    expect(repository.accepted, ['request']);
    expect(find.textContaining('No requests yet.'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clan-member-applicant')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clan search works and visitors can request to join', (
    tester,
  ) async {
    final repository = _Clans()..clans = [_clan];
    await _pump(
      tester,
      HomeDiscoveryScreen(
        repository: _Discovery(),
        search: true,
        onPlayer: (_) async {},
        onNotification: (_) async {},
        clanRepository: repository,
        fixtureRepository: _Fixtures(),
      ),
    );
    await tester.tap(find.text('Clans'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('home-search-clan-desert')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('home-player-search')))
          .decoration!
          .hintText,
      'Clan name',
    );
    await tester.tap(find.byKey(const ValueKey('home-search-clan-desert')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clan-request-join')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('clan-request-join')));
    await tester.pumpAndSettle();
    expect(repository.joined, ['desert']);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'clan-public');
  });

  testWidgets('creator stays usable on a narrow screen with enlarged text', (
    tester,
  ) async {
    await _pump(
      tester,
      CreateClanScreen(clanRepository: _Clans()),
      width: 320,
      scale: 1.4,
    );
    await tester.enterText(
      find.byKey(const ValueKey('clan-create-name')),
      'Desert Rattlers',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('clan-create-submit')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  double width = 393,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if (Platform.environment['FIELDRUSH_CLANS_CAPTURE_DIR'] != null) {
    for (final font in ['Outfit', 'PlusJakartaSans']) {
      final loader = FontLoader(font)
        ..addFont(rootBundle.load('assets/fonts/$font.ttf'));
      await loader.load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  }
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(
          key: const ValueKey('clan-capture'),
          child: child!,
        ),
      ),
      home: screen,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['FIELDRUSH_CLANS_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final render = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('clan-capture')),
    );
    final picture = await render.toImage(pixelRatio: 2);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}

class _Clans implements ClanRepository {
  _Clans({bool owned = false}) {
    if (owned) {
      clans = [_clan];
      membership = const ClanMembership(clanId: 'desert', role: 'owner');
    }
  }
  List<Clan> clans = [];
  ClanMembership? membership;
  List<ClanMember> members = [
    const ClanMember(
      profileId: 'owner',
      displayName: 'Alex P.',
      role: 'owner',
      username: 'alexpreview',
    ),
  ];
  List<ClanJoinRequest> requests = [];
  final accepted = <String>[], joined = <String>[];
  int creates = 0;
  String? createdTheme;
  @override
  Future<List<Clan>> listClans() async => clans;
  @override
  Future<ClanMembership?> getMyClanMembership() async => membership;
  @override
  Future<List<ClanMember>> listClanMembers(String id) async => members;
  @override
  Future<List<ClanJoinRequest>> listPendingJoinRequests(String id) async =>
      requests;
  @override
  Future<Clan> createClan({
    required String name,
    required String tag,
    required String motto,
    required String emblem,
    required String themeId,
    required String patternId,
  }) async {
    creates++;
    createdTheme = themeId;
    clans = [_clan];
    membership = const ClanMembership(clanId: 'desert', role: 'owner');
    return _clan;
  }

  @override
  Future<void> reviewJoinRequest({
    required String requestId,
    required bool approve,
  }) async {
    if (approve) {
      accepted.add(requestId);
      members = [
        ...members,
        const ClanMember(
          profileId: 'applicant',
          displayName: 'Dana M.',
          role: 'member',
          username: 'dana',
        ),
      ];
    }
    requests = [];
  }

  @override
  Future<void> requestToJoinClan(String id) async {
    joined.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixtures implements FixtureRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Discovery implements HomeDiscoveryRepository {
  @override
  Future<List<HomePlayerResult>> searchPlayers(String query) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
