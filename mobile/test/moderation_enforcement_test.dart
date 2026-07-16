import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:field/src/auth/auth_gate.dart';
import 'package:field/src/auth/auth_repository.dart';
import 'package:field/src/home/home_screen.dart';
import 'package:field/src/moderation/account_restriction_screen.dart';
import 'package:field/src/moderation/moderation.dart';
import 'package:field/src/moderation/moderation_repository.dart';

void main() {
  group('ModerationStatus', () {
    test('parses canonical account suspension response', () {
      final status = ModerationStatus.fromRpcResponse({
        'state': 'SUSPENDED',
        'scope': 'ACCOUNT',
        'message': 'Repeated unsafe conduct.',
        'ends_at': '2026-07-20T18:30:00Z',
        'warning_count': 2,
      });

      expect(status.state, ModerationState.suspended);
      expect(status.scope, ModerationScope.account);
      expect(status.blocksAccount, isTrue);
      expect(status.isPlayRestricted, isFalse);
      expect(status.message, 'Repeated unsafe conduct.');
      expect(status.endsAt, isNotNull);
      expect(status.warningCount, 2);
    });

    test('keeps play-only suspension browseable', () {
      final status = ModerationStatus.fromRpcResponse([
        {
          'state': 'SUSPENDED',
          'scope': 'PLAY',
          'message': 'Match access paused.',
          'ends_at': null,
          'warning_count': 1,
        },
      ]);

      expect(status.blocksAccount, isFalse);
      expect(status.isPlayRestricted, isTrue);
    });

    test('treats malformed suspended scope as account-wide', () {
      final status = ModerationStatus.fromRpcResponse({
        'state': 'SUSPENDED',
        'scope': 'UNKNOWN',
        'message': '',
        'warning_count': 0,
      });

      expect(status.scope, ModerationScope.account);
      expect(status.blocksAccount, isTrue);
    });

    test('warnings never lock the app', () {
      final status = ModerationStatus.fromRpcResponse({
        'state': 'WARNING',
        'scope': 'ACCOUNT',
        'message': 'Keep matches respectful.',
        'warning_count': '3',
      });

      expect(status.blocksAccount, isFalse);
      expect(status.isPlayRestricted, isFalse);
      expect(status.warningCount, 3);
    });
  });

  testWidgets('restricted screen explains status and offers support', (
    tester,
  ) async {
    var signOutCount = 0;
    final status = ModerationStatus(
      state: ModerationState.suspended,
      scope: ModerationScope.account,
      message: 'Your account is under a temporary safety suspension.',
      endsAt: DateTime(2026, 7, 20, 14, 30),
      warningCount: 2,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RestrictedAccountScreen(
          status: status,
          onSignOut: () async => signOutCount++,
        ),
      ),
    );

    expect(find.byKey(const Key('restricted-account-screen')), findsOneWidget);
    expect(find.text('ACCOUNT SUSPENDED'), findsOneWidget);
    expect(
      find.text('Your account is under a temporary safety suspension.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('restricted-account-end-date')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('restricted-account-contact-support')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('restricted-account-support-sheet')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('restricted-account-copy-details')),
      findsOneWidget,
    );

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('restricted-account-sign-out')),
    );
    await tester.tap(find.byKey(const Key('restricted-account-sign-out')));
    await tester.pump();
    expect(signOutCount, 1);
  });

  testWidgets('warning notice shows backend message and warning count', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Color(0xFF111827),
          body: Padding(
            padding: EdgeInsets.all(16),
            child: ModerationStatusNoticeContent(
              status: ModerationStatus(
                state: ModerationState.warning,
                scope: ModerationScope.none,
                message: 'This is your final warning for abusive conduct.',
                endsAt: null,
                warningCount: 3,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('account-warning-notice')), findsOneWidget);
    expect(find.text('ACCOUNT WARNING'), findsOneWidget);
    expect(
      find.text('This is your final warning for abusive conduct.'),
      findsOneWidget,
    );
    expect(find.text('3 account warnings'), findsOneWidget);
    expect(find.byKey(const Key('restricted-account-screen')), findsNothing);
  });

  testWidgets('auth gate shows themed loading before resolving a ban', (
    tester,
  ) async {
    final statusCompleter = Completer<ModerationStatus>();
    final repository = _FakeModerationRepository(statusCompleter.future);

    await tester.pumpWidget(_gateApp(moderationRepository: repository));
    await tester.pump();

    expect(find.byKey(const Key('moderation-status-loading')), findsOneWidget);
    expect(find.byKey(const Key('authenticated-app')), findsNothing);

    statusCompleter.complete(
      const ModerationStatus(
        state: ModerationState.banned,
        scope: ModerationScope.account,
        message: 'Permanent account ban.',
        endsAt: null,
        warningCount: 4,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('restricted-account-screen')), findsOneWidget);
    expect(find.byKey(const Key('authenticated-app')), findsNothing);
  });

  testWidgets('auth gate blocks an account-wide suspension', (tester) async {
    await tester.pumpWidget(
      _gateApp(
        moderationRepository: _FakeModerationRepository(
          Future.value(
            const ModerationStatus(
              state: ModerationState.suspended,
              scope: ModerationScope.account,
              message: 'Temporary account restriction.',
              endsAt: null,
              warningCount: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('restricted-account-screen')), findsOneWidget);
    expect(find.byKey(const Key('authenticated-app')), findsNothing);
  });

  testWidgets('auth gate allows warning and play-only states', (tester) async {
    for (final status in [
      const ModerationStatus(
        state: ModerationState.warning,
        scope: ModerationScope.none,
        message: 'Respect other players.',
        endsAt: null,
        warningCount: 1,
      ),
      const ModerationStatus(
        state: ModerationState.suspended,
        scope: ModerationScope.play,
        message: 'Play access paused.',
        endsAt: null,
        warningCount: 2,
      ),
    ]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        _gateApp(
          moderationRepository: _FakeModerationRepository(Future.value(status)),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('authenticated-app')), findsOneWidget);
      expect(find.text(status.state.name), findsOneWidget);
      expect(find.byKey(const Key('restricted-account-screen')), findsNothing);
    }
  });

  testWidgets('auth gate fails open without crashing on network error', (
    tester,
  ) async {
    await tester.pumpWidget(
      _gateApp(
        moderationRepository: _FakeModerationRepository.throwing(
          Exception('offline'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('authenticated-app')), findsOneWidget);
    expect(find.text('active'), findsOneWidget);
  });
}

Widget _gateApp({required ModerationRepository moderationRepository}) {
  return MaterialApp(
    home: AuthGate(
      authRepository: _FakeAuthRepository(_completeSession()),
      moderationRepository: moderationRepository,
      authenticatedAppBuilder: (context, status) => Scaffold(
        key: const Key('authenticated-app'),
        body: Text(status.state.name),
      ),
    ),
  );
}

Session _completeSession() {
  const userId = '3f84969a-7c5b-4e98-9a71-dcad98c5d719';
  const user = User(
    id: userId,
    appMetadata: {},
    userMetadata: {
      'display_name': 'Test Player',
      'date_of_birth': '2000-01-01',
    },
    aud: 'authenticated',
    createdAt: '2026-07-15T00:00:00Z',
  );
  return Session(
    accessToken: 'test-token',
    refreshToken: 'test-refresh-token',
    tokenType: 'bearer',
    user: user,
  );
}

class _FakeModerationRepository implements ModerationRepository {
  _FakeModerationRepository(this.status) : error = null;

  _FakeModerationRepository.throwing(this.error) : status = null;

  final Future<ModerationStatus>? status;
  final Object? error;

  @override
  Future<ModerationStatus> getMyModerationStatus() async {
    if (error != null) throw error!;
    return status!;
  }

  @override
  Future<ModerationReportReceipt> submitReport(
    ModerationReportDraft report,
  ) async {
    return const ModerationReportReceipt(id: 'report-id');
  }
}

class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this._session);

  Session? _session;

  @override
  Session? get currentSession => _session;

  @override
  User? get currentUser => _session?.user;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  Future<void> sendPhoneOtp(String phone) async {}

  @override
  Future<void> verifyPhoneOtp({
    required String phone,
    required String token,
  }) async {}

  @override
  Future<void> updateDisplayName(String displayName) async {}

  @override
  Future<void> updateDateOfBirth(DateTime dateOfBirth) async {}

  @override
  Future<void> switchToUserForDevelopment(String profileId) async {}

  @override
  Future<void> signOut() async {
    _session = null;
  }
}
