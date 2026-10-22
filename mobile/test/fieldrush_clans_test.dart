import 'dart:io';
import 'dart:ui' as ui;

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/clans/clan.dart';
import 'package:field/src/clans/clan_detail_screen.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/clans/clans_screen.dart';
import 'package:field/src/clans/create_clan_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/home/home_discovery_repository.dart';
import 'package:field/src/home/home_discovery_screen.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  testWidgets(
    'owner member actions use the shared modal and keep role changes',
    (tester) async {
      final repository = _Clans(owned: true)
        ..members = [
          const ClanMember(
            profileId: 'owner',
            displayName: 'Alex P.',
            role: 'owner',
          ),
          const ClanMember(
            profileId: 'member',
            displayName: 'Dana M.',
            role: 'member',
          ),
          const ClanMember(
            profileId: 'leader',
            displayName: 'Sam K.',
            role: 'leader',
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
      expect(find.byTooltip('Manage Alex P.'), findsNothing);
      await tester.tap(find.byTooltip('Manage Dana M.'));
      await tester.pumpAndSettle();
      expect(find.byType(FieldrushModal), findsOneWidget);
      expect(find.text('Make captain'), findsOneWidget);
      expect(find.text('Transfer ownership'), findsOneWidget);
      expect(find.text('Remove from clan'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Manage Dana M.')).style!.fontFamily,
        'Outfit',
      );
      expect(
        Theme.of(
          tester.element(find.text('Manage Dana M.')),
        ).colorScheme.surface,
        FieldrushAuthTheme.cream,
      );
      await tester.tap(find.byKey(const ValueKey('clan-member-action-role')));
      await tester.pumpAndSettle();
      expect(repository.roleChanges, [(profileId: 'member', makeLeader: true)]);
      await tester.tap(find.byTooltip('Manage Sam K.'));
      await tester.pumpAndSettle();
      expect(find.text('Remove captain role'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('clan-member-action-role')));
      await tester.pumpAndSettle();
      expect(repository.roleChanges.last, (
        profileId: 'leader',
        makeLeader: false,
      ));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('member removal and transfer still require confirmation', (
    tester,
  ) async {
    final repository = _Clans(owned: true)
      ..members = [
        const ClanMember(
          profileId: 'owner',
          displayName: 'Alex P.',
          role: 'owner',
        ),
        const ClanMember(
          profileId: 'member',
          displayName: 'Dana M.',
          role: 'member',
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
    await tester.tap(find.byTooltip('Manage Dana M.'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('clan-member-action-remove')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Dana M.?'), findsOneWidget);
    expect(repository.removed, isEmpty);
    await tester.tap(find.byKey(const ValueKey('field-confirmation-cancel')));
    await tester.pumpAndSettle();
    expect(repository.removed, isEmpty);
    await tester.tap(find.byTooltip('Manage Dana M.'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('clan-member-action-transfer')));
    await tester.pumpAndSettle();
    expect(find.text('Transfer ownership?'), findsOneWidget);
    expect(repository.transferred, isEmpty);
    await tester.tap(find.byKey(const ValueKey('field-confirmation-confirm')));
    await tester.pumpAndSettle();
    expect(repository.transferred, ['member']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captain cannot promote, transfer or remove another captain', (
    tester,
  ) async {
    final repository = _Clans(owned: true)
      ..membership = const ClanMembership(clanId: 'desert', role: 'leader')
      ..members = [
        const ClanMember(
          profileId: 'owner',
          displayName: 'Alex P.',
          role: 'owner',
        ),
        const ClanMember(
          profileId: 'member',
          displayName: 'Dana M.',
          role: 'member',
        ),
        const ClanMember(
          profileId: 'leader',
          displayName: 'Sam K.',
          role: 'leader',
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
    await tester.tap(find.byTooltip('Manage Sam K.'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clan-member-action-role')), findsNothing);
    expect(
      find.byKey(const ValueKey('clan-member-action-transfer')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('clan-member-action-remove')),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Manage Dana M.'));
    await tester.pumpAndSettle();
    expect(find.text('Remove from clan'), findsOneWidget);
    expect(find.byKey(const ValueKey('clan-member-action-role')), findsNothing);
    expect(
      find.byKey(const ValueKey('clan-member-action-transfer')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'blocked clan archive keeps an actionable error open until dismissed',
    (tester) async {
      final repository = _Clans(owned: true)
        ..archiveError = const PostgrestException(
          message:
              'Cancel every active clan match from Match Details before deleting this clan. Live matches must be resolved by the referee or Field admin.',
          code: 'P0001',
        );
      var membershipChanges = 0;
      await _pump(
        tester,
        ClanDetailScreen(
          clan: _clan,
          clanRepository: repository,
          fixtureRepository: _Fixtures(),
          currentMembership: repository.membership,
          embedded: true,
          onMembershipChanged: () async {
            membershipChanges++;
          },
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive clan'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('field-confirmation-confirm')),
      );
      await tester.pumpAndSettle();
      expect(repository.archiveAttempts, 1);
      expect(find.text('Couldn’t archive clan'), findsOneWidget);
      expect(
        find.textContaining('Your clan still has an unfinished match.'),
        findsOneWidget,
      );
      expect(find.textContaining('ask a referee or admin'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('clan-exit-error')), findsOneWidget);
      expect(membershipChanges, 0);
      expect(repository.membership, isNotNull);
      await tester.tap(find.byKey(const ValueKey('clan-exit-error-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clan-exit-error')), findsNothing);
      expect(find.text('Desert Rattlers'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unexpected archive failure shows a safe explanation and allows another attempt',
    (tester) async {
      final repository = _Clans(owned: true)
        ..archiveError = const PostgrestException(
          message: 'column "internal_secret" does not exist',
          code: '42703',
        );
      await _pump(
        tester,
        ClanDetailScreen(
          clan: _clan,
          clanRepository: repository,
          fixtureRepository: _Fixtures(),
          currentMembership: repository.membership,
          embedded: true,
        ),
      );
      for (var attempt = 1; attempt <= 2; attempt++) {
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Archive clan'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('field-confirmation-confirm')),
        );
        await tester.pumpAndSettle();
        expect(repository.archiveAttempts, attempt);
        expect(
          find.text(
            'We couldn’t confirm that this clan was archived. Please try again.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('internal_secret'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('clan-exit-error-close')));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    },
  );
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
  final roleChanges = <({String profileId, bool makeLeader})>[];
  final removed = <String>[], transferred = <String>[];
  int creates = 0;
  int archiveAttempts = 0;
  Object? archiveError;
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
  Future<void> archiveClan(String id) async {
    archiveAttempts++;
    if (archiveError case final error?) throw error;
    membership = null;
    clans = [];
  }

  @override
  Future<void> setClanMemberLeader({
    required String clanId,
    required String profileId,
    required bool makeLeader,
  }) async {
    roleChanges.add((profileId: profileId, makeLeader: makeLeader));
  }

  @override
  Future<void> kickClanMember({
    required String clanId,
    required String profileId,
  }) async {
    removed.add(profileId);
  }

  @override
  Future<void> transferClanOwnership({
    required String clanId,
    required String newOwnerProfileId,
  }) async {
    transferred.add(newOwnerProfileId);
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
