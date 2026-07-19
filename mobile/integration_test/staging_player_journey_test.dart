import 'dart:async';

import 'package:field/main.dart' as app;
import 'package:field/src/moderation/moderation_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'helpers/staging_test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hosted staging player journey', (tester) async {
    final config = StagingE2EConfig.fromEnvironment()..validate();

    _logStage('launch app and verify signed-out state');
    await app.main();
    await _ensureSignedOut(tester);

    _logStage('verify fixed OTP login');
    await _verifyFixedOtpLogin(tester, config);
    _logStage('complete onboarding');
    await _switchToProfile(
      tester,
      profileId: config.onboardingProfileId,
      label: 'onboarding player',
      expected: _SignedInDestination.onboarding,
      resetOnboardingMetadata: true,
    );
    await _completeOnboarding(tester);
    expect(
      Supabase.instance.client.auth.currentUser?.userMetadata?['display_name'],
      'E2E Onboarding',
    );
    expect(
      Supabase.instance.client.auth.currentUser?.userMetadata?['date_of_birth'],
      isNotNull,
    );

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

    _logStage('book the main player and send a party invite');
    await _switchToProfile(
      tester,
      profileId: config.mainProfileId,
      label: 'main player',
    );
    final mainId = _currentUserId();
    final matchGame = await _gameById(repository, config.matchGameId);
    expect(matchGame.confirmedCount, 11);
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
      inviteeId: config.partyTargetProfileId,
    );
    await tapAfterScroll(tester, find.byKey(const ValueKey('booking-go-home')));
    await pumpUntilFound(
      tester,
      find.byKey(ValueKey('home-solo-booking-${matchBooking!.id}')),
      reason: 'The new match booking did not appear on Home.',
    );

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
    await _submitSupportRequest(tester, details: config.supportDetails);
    await _submitModerationReport(
      tester,
      subjectId: config.partyTargetProfileId,
      details: config.reportDetails,
    );

    _logStage('book and cancel the isolated cancellation game');
    final cancellationGame = await _gameById(
      repository,
      config.cancellationGameId,
    );
    expect(cancellationGame.confirmedCount, 0);
    final openAttackerSpots = cancellationGame.spotsFor(OpenQueueRole.attacker);
    expect(openAttackerSpots, greaterThan(0));

    await _bookGameThroughUi(
      tester,
      game: cancellationGame,
      role: OpenQueueRole.attacker,
    );
    final cancellationBooking = await _boundedRemoteStep(
      'load cancellation-game booking',
      repository.getMyUpcomingBookingForGame(cancellationGame.id),
    );
    expect(cancellationBooking, isNotNull);
    await _cancelCurrentBooking(tester);

    final cancelledBooking = await _boundedRemoteStep(
      'verify cancelled booking persistence',
      Supabase.instance.client
          .from('open_queue_bookings')
          .select(
            'status, cancelled_at, refund_bps, refund_percent, '
            'refund_amount_fils',
          )
          .eq('id', cancellationBooking!.id)
          .single(),
    );
    expect(cancelledBooking['status'], 'CANCELLED');
    expect(cancelledBooking['cancelled_at'], isNotNull);
    expect(cancelledBooking['refund_bps'], isNotNull);
    expect(cancelledBooking['refund_amount_fils'], isNotNull);

    final reopenedGame = await _gameById(repository, config.cancellationGameId);
    expect(reopenedGame.status, 'OPEN');
    expect(reopenedGame.confirmedCount, 0);
    expect(
      reopenedGame.spotsFor(OpenQueueRole.attacker),
      openAttackerSpots,
      reason: 'Cancelling must reopen the attacker position immediately.',
    );

    final preservedMatch = await _gameById(repository, config.matchGameId);
    expect(preservedMatch.status, 'FULL');
    expect(preservedMatch.confirmedCount, 12);
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

enum _SignedInDestination { home, onboarding }

Future<void> _ensureSignedOut(WidgetTester tester) async {
  final client = Supabase.instance.client;
  if (client.auth.currentSession != null) {
    await client.auth.signOut(scope: SignOutScope.local);
  }
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('auth-get-started')),
    reason: 'The app did not return to the signed-out welcome screen.',
  );
}

Future<void> _verifyFixedOtpLogin(
  WidgetTester tester,
  StagingE2EConfig config,
) async {
  await tapWhenVisible(tester, find.byKey(const ValueKey('auth-get-started')));
  await pumpUntilFound(tester, find.byKey(const ValueKey('auth-phone-field')));
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('auth-country-picker')),
  );
  await pumpUntilFound(tester, find.text('Bahrain'));
  await tester.pump(const Duration(milliseconds: 450));
  await tester.tap(find.text('Bahrain').last);
  await tester.pump(const Duration(milliseconds: 350));

  await tester.enterText(
    find.byKey(const ValueKey('auth-phone-field')),
    config.bahrainBootstrapLocalNumber,
  );
  await tester.pump();
  await tapWhenVisible(tester, find.byKey(const ValueKey('auth-send-code')));
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('auth-otp-field')),
    reason: 'The fixed-code staging login did not reach OTP verification.',
  );
  await tester.enterText(
    find.byKey(const ValueKey('auth-otp-field')),
    config.devOtpCode,
  );
  await tester.pump();
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
  bool resetOnboardingMetadata = false,
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
      body: {
        'profile_id': profileId,
        if (resetOnboardingMetadata) 'reset_onboarding_metadata': true,
      },
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
      const ValueKey('auth-name-field'),
    ),
  };
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

void _logStage(String label) {
  debugPrint('[FIELD_E2E] STAGE $label');
}

Future<void> _completeOnboarding(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('auth-name-field')),
    'E2E Onboarding',
  );
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('date-of-birth-selector')),
  );
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('date-of-birth-selector')),
  );
  await pumpUntilFound(tester, find.text('OK'));
  await tester.tap(find.text('OK'));
  await tester.pump();
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('auth-save-date-of-birth')),
  );
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('home-screen')),
    reason: 'Completing onboarding did not open Home.',
  );
}

Future<OpenQueueGame> _gameById(
  SupabaseOpenQueueRepository repository,
  String gameId,
) async {
  final games = await _boundedRemoteStep(
    'load solo-game feed for $gameId',
    repository.listGames(),
  );
  try {
    return games.firstWhere((game) => game.id == gameId);
  } on StateError {
    throw TestFailure(
      'The staging fixture did not expose upcoming game $gameId.',
    );
  }
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
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('field-bottom-nav-item-1')),
  );
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('fixtures-play-action')),
  );
  await tapWhenVisible(tester, find.byKey(const ValueKey('play-solo-choice')));

  final roleSlug = role.code.toLowerCase();
  await pumpUntilFound(
    tester,
    find.byKey(ValueKey('open-queue-main-role-$roleSlug')),
  );
  await tapWhenVisible(
    tester,
    find.byKey(ValueKey('open-queue-main-role-$roleSlug')),
  );
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('open-queue-see-matching-games')),
  );

  final joinAction = find.byKey(
    ValueKey('open-queue-join-${game.id}-$roleSlug'),
  );
  await scrollUntilFound(
    tester,
    joinAction,
    maxScrolls: 60,
    reason: 'The E2E game was not offered for ${role.label}.',
  );
  await _tapEnabledFilledButton(
    tester,
    joinAction,
    reason: 'The ${role.label} booking action never became available.',
  );
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('open-queue-continue-to-checkout')),
    reason: 'The booking-cost preview never enabled checkout.',
  );
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('open-queue-confirm-payment')),
    reason: 'The staging test checkout never became available.',
  );
  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('booking-player-status-card')),
    reason: 'Booking did not reach its confirmation details.',
  );
  await scrollUntilFound(
    tester,
    find.text(game.venue),
    reason: 'The booking details did not show the booked venue.',
  );
  expect(find.text(game.venue), findsWidgets);
}

Future<void> _createAndSendPartyInvite(
  WidgetTester tester, {
  required String inviteeId,
}) async {
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('create-open-queue-party')),
    reason: 'A newly booked player could not create a party.',
  );
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('invite-open-queue-party-player')),
    reason: 'The party did not expose its invite action.',
  );
  final inviteAction = find.byKey(ValueKey('invite-party-player-$inviteeId'));
  await scrollUntilFound(
    tester,
    inviteAction,
    reason: 'The pre-booked E2E player was not listed for a party invite.',
  );
  await _tapEnabledFilledButton(
    tester,
    inviteAction,
    reason: 'The pre-booked E2E player was not eligible for a party.',
  );
  await pumpUntilFound(
    tester,
    find.text('Sent'),
    reason: 'The party invitation was not confirmed in the UI.',
  );
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('party-invite-sheet-close')),
  );
}

Future<void> _acceptPartyInvite(WidgetTester tester, String gameId) async {
  await tapWhenVisible(
    tester,
    find.byKey(ValueKey('home-party-invite-$gameId')),
    timeout: const Duration(seconds: 35),
    reason: 'The invited player did not receive the party alert on Home.',
  );
  await tapAfterScroll(
    tester,
    find.byKey(const ValueKey('open-queue-party-invite-indicator')),
    reason: 'Booking details did not show the incoming party invite.',
  );
  await _tapEnabledFilledButton(
    tester,
    find.byKey(const ValueKey('accept-open-queue-party-invite')),
  );
  await pumpUntilAbsent(
    tester,
    find.byKey(const ValueKey('open-queue-party-invite')),
    reason: 'The accepted party invitation remained pending.',
  );
  expect(find.byKey(const ValueKey('open-queue-party-count')), findsOneWidget);
  await tapAfterScroll(tester, find.byKey(const ValueKey('booking-go-home')));
  await pumpUntilFound(tester, find.byKey(const ValueKey('home-screen')));
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
    find.byKey(const ValueKey('profile-support-action')),
    timeout: const Duration(seconds: 35),
    reason: 'Profile did not expose Help & support.',
  );
  await tapAfterScroll(
    tester,
    find.byKey(const ValueKey('profile-support-action')),
  );
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
  tester.testTextInput.hide();
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

  await pumpUntilFound(
    tester,
    find.byKey(const ValueKey('profile-options-menu')),
    reason: 'The party target profile did not load its options menu.',
  );
  await tester.tap(find.byKey(const ValueKey('profile-options-menu')));
  await tester.pump();
  await tapWhenVisible(
    tester,
    find.byKey(const ValueKey('profile-report-action')),
  );
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
  tester.testTextInput.hide();
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
  await tapAfterScroll(tester, find.byKey(const ValueKey('booking-cancel')));
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
    find.byKey(const ValueKey('booking-player-status-card')),
    reason: 'The cancelled booking details did not close.',
  );
}

Future<void> _tapEnabledFilledButton(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 35),
  String? reason,
}) async {
  await scrollUntilFound(tester, finder, maxScrolls: 60, reason: reason);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final button = tester.widget<FilledButton>(finder);
    if (button.onPressed != null) {
      await tapAfterScroll(tester, finder, reason: reason);
      return;
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
