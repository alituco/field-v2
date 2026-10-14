import 'dart:async';

import 'package:field/main.dart' as app;
import 'package:field/src/fixtures/fieldrush_fixture_page.dart';
import 'package:field/src/leaderboard/fieldrush_leaderboard_widgets.dart';
import 'package:field/src/leaderboard/fieldrush_rating_tracks.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/moderation/moderation_repository.dart';
import 'package:field/src/open_queue/fieldrush_booking_flow.dart';
import 'package:field/src/open_queue/fieldrush_booking_widgets.dart';
import 'package:field/src/open_queue/fieldrush_checkout_sheet.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_party.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/fieldrush_you_screen.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'helpers/fieldrush_fixture_auth_repository.dart';
import 'helpers/staging_party_navigation.dart';
import 'helpers/staging_profile_navigation.dart';
import 'helpers/staging_test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hosted staging player journey', (tester) async {
    final config = StagingE2EConfig.fromEnvironment()..validate();
    validateHostedPaymentBypass();

    _logStage('launch app and verify signed-out state');
    await app.runFieldApp(
      accountRepository: FieldrushFixtureAuthRepository(config),
    );
    await _ensureSignedOut(tester);

    _logStage('verify fixed OTP login');
    await _verifyFixedOtpLogin(tester, config);
    _logStage('complete onboarding');
    await _switchToProfile(
      tester,
      profileId: config.onboardingProfileId,
      label: 'onboarding player',
      expected: _SignedInDestination.onboarding,
    );
    await _completeOnboarding(tester, config);
    await _verifyCompletedAccount(config);

    final repository = SupabaseOpenQueueRepository();
    _logStage('verify seeded party-target booking');
    await _switchToProfile(
      tester,
      profileId: config.partyTargetProfileId,
      label: 'party target',
    );
    expect(
      _currentUserId(),
      config.partyTargetProfileId,
      reason: 'The party-target phone did not open its fixture profile.',
    );
    final partyTargetBooking = await _boundedRemoteStep(
      'load party-target booking',
      repository.getMyUpcomingBookingForGame(config.matchGameId),
    );
    expect(
      partyTargetBooking,
      isNotNull,
      reason:
          'The staging fixture must pre-book the party target into the E2E match.',
    );

    _logStage('verify the main player journey');
    await _switchToProfile(
      tester,
      profileId: config.mainProfileId,
      label: 'main player',
    );
    final mainId = _currentUserId();
    _logStage('verify Phoenix leaderboards and season navigation');
    await _verifyLeaderboards(tester);
    // The player may hold only one upcoming/active booking. Exercise the
    // cancellation first, then book the match used by the referee/admin phase.
    await _verifyCancellationThroughUi(tester, repository, config);
    _logStage('book the main player and send a party invite');
    final matchGame = await _gameById(repository, config.matchGameId);
    expect(matchGame.confirmedCount, 13);
    expect(matchGame.spotsFor(OpenQueueRole.defender), 1);

    await _bookGameThroughUi(
      tester,
      game: matchGame,
      role: OpenQueueRole.defender,
    );
    final matchBooking = await _boundedRemoteStep(
      'load newly created main-player booking',
      repository.getMyUpcomingBookingForGame(matchGame.id),
    );
    expect(matchBooking, isNotNull);

    await _createAndSendPartyInvite(
      tester,
      gameId: matchGame.id,
      inviteeId: config.partyTargetProfileId,
    );
    await _goHomeFromGame(tester);
    await pumpUntilFound(
      tester,
      find.byKey(ValueKey('home-solo-booking-${matchBooking!.id}')),
      reason: 'The new match booking did not appear on Home.',
    );
    await _verifyFixtureDetailLink(tester, matchGame);

    _logStage('accept the party invite as its recipient');
    await _switchToProfile(
      tester,
      profileId: config.partyTargetProfileId,
      label: 'party target',
    );
    await _acceptPartyInvite(tester, matchGame.id);

    _logStage('submit support and moderation reports');
    await _switchToProfile(
      tester,
      profileId: config.mainProfileId,
      label: 'main player',
    );
    expect(_currentUserId(), mainId);
    _logStage('submit support request from You');
    await _submitSupportRequest(tester, details: config.supportDetails);
    _logStage('submit moderation report for another player');
    await _submitModerationReport(
      tester,
      subjectId: config.partyTargetProfileId,
      details: config.reportDetails,
    );

    final preservedMatch = await _gameById(repository, config.matchGameId);
    expect(preservedMatch.status, 'FULL');
    expect(preservedMatch.confirmedCount, 14);
    expect(
      await _boundedRemoteStep(
        'verify preserved full-match booking',
        repository.getMyUpcomingBookingForGame(config.matchGameId),
      ),
      isNotNull,
      reason:
          'The full E2E match must remain intact for the referee/admin phase.',
    );
    _logStage('player journey complete');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

Future<void> _verifyCancellationThroughUi(
  WidgetTester tester,
  SupabaseOpenQueueRepository repository,
  StagingE2EConfig config,
) async {
  _logStage('book and cancel the isolated cancellation game');
  final game = await _gameById(repository, config.cancellationGameId);
  expect(game.confirmedCount, 0);
  final attackerSpots = game.spotsFor(OpenQueueRole.attacker);
  expect(attackerSpots, greaterThan(0));
  await _bookGameThroughUi(tester, game: game, role: OpenQueueRole.attacker);
  final booking = await _boundedRemoteStep(
    'load cancellation-game booking',
    repository.getMyUpcomingBookingForGame(game.id),
  );
  expect(booking, isNotNull);
  await _cancelCurrentBooking(tester);
  final cancelled = await _waitForCancelledBooking(booking!.id);
  expect(cancelled['status'], 'CANCELLED');
  expect(cancelled['cancelled_at'], isNotNull);
  expect(cancelled['refund_bps'], isNotNull);
  expect(cancelled['refund_amount_fils'], isNotNull);
  final reopened = await _gameById(repository, game.id);
  expect(reopened.status, 'OPEN');
  expect(reopened.confirmedCount, 0);
  expect(
    reopened.spotsFor(OpenQueueRole.attacker),
    attackerSpots,
    reason: 'Cancelling must reopen the attacker position immediately.',
  );
}

enum _SignedInDestination { home, onboarding }

Future<void> _ensureSignedOut(WidgetTester tester) async {
  final client = Supabase.instance.client;
  if (client.auth.currentSession != null) {
    await client.auth.signOut(scope: SignOutScope.local);
  }
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('fieldrush-create-account')),
    reason: 'The app did not return to the signed-out welcome screen.',
  );
}

Future<void> _verifyFixedOtpLogin(
  WidgetTester tester,
  StagingE2EConfig config,
) async {
  await tapWhenVisible(tester, find.byKey(const ValueKey('fieldrush-log-in')));
  await pumpUntilFound(tester, find.byKey(const ValueKey('fieldrush-phone')));
  // A full international number works with the default US country selector.
  await tester.enterText(
    find.byKey(const ValueKey('fieldrush-phone')),
    config.bootstrapPhone,
  );
  await _continueOnboarding(tester);
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('fieldrush-code')),
    reason: 'The fixed-code staging login did not reach OTP verification.',
  );
  await tester.enterText(
    find.byKey(const ValueKey('fieldrush-code')),
    config.devOtpCode,
  );
  await _continueOnboarding(tester);
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('home-screen')),
    reason: 'The fixed staging OTP did not create an authenticated session.',
  );
}

Future<void> _switchToProfile(
  WidgetTester tester, {
  required String profileId,
  required String label,
  _SignedInDestination expected = _SignedInDestination.home,
}) async {
  final client = Supabase.instance.client;
  final currentSession = client.auth.currentSession;
  if (currentSession == null) {
    throw TestFailure('Cannot switch to $label without a staging session.');
  }

  final response = await _boundedRemoteStep(
    'request session for $label',
    client.functions.invoke(
      'dev-switch-user',
      headers: {'Authorization': 'Bearer ${currentSession.accessToken}'},
      body: {'profile_id': profileId},
    ),
  );
  final data = response.data;
  if (data is! Map) {
    throw TestFailure('The staging switch for $label returned invalid data.');
  }
  final accessToken = data['access_token'];
  final refreshToken = data['refresh_token'];
  if (accessToken is! String || refreshToken is! String) {
    throw TestFailure('The staging switch for $label returned no session.');
  }

  await _boundedRemoteStep(
    'activate session for $label',
    client.auth.setSession(refreshToken, accessToken: accessToken),
  );
  expect(
    client.auth.currentUser?.id,
    profileId,
    reason: 'The staging switch did not activate the $label account.',
  );

  final destination = switch (expected) {
    _SignedInDestination.home => find.byKey(const ValueKey('home-screen')),
    _SignedInDestination.onboarding => find.byKey(
      const ValueKey('fieldrush-first-name'),
    ),
  };
  if (expected == _SignedInDestination.home) {
    await pumpUntilFound(
      tester,
      find.byKey(ValueKey(profileId)),
      reason: 'AuthGate did not mount Home for the $label account.',
    );
  }
  await pumpUntilFound(
    tester,
    destination,
    reason: expected == _SignedInDestination.home
        ? 'The $label account did not reach Home.'
        : 'The $label account was not reset to the start of onboarding.',
  );
}

Future<T> _boundedRemoteStep<T>(
  String label,
  Future<T> operation, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  debugPrint('[FIELD_E2E] START $label');
  try {
    final result = await operation.timeout(timeout);
    debugPrint('[FIELD_E2E] PASS $label');
    return result;
  } on TimeoutException {
    throw TestFailure('$label timed out after ${timeout.inSeconds} seconds.');
  }
}

Future<Map<String, dynamic>> _waitForCancelledBooking(
  String bookingId, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  const label = 'verify cancelled booking persistence';
  debugPrint('[FIELD_E2E] START $label');
  final deadline = DateTime.now().add(timeout);
  Map<String, dynamic>? latest;

  while (DateTime.now().isBefore(deadline)) {
    final response = await Supabase.instance.client
        .from('open_queue_bookings')
        .select(
          'status, cancelled_at, refund_bps, refund_percent, '
          'refund_amount_fils',
        )
        .eq('id', bookingId)
        .single();
    latest = Map<String, dynamic>.from(response);
    if (latest['status'] == 'CANCELLED') {
      debugPrint('[FIELD_E2E] PASS $label');
      return latest;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  throw TestFailure(
    '$label did not observe CANCELLED within ${timeout.inSeconds} seconds; '
    'last status was ${latest?['status'] ?? 'missing'}.',
  );
}

void _logStage(String label) {
  debugPrint('[FIELD_E2E] STAGE $label');
}

String _onboardingUsername(StagingE2EConfig config) =>
    'e2e_${config.onboardingProfileId.replaceAll('-', '').substring(0, 12)}';

String _onboardingEmail(StagingE2EConfig config) =>
    'e2e.${config.onboardingProfileId}@example.test';

Future<void> _continueOnboarding(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tapAfterScroll(
    tester,
    find.byKey(const ValueKey('fieldrush-continue')),
  );
}

Future<void> _completeOnboarding(
  WidgetTester tester,
  StagingE2EConfig config,
) async {
  await tester.enterText(
    find.byKey(const ValueKey('fieldrush-first-name')),
    'E2E',
  );
  await tester.enterText(
    find.byKey(const ValueKey('fieldrush-last-name')),
    'Onboarding',
  );
  await _continueOnboarding(tester);
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('fieldrush-username')),
  );
  await tester.enterText(
    find.byKey(const ValueKey('fieldrush-username')),
    _onboardingUsername(config),
  );
  await _continueOnboarding(tester);
  await pumpUntilFound(tester, find.byKey(const ValueKey('fieldrush-month')));
  await tester.enterText(find.byKey(const ValueKey('fieldrush-month')), '01');
  await tester.enterText(find.byKey(const ValueKey('fieldrush-day')), '01');
  await tester.enterText(find.byKey(const ValueKey('fieldrush-year')), '2000');
  await _continueOnboarding(tester);
  await pumpUntilFound(tester, find.byKey(const ValueKey('fieldrush-email')));
  await tester.enterText(
    find.byKey(const ValueKey('fieldrush-email')),
    _onboardingEmail(config),
  );
  await _continueOnboarding(tester);
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('fieldrush-accept-policies')),
  );
  await tapAfterScroll(
    tester,
    find.byKey(const ValueKey('fieldrush-accept-policies')),
  );
  await _continueOnboarding(tester);
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('home-screen')),
    reason: 'Completing onboarding did not open Home.',
  );
}

Future<void> _verifyCompletedAccount(StagingE2EConfig config) async {
  final client = Supabase.instance.client;
  final account = await _boundedRemoteStep(
    'verify authoritative Fieldrush account completion',
    client.rpc('get_my_fieldrush_account'),
  );
  expect(account, isA<Map>());
  final data = Map<String, dynamic>.from(account as Map);
  expect(data['first_name'], 'E2E');
  expect(data['last_name'], 'Onboarding');
  expect(data['username'], _onboardingUsername(config));
  expect(data['date_of_birth'], '2000-01-01');
  expect(data['email'], _onboardingEmail(config));
  expect(data['phone_verified'], isTrue);
  expect(data['email_verified'], isFalse);
  expect(data['onboarding_completed'], isTrue);

  final profile = await _boundedRemoteStep(
    'verify public name protects the full last name',
    client
        .from('profiles')
        .select('display_name')
        .eq('id', config.onboardingProfileId)
        .single(),
  );
  expect(profile['display_name'], 'E2E O.');
}

Future<OpenQueueGame> _gameById(
  SupabaseOpenQueueRepository repository,
  String gameId,
) async {
  final games = await _boundedRemoteStep(
    'load solo-game feed for $gameId',
    repository.listMarketGames('America/Phoenix'),
  );
  try {
    return games.firstWhere((game) => game.id == gameId);
  } on StateError {
    throw TestFailure(
      'The staging fixture did not expose upcoming game $gameId.',
    );
  }
}

Future<void> _verifyFixtureDetailLink(
  WidgetTester tester,
  OpenQueueGame game,
) async {
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('field-bottom-nav-item-1')),
  );
  await pumpUntilFound(tester, find.byType(FieldrushFixturePage));
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('fixtures-next-day')),
    reason: 'The server-backed fixture calendar did not load.',
  );
  final local = game.localStartsAt;
  final dateKey =
      '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  final date = find.byKey(ValueKey('fixtures-date-$dateKey'));
  final calendar = find.descendant(
    of: find.byType(FieldrushFixturePage),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.right,
    ),
  );
  await tester.scrollUntilVisible(
    date,
    160,
    scrollable: calendar,
    maxScrolls: 80,
  );
  await tapWhenVisible(tester, date);
  await tapAfterScroll(tester, find.byKey(ValueKey('solo-fixture-${game.id}')));
  await _expectGameDetail(tester, game.id);
  expect(
    find.byType(FieldrushBookingFlow),
    findsNothing,
    reason: 'Fixture taps must open game details rather than a new booking.',
  );
  await pumpUntilFound(tester, find.text('Leave game'));
  await _goHomeFromGame(tester);
}

Future<void> _verifyLeaderboards(WidgetTester tester) async {
  final repository = SupabaseLeaderboardRepository();
  final catalog = await _boundedRemoteStep(
    'read authoritative season calendar',
    repository.loadSeasons(),
  );
  final season = catalog.currentSeason;
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('field-bottom-nav-item-3')),
  );
  final ratings = await _boundedRemoteStep(
    'read authoritative independent player ratings',
    repository.loadPlayerRatings(season: season),
  );
  final cityId = ratings.primaryCityId ?? ratings.preferredCityId ?? 'phoenix';
  var content = await _loadedRanks(tester, season, cityId: cityId);
  expect(
    content.cityId,
    cityId,
    reason: 'Ranks must start in the player’s city.',
  );
  final city = content.cities.singleWhere((city) => city.id == cityId);
  final expected = await _boundedRemoteStep(
    'read authoritative city outfield ranks',
    repository.loadRatingPage(
      season: season,
      track: RatingTrack.outfield,
      cityId: cityId,
    ),
  );
  _assertRanksMatchServer(
    content,
    expected,
    ratings.forScope(RatingTrack.outfield, cityId),
  );
  expect(find.byKey(const ValueKey('ranks-city')), findsOneWidget);

  // The city switcher is a live global/city menu; both scopes must display the
  // server's standings rather than reuse whichever city happened to load first.
  await tapWhenVisible(tester, find.byKey(const ValueKey('ranks-city')));
  await tapWhenVisible(tester, _rankCityOption('global'));
  content = await _loadedRanks(tester, season, cityId: null);
  final global = await _boundedRemoteStep(
    'read authoritative global outfield ranks',
    repository.loadRatingPage(season: season, track: RatingTrack.outfield),
  );
  _assertRanksMatchServer(
    content,
    global,
    ratings.forScope(RatingTrack.outfield, null),
  );
  expect(
    content.rewards,
    isNull,
    reason: 'Global must not advertise city prizes.',
  );
  await tapWhenVisible(tester, find.byKey(const ValueKey('ranks-city')));
  await tapWhenVisible(tester, _rankCityOption(cityId));
  content = await _loadedRanks(tester, season, cityId: cityId);
  expect(
    content.cities.singleWhere((value) => value.id == cityId).label,
    city.label,
  );

  final rankPage = find.byType(FieldrushLeaderboardContent);
  await tapAfterScroll(
    tester,
    find.descendant(of: rankPage, matching: find.text('Keepers')),
  );
  content = await _loadedRanks(
    tester,
    season,
    track: RatingTrack.goalkeeper,
    cityId: cityId,
  );
  final keepers = await _boundedRemoteStep(
    'read authoritative city keeper ranks',
    repository.loadRatingPage(
      season: season,
      track: RatingTrack.goalkeeper,
      cityId: cityId,
    ),
  );
  _assertRanksMatchServer(
    content,
    keepers,
    ratings.forScope(RatingTrack.goalkeeper, cityId),
  );
  await tapAfterScroll(
    tester,
    find.descendant(of: rankPage, matching: find.text('Outfield')),
  );
  content = await _loadedRanks(tester, season, cityId: cityId);
  _assertRanksMatchServer(
    content,
    expected,
    ratings.forScope(RatingTrack.outfield, cityId),
  );

  await tapAfterScroll(
    tester,
    find.descendant(of: rankPage, matching: find.text('Clans')),
  );
  await pumpUntilFound(tester, find.text('Clan ladders are coming'));
  expect(tester.widget<FieldrushLeaderboardContent>(rankPage).clans, isTrue);
  await tapAfterScroll(tester, find.text('See solo ladder'));
  content = await _loadedRanks(tester, season, cityId: cityId);
  expect(content.clans, isFalse);

  if (expected.players.isEmpty) {
    if (content.rewards == null) {
      await scrollUntilFound(
        tester,
        find.byKey(const ValueKey('ranks-empty-ranked')),
      );
    } else {
      for (var place = 1; place <= 3; place++) {
        await scrollUntilFound(
          tester,
          find.byKey(ValueKey('ranks-prize-open-$place')),
        );
      }
      expect(content.rewards!.players, isEmpty);
    }
    await scrollUntilFound(tester, find.text('IN PLACEMENT'));
    expect(content.placementError, isNull);
    expect(content.totalCount, 0);
  } else {
    final top = expected.players.first;
    final topRow = _rankPlayerRow(top.profileId);
    await scrollUntilFound(tester, topRow);
    expect(
      find.descendant(
        of: topRow,
        matching: find.byWidgetPredicate((widget) {
          if (widget is! Text) return false;
          final text = widget.data?.replaceAll(',', '');
          return text == '${top.skillRating}' ||
              text == '${top.divisionLabel} · ${top.skillRating} skill rating';
        }),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: topRow,
        matching: find.text(
          top.profileId == _currentUserId() ? 'You' : top.displayName,
        ),
      ),
      findsOneWidget,
    );
    await tapAfterScroll(tester, topRow);
    if (top.profileId == _currentUserId()) {
      await pumpUntilFound(tester, find.byType(FieldrushYouScreen));
      await pumpUntilFound(tester, find.byKey(const ValueKey('you-content')));
      await tapWhenVisible(
        tester,
        find.byKey(const ValueKey('field-bottom-nav-item-3')),
      );
    } else {
      await pumpUntilFound(tester, find.byType(ProfileScreen));
      expect(
        tester.widget<ProfileScreen>(find.byType(ProfileScreen).last).profileId,
        top.profileId,
      );
      await returnFromViewedPlayerProfile(
        tester,
        expectedProfileId: top.profileId,
      );
    }
    content = await _loadedRanks(tester, season, cityId: cityId);
    if (expected.totalCount > 3) {
      await tapAfterScroll(tester, find.byKey(const ValueKey('ranks-more')));
      await pumpUntilFound(
        tester,
        find.byWidgetPredicate(
          (widget) =>
              widget is FieldrushLeaderboardContent &&
              !widget.loadingMore &&
              widget.visibleCount >= 20,
        ),
        reason: 'Expanding the city ladder did not expose its ranked rows.',
      );
      content = tester.widget<FieldrushLeaderboardContent>(rankPage);
      expect(content.pageError, isNull);
      final featured = (content.rewards?.players ?? expected.players.take(3))
          .map((player) => player.profileId)
          .toSet();
      final rows = expected.players
          .where((player) => !featured.contains(player.profileId))
          .take(20);
      for (final player in rows) {
        await scrollUntilFound(
          tester,
          find.byKey(ValueKey('ranks-player-${player.profileId}')),
          maxScrolls: 60,
          reason:
              'A server-returned player disappeared from the expanded leaderboard.',
        );
      }
    }
  }

  final seasons = catalog.visibleSeasons;
  final seasonIndex = seasons.indexWhere((value) => value.id == season.id);
  if (seasonIndex > 0) {
    final previous = seasons[seasonIndex - 1];
    await tapAfterScroll(tester, find.byTooltip('Previous season'));
    content = await _loadedRanks(tester, previous, cityId: cityId);
    final oldPage = await _boundedRemoteStep(
      'read authoritative previous-season ranks',
      repository.loadRatingPage(
        season: previous,
        track: RatingTrack.outfield,
        cityId: cityId,
      ),
    );
    final oldRating = await _boundedRemoteStep(
      'read authoritative previous-season placement',
      repository.loadPlayerRatings(season: previous),
    );
    _assertRanksMatchServer(
      content,
      oldPage,
      oldRating.forScope(RatingTrack.outfield, cityId),
    );
    await tapAfterScroll(tester, find.byTooltip('Next season'));
    await _loadedRanks(tester, season, cityId: cityId);
  }

  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('field-bottom-nav-item-0')),
  );
  await pumpUntilFound(tester, find.byKey(const ValueKey('home-screen')));
}

Finder _rankCityOption(String value) => find.byWidgetPredicate(
  (widget) => widget is PopupMenuItem<String> && widget.value == value,
);

Finder _rankPlayerRow(String profileId) {
  final keys = {
    ValueKey('ranks-podium-$profileId'),
    ValueKey('ranks-player-$profileId'),
    ValueKey('ranks-prize-$profileId'),
  };
  return find.byWidgetPredicate((widget) => keys.contains(widget.key));
}

Future<FieldrushLeaderboardContent> _loadedRanks(
  WidgetTester tester,
  LeaderboardSeason season, {
  RatingTrack track = RatingTrack.outfield,
  String? cityId = 'phoenix',
}) async {
  final content = find.byWidgetPredicate(
    (widget) =>
        widget is FieldrushLeaderboardContent &&
        widget.season.id == season.id &&
        widget.track == track &&
        widget.cityId == cityId &&
        !widget.loading,
  );
  await pumpUntilFound(
    tester,
    content,
    timeout: const Duration(seconds: 45),
    reason: 'The ${season.label} leaderboard did not finish loading.',
  );
  final widget = tester.widget<FieldrushLeaderboardContent>(content);
  expect(
    widget.error,
    isNull,
    reason:
        'Ranks returned a loading failure rather than authoritative season data.',
  );
  expect(
    widget.rewardsError,
    isNull,
    reason: 'The selected city and role must load its season reward settings.',
  );
  return widget;
}

void _assertRanksMatchServer(
  FieldrushLeaderboardContent content,
  PlayerRatingLeaderboardPage page,
  PlayerRatingLeaderboardEntry rating,
) {
  expect(content.totalCount, page.totalCount);
  expect(
    content.players.map((player) => player.profileId),
    page.players.map((player) => player.profileId),
  );
  expect(
    content.players.map((player) => player.skillRating),
    page.players.map((player) => player.skillRating),
  );
  expect(
    content.players.map((player) => player.rank),
    page.players.map((player) => player.rank),
  );
  expect(
    content.players.map((player) => player.matchesPlayed),
    page.players.map((player) => player.matchesPlayed),
  );
  expect(
    content.players.every(
      (player) =>
          player.isRanked &&
          (content.cityId == null || player.region == content.cityId),
    ),
    isTrue,
  );
  expect(
    content.currentRating,
    isNotNull,
    reason:
        'The player’s real seasonal placement must load alongside the ladder.',
  );
  expect(content.currentRating!.profileId, _currentUserId());
  expect(content.currentRating!.matchesPlayed, rating.matchesPlayed);
  expect(content.currentRating!.skillRating, rating.skillRating);
  expect(content.currentRating!.wins, rating.wins);
  expect(content.currentRating!.draws, rating.draws);
  expect(content.currentRating!.losses, rating.losses);
  expect(content.currentRating!.rank, rating.rank);
  expect(content.currentRating!.region, rating.region);
}

Future<void> _bookGameThroughUi(
  WidgetTester tester, {
  required OpenQueueGame game,
  required OpenQueueRole role,
}) async {
  expect(
    game.canBook(role),
    isTrue,
    reason: '${role.code} must be available in ${game.id} before UI booking.',
  );
  expect(game.timezone, 'America/Phoenix');
  expect(game.currency, 'USD');
  expect(game.capacity, 14);
  final repository = SupabaseOpenQueueRepository();
  await _expectNoBooking(
    repository,
    game.id,
    'before entering the booking flow',
  );
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('field-bottom-nav-item-1')),
  );
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('fixtures-play-action')),
  );
  await pumpUntilFound(tester, find.text('Start a game'));
  expect(find.byKey(const ValueKey('play-clan-choice')), findsOneWidget);
  await tapWhenVisible(tester, find.byKey(const ValueKey('play-solo-choice')));

  await pumpUntilFound(tester, find.byType(FieldrushBookingFlow));
  expect(find.text('STEP 1 OF 3'), findsOneWidget);
  await pumpUntilFound(
    tester,
    find.byKey(ValueKey('booking-position-${role.code}')),
  );
  await tapWhenVisible(
    tester,
    find.byKey(ValueKey('booking-position-${role.code}')),
  );
  expect(find.text('1 selected'), findsOneWidget);
  expect(find.byKey(const ValueKey('booking-position-MID')), findsNothing);
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('booking-see-games')),
    reason: 'The selected positions never enabled matching games.',
  );
  await pumpUntilFound(tester, find.text('STEP 2 OF 3'));

  final joinAction = find.byKey(ValueKey('booking-game-${game.id}'));
  await scrollUntilFound(
    tester,
    joinAction,
    maxScrolls: 60,
    reason: 'The E2E game was not offered for ${role.label}.',
  );
  expect(
    find.descendant(
      of: joinAction,
      matching: find.text('Your spot · ${bookingRoleName(role)}'),
    ),
    findsOneWidget,
  );
  await tapAfterScroll(tester, joinAction);
  await pumpUntilFound(
    tester,
    find.text('STEP 3 OF 3'),
    reason: 'Choosing the game did not open the review step.',
  );
  expect(find.text(game.calendarDateLabel), findsWidgets);
  expect(find.text(bookingRoleName(role)), findsOneWidget);
  expect(find.text('7v7'), findsOneWidget);
  await _expectNoBooking(
    repository,
    game.id,
    'after selecting a position and reviewing the game',
  );
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('booking-continue-payment')),
    reason: 'The review step never enabled checkout.',
  );
  await pumpUntilFound(tester, find.byType(FieldrushCheckoutSheet));
  final quote = await _boundedRemoteStep(
    'verify the authoritative checkout total',
    repository.previewBookingCost(gameId: game.id, role: role),
  );
  expect(quote.currency, 'USD');
  await pumpUntilFound(
    tester,
    find.text('Continue to Pay · ${quote.totalLabel}'),
  );
  await _expectNoBooking(
    repository,
    game.id,
    'while the exact-price checkout is still awaiting confirmation',
  );
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('open-queue-confirm-payment')),
    reason: 'The staging test checkout never became available.',
  );
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('booking-view-game')),
    reason: 'Verified payment did not reach the booking confirmation.',
  );
  expect(find.text('You’re in'), findsOneWidget);
  final confirmed = await _boundedRemoteStep(
    'verify the server-confirmed reservation',
    repository.getMyUpcomingBookingForGame(game.id),
  );
  expect(confirmed, isNotNull);
  expect(confirmed!.gameId, game.id);
  expect(confirmed.role, role);
  expect(confirmed.status, 'CONFIRMED');
  expect(confirmed.game.currency, 'USD');
  expect(confirmed.amountPaidFils, quote.totalFils);
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('booking-view-game')),
  );
  await _expectGameDetail(tester, game.id);
  await scrollUntilFound(
    tester,
    find.textContaining(game.venue),
    reason: 'The game detail did not show its actual venue.',
  );
  await pumpUntilFound(
    tester,
    find.text('Leave game'),
    reason: 'The confirmed reservation was not reflected on the game page.',
  );
}

Future<void> _expectNoBooking(
  SupabaseOpenQueueRepository repository,
  String gameId,
  String stage,
) async {
  final booking = await _boundedRemoteStep(
    'verify no reservation $stage',
    repository.getMyUpcomingBookingForGame(gameId),
  );
  expect(
    booking,
    isNull,
    reason:
        'Merely selecting or reviewing a game must not reserve a position $stage.',
  );
}

Future<void> _expectGameDetail(WidgetTester tester, String gameId) async {
  await pumpUntilFound(
    tester,
    find.byType(FieldrushGameDetailScreen),
    reason: 'The Fieldrush game page did not open.',
  );
  expect(
    tester
        .widget<FieldrushGameDetailScreen>(
          find.byType(FieldrushGameDetailScreen).last,
        )
        .gameId,
    gameId,
    reason: 'The game page opened a different fixture.',
  );
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('fieldrush-game-hero')),
  );
}

Future<void> _goHomeFromGame(WidgetTester tester) async {
  await tapWhenVisible(
    tester,
    find.descendant(
      of: find.byType(FieldrushGameDetailScreen),
      matching: find.byKey(const ValueKey('field-bottom-nav-item-0')),
    ),
  );
  await pumpUntilAbsent(
    tester,
    find.byType(FieldrushGameDetailScreen),
    reason: 'Game navigation did not return to Home.',
  );
  await pumpUntilFound(tester, find.byKey(const ValueKey('home-screen')));
}

Future<void> _createAndSendPartyInvite(
  WidgetTester tester, {
  required String gameId,
  required String inviteeId,
}) async {
  final party = find.byKey(const ValueKey('fieldrush-game-party'));
  // Party context loads independently of the game hero. Keep the finder
  // unsliced so an empty/loading frame can be polled instead of throwing
  // StateError from Finder.first before tapAfterScroll can wait or scroll.
  final inviteSlot = find.descendant(of: party, matching: find.text('Invite'));
  await tapAfterScroll(
    tester,
    inviteSlot,
    reason:
        'The booked player did not receive an available party invitation slot.',
  );
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('party-invite-sheet-close')),
    reason: 'Creating a party did not open the real invitation picker.',
  );
  final created = await _boundedRemoteStep(
    'verify party creation',
    SupabaseOpenQueueRepository().getPartyContext(gameId),
  );
  expect(created.myParty, isNotNull);
  expect(created.myParty!.ownerProfileId, _currentUserId());
  expect(created.myParty!.isOwner, isTrue);
  await sendPartyInviteThroughUi(tester, inviteeId: inviteeId);
  final invited = await _boundedRemoteStep(
    'verify persisted party invitation',
    SupabaseOpenQueueRepository().getPartyContext(gameId),
  );
  expect(
    invited.myParty!.pendingMembers.map((member) => member.profileId),
    contains(inviteeId),
  );
}

Future<void> _acceptPartyInvite(WidgetTester tester, String gameId) async {
  await tapAfterScroll(
    tester,
    find.descendant(
      of: find.byKey(ValueKey('home-party-invite-$gameId')),
      matching: find.byType(FilledButton),
    ),
    timeout: const Duration(seconds: 35),
    reason: 'The invited player did not receive the party alert on Home.',
  );
  await _expectGameDetail(tester, gameId);
  final party = find.byKey(const ValueKey('fieldrush-game-party'));
  final accept = find.descendant(
    of: party,
    matching: find.widgetWithText(FilledButton, 'Accept'),
  );
  await _tapEnabledFilledButton(
    tester,
    accept,
    reason: 'The game page did not expose the incoming party invite.',
  );
  await pumpUntilAbsent(
    tester,
    accept,
    reason: 'The accepted party invitation remained pending.',
  );
  final accepted = await _boundedRemoteStep(
    'verify persisted party acceptance',
    SupabaseOpenQueueRepository().getPartyContext(gameId),
  );
  expect(accepted.myParty, isNotNull);
  expect(accepted.myParty!.isOwner, isFalse);
  expect(accepted.myParty!.acceptedCount, 2);
  final membership = accepted.myParty!.members.singleWhere(
    (member) => member.profileId == _currentUserId(),
  );
  expect(membership.status, OpenQueuePartyMemberStatus.accepted);
  expect(accepted.receivedInvites, isEmpty);
  await expectAcceptedPartyMembershipVisible(tester, membership: membership);
  await _goHomeFromGame(tester);
}

Future<void> _submitSupportRequest(
  WidgetTester tester, {
  required String details,
}) async {
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('field-bottom-nav-item-4')),
  );

  await pumpUntilFound(
    tester,
    find.byType(FieldrushYouScreen),
    reason: 'The You tab did not become active.',
  );
  final profileContent = find.byKey(const ValueKey('you-content'));
  final profileError = find.text('Could not load your profile');
  await pumpUntilAny(
    tester,
    [profileContent, profileError],
    timeout: const Duration(seconds: 45),
    reason: 'You did not finish loading.',
  );
  if (profileError.evaluate().isNotEmpty) {
    throw TestFailure('You returned its load-error state.');
  }

  await scrollUntilFound(
    tester,
    find.text('Help & support'),
    maxScrolls: 60,
    reason: 'You did not expose Help & support.',
  );
  await tapAfterScroll(tester, find.text('Help & support'));
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('contact-support-sheet')),
  );
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('support-category-feedback')),
  );
  await tester.enterText(
    find.byKey(const ValueKey('support-details')),
    details,
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('support-submit')),
  );
  await pumpUntilAbsent(
    tester,
    find.byKey(const ValueKey('contact-support-sheet')),
    reason: 'The support request was not accepted.',
  );
  await pumpUntilFound(tester, find.textContaining('Request sent · reference'));

  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('field-bottom-nav-item-0')),
  );
  await pumpUntilFound(tester, find.byKey(const ValueKey('home-screen')));
}

Future<void> _submitModerationReport(
  WidgetTester tester, {
  required String subjectId,
  required String details,
}) async {
  final routeFuture =
      Navigator.of(
        tester.element(find.byKey(const ValueKey('home-screen'))),
      ).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: ProfileScreen(
              profileId: subjectId,
              profileRepository: SupabaseProfileRepository(),
              moderationRepository: SupabaseModerationRepository(),
            ),
          ),
        ),
      );
  await tester.pump();

  await openViewedPlayerReport(tester, expectedProfileId: subjectId);
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('moderation-report-sheet')),
  );
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('moderation-category-harassment')),
  );
  await tester.enterText(
    find.byKey(const ValueKey('moderation-report-details')),
    details,
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('moderation-report-submit')),
  );
  await pumpUntilAbsent(
    tester,
    find.byKey(const ValueKey('moderation-report-sheet')),
    reason: 'The player report was not accepted.',
  );
  await pumpUntilFound(
    tester,
    find.textContaining('Report sent privately · reference'),
  );

  Navigator.of(tester.element(find.byType(ProfileScreen).last)).pop();
  await tester.pump();
  await routeFuture;
  await pumpUntilFound(tester, find.byKey(const ValueKey('home-screen')));
}

Future<void> _cancelCurrentBooking(WidgetTester tester) async {
  expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('game-main-action')),
  );
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('field-confirmation-dialog')),
    reason: 'Cancellation did not show its server-backed consequence preview.',
  );
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('field-confirmation-confirm')),
  );

  await tester.pump(const Duration(milliseconds: 800));
  if (find
      .byKey(const ValueKey('field-confirmation-dialog'))
      .evaluate()
      .isNotEmpty) {
    await tapWhenVisible(
      tester,
      find.byKey(const ValueKey('field-confirmation-confirm')),
    );
  }
  await pumpUntilAbsent(
    tester,
    find.byKey(const ValueKey('field-confirmation-dialog')),
    reason: 'The cancellation confirmation did not close.',
  );
  await pumpUntilAbsent(
    tester,
    find.text('Leave game'),
    reason: 'The game page still shows the cancelled reservation as active.',
  );
  await pumpUntilFound(
    tester,
    find.textContaining('Join ·'),
    reason: 'Cancelling did not restore the available-game action.',
  );
  await _goHomeFromGame(tester);
}

Future<void> _tapEnabledFilledButton(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 35),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  await scrollUntilFound(
    tester,
    finder,
    maxScrolls: 60,
    timeout: timeout,
    reason: reason,
  );
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) {
      final button = tester.widget<FilledButton>(finder);
      if (button.onPressed != null) {
        await tapWhenVisible(
          tester,
          finder,
          timeout: deadline.difference(DateTime.now()),
          reason: reason,
        );
        return;
      }
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  throw TestFailure(reason ?? 'The expected action remained disabled.');
}

String _currentUserId() {
  final id = Supabase.instance.client.auth.currentUser?.id;
  if (id == null || id.isEmpty) {
    throw TestFailure('The staging session has no authenticated user.');
  }
  return id;
}
