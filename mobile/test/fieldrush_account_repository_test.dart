import 'dart:async';
import 'dart:convert';

import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_account_repository.dart';
import 'package:field/src/auth/player_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late SupabaseClient client;
  late SupabaseFieldrushAccountRepository repository;
  late List<http.Request> requests;
  late FutureOr<http.Response> Function(http.Request) respond;
  late http.Client transport;
  http.Response? logoutResponse;

  setUp(() {
    requests = [];
    logoutResponse = null;
    respond = (request) => throw StateError(
      'Unexpected local mock request: ${request.method} ${request.url.path}',
    );
    transport = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/auth/v1/logout') {
        return logoutResponse ?? http.Response('', 204);
      }
      final response = await respond(request);
      return http.Response.bytes(
        response.bodyBytes,
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    });
    client = SupabaseClient(
      'https://fieldrush-tests.invalid',
      'test-anon-key-not-a-secret',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: transport,
    );
    repository = SupabaseFieldrushAccountRepository(
      client: client,
      emailDeliveryEnabled: false,
      emailVerificationHttpClient: transport,
    );
  });

  tearDown(() async {
    await client.dispose();
  });

  Future<void> signedIn({String id = 'user-a'}) async {
    await client.auth.recoverSession(jsonEncode(_session(id: id)));
  }

  void enableEmail() {
    repository = SupabaseFieldrushAccountRepository(
      client: client,
      emailDeliveryEnabled: true,
      emailVerificationHttpClient: transport,
    );
  }

  Map<String, dynamic> staffSession() {
    final session = _session();
    session['user'] = {
      ..._user(),
      'app_metadata': {'fieldrush_account_type': 'staff'},
    };
    return session;
  }

  test(
    'staff account load refuses player RPCs and clears the local session',
    () async {
      await client.auth.recoverSession(jsonEncode(staffSession()));
      await expectLater(
        repository.loadAccount(),
        throwsA(
          isA<AuthException>().having(
            (error) => error.code,
            'code',
            'staff_account_only',
          ),
        ),
      );
      expect(client.auth.currentUser, isNull);
      expect(
        requests.every((request) => request.url.path == '/auth/v1/logout'),
        isTrue,
      );
    },
  );

  test(
    'staff identity cannot mutate its phone or create a player draft',
    () async {
      for (final operation in <Future<void> Function()>[
        () => repository.sendPhoneCode('+16025550101'),
        () => repository.saveDraft(const AccountDraft()),
        () => repository.requestEmailVerification('staff-edit@example.test'),
        () => repository.verifyEmailCode('staff-edit@example.test', '123456'),
        () async {
          await repository.updateAccount(const AccountDraft());
        },
        () => repository.deleteAccount(),
        () async {
          await repository.completeOnboarding(const AccountDraft());
        },
      ]) {
        await client.auth.recoverSession(jsonEncode(staffSession()));
        requests.clear();
        await expectLater(
          operation(),
          throwsA(
            isA<AuthException>().having(
              (error) => error.message,
              'message',
              staffAccountOnlyMessage,
            ),
          ),
        );
        expect(client.auth.currentUser, isNull);
        expect(
          requests.every((request) => request.url.path == '/auth/v1/logout'),
          isTrue,
        );
      }
    },
  );

  test(
    'SMS response carrying a staff realm is refused before player onboarding',
    () async {
      respond = (_) => _json(staffSession());
      await expectLater(
        repository.verifyPhoneCode('+14807469696', '123456'),
        throwsA(
          isA<AuthException>().having(
            (error) => error.code,
            'code',
            'staff_account_only',
          ),
        ),
      );
      expect(client.auth.currentUser, isNull);
      expect(requests.map((request) => request.url.path), [
        '/auth/v1/verify',
        '/auth/v1/logout',
      ]);
    },
  );

  test('editable user metadata cannot claim or remove the staff realm', () {
    expect(
      isStaffIdentity(
        User.fromJson({
          ..._user(),
          'user_metadata': {'fieldrush_account_type': 'staff'},
        }),
      ),
      isFalse,
    );
    expect(
      isStaffIdentity(
        User.fromJson({
          ..._user(),
          'app_metadata': {'fieldrush_account_type': 'staff'},
          'user_metadata': {'fieldrush_account_type': 'player'},
        }),
      ),
      isTrue,
    );
  });

  test(
    'a returned staff identity still fails after another player session replaces it',
    () async {
      await signedIn(id: 'new-player');
      final staff = User.fromJson(
        jsonDecode(jsonEncode(staffSession()['user'])) as Map<String, dynamic>,
      );
      await expectLater(
        requirePlayerIdentity(client, authenticatedUser: staff),
        throwsA(
          isA<AuthException>().having(
            (error) => error.code,
            'code',
            'staff_account_only',
          ),
        ),
      );
      expect(client.auth.currentUser?.id, 'new-player');
      expect(requests, isEmpty);
    },
  );

  test(
    'disabled email delivery cannot report success or send any request',
    () async {
      await expectLater(
        repository.requestEmailVerification('alex@example.com'),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<AuthException>()),
      );
      expect(requests, isEmpty);
    },
  );

  test('recovery sends an existing-only SMS request', () async {
    respond = (_) => _json({});
    await repository.sendRecoveryCode('+14807469696');
    expect(requests.single.url.path, '/auth/v1/otp');
    expect(_body(requests.single)['phone'], '+14807469696');
    expect(_body(requests.single)['create_user'], isFalse);
    expect(_body(requests.single)['channel'], 'sms');
  });

  test('recovery cannot replace an already signed-in account', () async {
    await signedIn();
    await expectLater(
      repository.sendRecoveryCode('+16025550101'),
      throwsA(isA<AuthException>()),
    );
    expect(requests, isEmpty);
    expect(client.auth.currentUser?.id, 'user-a');
  });

  test(
    'signed-out phone login allows a new identity and verifies SMS',
    () async {
      respond = (request) =>
          request.url.path.endsWith('/otp') ? _json({}) : _json(_session());
      await repository.sendPhoneCode('+14807469696');
      await repository.verifyPhoneCode('+14807469696', '123456');
      expect(_body(requests.first)['create_user'], isTrue);
      expect(_body(requests.last)['type'], 'sms');
      expect(client.auth.currentUser?.id, 'user-a');
    },
  );

  test(
    'signed-in phone attachment updates and verifies the same identity',
    () async {
      await signedIn();
      respond = (request) => request.url.path.endsWith('/user')
          ? _json(_user())
          : _json(_session(phone: '16025550101'));
      await repository.sendPhoneCode('+16025550101');
      expect(requests.single.method, 'PUT');
      expect(requests.single.url.path, '/auth/v1/user');
      expect(_body(requests.single)['phone'], '+16025550101');
      expect(client.auth.currentUser?.phone, '14807469696');
      await repository.verifyPhoneCode('+16025550101', '123456');
      expect(_body(requests[1])['type'], 'phone_change');
      expect(client.auth.currentUser?.id, 'user-a');
      expect(client.auth.currentUser?.phone, '16025550101');
      expect(
        requests.any((request) => request.url.path.endsWith('/otp')),
        isFalse,
      );
    },
  );

  test(
    'unfinished phone-only signup switches through logout then fresh SMS',
    () async {
      await signedIn();
      final before = client.auth.currentUser!.id;
      respond = (request) {
        if (request.url.path == '/auth/v1/user') {
          return _json(_googleUser(includeGoogle: false));
        }
        if (request.url.path.startsWith('/rest/')) {
          return _json({
            ..._accountJson(),
            'onboarding_completed': false,
            'status': 'onboarding',
          });
        }
        if (request.url.path == '/auth/v1/verify') {
          return _json(_session(id: 'new-user', phone: '16025550101'));
        }
        return _json({});
      };
      await repository.switchIncompletePhoneAccount('+16025550101');
      expect(client.auth.currentUser, isNull);
      expect(
        requests.map((request) => '${request.method} ${request.url.path}'),
        [
          'GET /auth/v1/user',
          'POST /rest/v1/rpc/get_my_fieldrush_account',
          'POST /auth/v1/logout',
          'POST /auth/v1/otp',
        ],
      );
      expect(requests[2].url.queryParameters['scope'], 'local');
      expect(_body(requests.last)['phone'], '+16025550101');
      expect(_body(requests.last)['create_user'], isTrue);
      expect(requests.any((request) => request.method == 'PUT'), isFalse);
      await repository.verifyPhoneCode('+16025550101', '123456');
      expect(_body(requests.last)['type'], 'sms');
      expect(client.auth.currentUser?.id, 'new-user');
      expect(client.auth.currentUser?.id, isNot(before));
      expect(requests.any((request) => request.method == 'DELETE'), isFalse);
    },
  );

  for (final reason in [
    'completed',
    'google-linked',
    'restricted',
    'same-number',
  ]) {
    test(
      'signup switch refuses $reason without signing out or editing phone',
      () async {
        await signedIn();
        respond = (request) => request.url.path == '/auth/v1/user'
            ? _json(_googleUser(includeGoogle: reason == 'google-linked'))
            : _json({
                ..._accountJson(),
                'onboarding_completed': reason == 'completed',
                'google_linked': reason == 'google-linked',
                'status': reason == 'restricted' ? 'suspended' : 'onboarding',
              });
        await expectLater(
          repository.switchIncompletePhoneAccount(
            reason == 'same-number' ? '+14807469696' : '+16025550101',
          ),
          throwsA(isA<AuthException>()),
        );
        expect(client.auth.currentUser?.id, 'user-a');
        expect(
          requests.any((request) => request.url.path.endsWith('/logout')),
          isFalse,
        );
        expect(requests.any((request) => request.method == 'PUT'), isFalse);
      },
    );
  }

  test(
    'signup state lookup failure does not log out or send another code',
    () async {
      await signedIn();
      respond = (request) => request.url.path == '/auth/v1/user'
          ? _json(_googleUser(includeGoogle: false))
          : _json({'message': 'Unavailable', 'code': 'XX000'}, status: 500);
      await expectLater(
        repository.switchIncompletePhoneAccount('+16025550101'),
        throwsA(isA<PostgrestException>()),
      );
      expect(client.auth.currentUser?.id, 'user-a');
      expect(requests.length, 2);
    },
  );

  test('failed logout cannot report a new SMS request', () async {
    await signedIn();
    logoutResponse = _json({'msg': 'Unavailable'}, status: 500);
    respond = (request) => request.url.path == '/auth/v1/user'
        ? _json(_googleUser(includeGoogle: false))
        : _json({
            ..._accountJson(),
            'onboarding_completed': false,
            'status': 'onboarding',
          });
    await expectLater(
      repository.switchIncompletePhoneAccount('+16025550101'),
      throwsA(isA<AuthException>()),
    );
    expect(
      requests.any((request) => request.url.path.endsWith('/otp')),
      isFalse,
    );
    expect(requests.any((request) => request.method == 'PUT'), isFalse);
    expect(client.auth.currentUser, isNull);
  });

  test(
    'new SMS failure after logout leaves the old account signed out, unchanged',
    () async {
      await signedIn();
      respond = (request) {
        if (request.url.path == '/auth/v1/user') {
          return _json(_googleUser(includeGoogle: false));
        }
        if (request.url.path.startsWith('/rest/')) {
          return _json({
            ..._accountJson(),
            'onboarding_completed': false,
            'status': 'onboarding',
          });
        }
        return _json({'msg': 'SMS unavailable'}, status: 503);
      };
      await expectLater(
        repository.switchIncompletePhoneAccount('+16025550101'),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser, isNull);
      expect(requests.any((request) => request.method == 'PUT'), isFalse);
      expect(requests.any((request) => request.method == 'DELETE'), isFalse);
    },
  );

  test('account switch during signup lookup preserves the new user', () async {
    await signedIn();
    respond = (request) async {
      if (request.url.path == '/auth/v1/user') {
        return _json(_googleUser(includeGoogle: false));
      }
      await signedIn(id: 'other-user');
      return _json({
        ..._accountJson(),
        'onboarding_completed': false,
        'status': 'onboarding',
      });
    };
    await expectLater(
      repository.switchIncompletePhoneAccount('+16025550101'),
      throwsA(isA<AuthException>()),
    );
    expect(client.auth.currentUser?.id, 'other-user');
    expect(
      requests.any((request) => request.url.path.endsWith('/logout')),
      isFalse,
    );
  });

  test(
    'device cleanup runs before leaving an unfinished phone account',
    () async {
      await signedIn();
      var prepared = false;
      repository = SupabaseFieldrushAccountRepository(
        client: client,
        beforeSignOut: () async {
          expect(client.auth.currentUser?.id, 'user-a');
          expect(
            requests.any((request) => request.url.path.endsWith('/logout')),
            isFalse,
          );
          prepared = true;
        },
      );
      respond = (request) {
        if (request.url.path == '/auth/v1/user') {
          return _json(_googleUser(includeGoogle: false));
        }
        if (request.url.path.startsWith('/rest/')) {
          return _json({
            ..._accountJson(),
            'onboarding_completed': false,
            'status': 'onboarding',
          });
        }
        expect(prepared, isTrue);
        return _json({});
      };
      await repository.switchIncompletePhoneAccount('+16025550101');
      expect(prepared, isTrue);
      expect(client.auth.currentUser, isNull);
    },
  );

  test(
    'failed device cleanup blocks the switch without changing the old account',
    () async {
      await signedIn();
      repository = SupabaseFieldrushAccountRepository(
        client: client,
        beforeSignOut: () async =>
            throw const AuthException('Device cleanup failed.'),
      );
      respond = (request) => request.url.path == '/auth/v1/user'
          ? _json(_googleUser(includeGoogle: false))
          : _json({
              ..._accountJson(),
              'onboarding_completed': false,
              'status': 'onboarding',
            });
      await expectLater(
        repository.switchIncompletePhoneAccount('+16025550101'),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser?.id, 'user-a');
      expect(
        requests.any((request) => request.url.path.endsWith('/logout')),
        isFalse,
      );
      expect(
        requests.any((request) => request.url.path.endsWith('/otp')),
        isFalse,
      );
    },
  );

  test('unexpected phone-change account is signed out and fails', () async {
    await signedIn();
    respond = (request) => request.url.path.endsWith('/user')
        ? _json(_user())
        : _json(_session(id: 'other-user'));
    await repository.sendPhoneCode('+16025550101');
    await expectLater(
      repository.verifyPhoneCode('+16025550101', '123456'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          contains('account changed unexpectedly'),
        ),
      ),
    );
    expect(client.auth.currentUser, isNull);
  });

  test(
    'phone verification failure retains the original verified number',
    () async {
      await signedIn();
      respond = (request) => request.url.path.endsWith('/user')
          ? _json(_user())
          : _json({
              'msg': 'Invalid verification code.',
              'error_code': 'otp_expired',
            }, status: 403);
      await repository.sendPhoneCode('+16025550101');
      await expectLater(
        repository.verifyPhoneCode('+16025550101', '123456'),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser?.id, 'user-a');
      expect(client.auth.currentUser?.phone, '14807469696');
    },
  );

  test(
    'reauthentication fetches confirmed phone and cannot create an account',
    () async {
      await signedIn();
      respond = (request) {
        if (request.url.path.endsWith('/user')) return _json(_user());
        if (request.url.path.endsWith('/verify')) return _json(_session());
        return _json({});
      };
      await repository.sendReauthenticationCode();
      expect(requests.first.method, 'GET');
      expect(_body(requests[1])['phone'], '+14807469696');
      expect(_body(requests[1])['create_user'], isFalse);
      await repository.verifyReauthenticationCode('123456');
      expect(_body(requests.last)['type'], 'sms');
      expect(client.auth.currentUser?.id, 'user-a');
    },
  );

  test(
    'reauthentication proof from another user cannot authorize deletion',
    () async {
      await signedIn();
      respond = (request) {
        if (request.url.path.endsWith('/user')) return _json(_user());
        if (request.url.path.endsWith('/verify')) {
          return _json(_session(id: 'other-user'));
        }
        return _json({});
      };
      await repository.sendReauthenticationCode();
      await expectLater(
        repository.verifyReauthenticationCode('123456'),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser, isNull);
    },
  );

  test(
    'deletion sends explicit confirmation and clears session only after confirmed success',
    () async {
      await signedIn();
      respond = (_) => _json({'deleted': true});
      await repository.deleteAccount();
      expect(requests.first.url.path, '/functions/v1/fieldrush-delete-account');
      expect(_body(requests.first), {
        'confirmation': 'DELETE',
        'wallet_forfeiture_confirmed': true,
      });
      expect(client.auth.currentUser, isNull);
    },
  );

  test(
    'unconfirmed deletion response is a failure and preserves session',
    () async {
      await signedIn();
      respond = (_) => _json({'deleted': false});
      await expectLater(
        repository.deleteAccount(),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser?.id, 'user-a');
      expect(
        requests.any((request) => request.url.path.endsWith('/logout')),
        isFalse,
      );
    },
  );

  test(
    'unsettled-account refusal is surfaced without deleting or signing out',
    () async {
      await signedIn();
      respond = (_) =>
          _json({'error': 'Resolve unsettled bookings first.'}, status: 409);
      await expectLater(
        repository.deleteAccount(),
        throwsA(
          isA<AuthException>().having(
            (error) => error.message,
            'message',
            'Resolve unsettled bookings first.',
          ),
        ),
      );
      expect(client.auth.currentUser?.id, 'user-a');
    },
  );

  test(
    'completion sends profile and versioned consent, not client authority fields',
    () async {
      respond = (_) => _json(_accountJson());
      final draft = AccountDraft(
        firstName: ' Alex ',
        lastName: ' Rivera ',
        username: 'Alex.R',
        dateOfBirth: DateTime(2000, 1, 2),
        email: 'alex@example.com',
        skillAssessment: SkillAssessment.advanced,
      );
      final account = await repository.completeOnboarding(draft);
      final payload = _body(requests.single);
      expect(
        requests.single.url.path,
        '/rest/v1/rpc/complete_fieldrush_onboarding',
      );
      expect(
        payload.keys,
        unorderedEquals(['draft', 'terms_version', 'privacy_version']),
      );
      expect(payload['terms_version'], fieldrushTermsVersion);
      expect(payload['privacy_version'], fieldrushPrivacyVersion);
      expect(payload['draft'], {
        'first_name': 'Alex',
        'last_name': 'Rivera',
        'username': 'alex.r',
        'date_of_birth': '2000-01-02',
        'email': 'alex@example.com',
        'skill_assessment': 'advanced',
      });
      expect(account.completed, isTrue);
    },
  );

  test(
    'draft saves only the assessment key and never a numeric seed',
    () async {
      respond = (_) => _json({});
      for (final assessment in SkillAssessment.values) {
        await repository.saveDraft(AccountDraft(skillAssessment: assessment));
        final request = requests.last;
        expect(
          request.url.path,
          '/rest/v1/rpc/save_fieldrush_onboarding_draft',
        );
        final draft = _body(request)['draft'] as Map;
        expect(draft['skill_assessment'], assessment.value);
        expect(draft.keys, isNot(contains('seed')));
        expect(draft.keys, isNot(contains('skill_rating')));
        expect(draft.values.whereType<num>(), isEmpty);
      }
    },
  );

  test(
    'account updates cannot submit a replacement skill assessment',
    () async {
      await signedIn();
      respond = (request) => request.url.path == '/auth/v1/user'
          ? _json(_user())
          : _json(_accountJson());
      await repository.updateAccount(
        const AccountDraft(
          firstName: 'Alex',
          email: 'alex@example.com',
          skillAssessment: SkillAssessment.highlyCompetitive,
        ),
      );
      expect(
        requests.last.url.path,
        '/rest/v1/rpc/update_my_fieldrush_account',
      );
      expect(
        _body(requests.last)['draft'],
        isNot(contains('skill_assessment')),
      );
    },
  );

  test(
    'account reads use the server trusted Google email projection',
    () async {
      respond = (_) => _json({
        ..._accountJson(),
        'google_linked': true,
        'google_email': 'google@example.com',
        'email': 'google@example.com',
        'email_verified': true,
      });
      final account = await repository.loadAccount();
      expect(account.googleLinked, isTrue);
      expect(account.googleEmail, 'google@example.com');
      expect(account.draft.email, 'google@example.com');
      expect(account.emailVerified, isTrue);
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/rest/v1/rpc/get_my_fieldrush_account');
    },
  );

  test(
    'fresh Google identity requires consent even when the local session is stale',
    () async {
      await signedIn();
      respond = (_) => _json(_googleUser());
      await expectLater(
        repository.updateAccount(const AccountDraft(email: 'new@example.com')),
        throwsA(isA<GoogleEmailChangeConfirmationRequiredException>()),
      );
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/auth/v1/user');
      expect(client.auth.currentUser?.id, 'user-a');
    },
  );

  test(
    'a Google email unchanged except case does not unlink even with consent',
    () async {
      await signedIn();
      respond = (request) => request.method == 'GET'
          ? _json(_googleUser())
          : _json({..._accountJson(), 'first_name': 'Edited'});
      final account = await repository.updateAccount(
        const AccountDraft(firstName: 'Edited', email: ' GOOGLE@example.com '),
        disconnectGoogle: true,
      );
      expect(account.draft.firstName, 'Edited');
      expect(requests.map((request) => request.method), ['GET', 'POST']);
      expect(
        requests.last.url.path,
        '/rest/v1/rpc/update_my_fieldrush_account',
      );
    },
  );

  test(
    'confirmed Google disconnect precedes email save and preserves phone session',
    () async {
      await signedIn();
      final originalSession = client.auth.currentSession;
      var unlinked = false;
      respond = (request) {
        if (request.method == 'GET') {
          return _json(_googleUser(includeGoogle: !unlinked));
        }
        if (request.method == 'DELETE') {
          unlinked = true;
          return http.Response('', 204);
        }
        return _json({..._accountJson(), 'email': 'new@example.com'});
      };
      final account = await repository.updateAccount(
        const AccountDraft(email: 'new@example.com'),
        disconnectGoogle: true,
      );
      expect(account.draft.email, 'new@example.com');
      expect(
        requests.map((request) => '${request.method} ${request.url.path}'),
        [
          'GET /auth/v1/user',
          'DELETE /auth/v1/user/identities/google-identity',
          'GET /auth/v1/user',
          'POST /rest/v1/rpc/update_my_fieldrush_account',
        ],
      );
      expect(client.auth.currentSession, originalSession);
      expect(client.auth.currentUser?.phone, '14807469696');
    },
  );

  for (final problem in [
    'unconfirmed',
    'missing-phone-identity',
    'empty-phone',
  ]) {
    test(
      'Google remains linked with unsafe phone fallback: $problem',
      () async {
        await signedIn();
        respond = (_) => _json(
          _googleUser(
            confirmedPhone: problem != 'unconfirmed',
            includePhone: problem != 'missing-phone-identity',
            phone: problem == 'empty-phone' ? '' : '14807469696',
          ),
        );
        await expectLater(
          repository.updateAccount(
            const AccountDraft(email: 'new@example.com'),
            disconnectGoogle: true,
          ),
          throwsA(isA<GoogleEmailChangeRequiresPhoneException>()),
        );
        expect(requests.single.method, 'GET');
      },
    );
  }

  test('invalid new email never disconnects Google', () async {
    await signedIn();
    await expectLater(
      repository.updateAccount(
        const AccountDraft(email: 'not-an-email'),
        disconnectGoogle: true,
      ),
      throwsA(isA<AuthException>()),
    );
    expect(requests, isEmpty);
  });

  for (final claim in [false, 'true', null]) {
    test(
      'untrusted Google verified claim $claim never authorizes unlink',
      () async {
        await signedIn();
        respond = (_) => _json(_googleUser(verifiedGoogle: claim));
        await expectLater(
          repository.updateAccount(
            const AccountDraft(email: 'new@example.com'),
            disconnectGoogle: true,
          ),
          throwsA(isA<AuthException>()),
        );
        expect(requests.single.method, 'GET');
      },
    );
  }

  test('mutable Google user metadata cannot authorize unlink', () async {
    await signedIn();
    respond = (_) => _json({
      ..._googleUser(verifiedGoogle: false),
      'user_metadata': {'email': 'google@example.com', 'email_verified': true},
    });
    await expectLater(
      repository.updateAccount(
        const AccountDraft(email: 'new@example.com'),
        disconnectGoogle: true,
      ),
      throwsA(isA<AuthException>()),
    );
    expect(requests.single.method, 'GET');
  });

  test('Google unlink refusal does not save a different email', () async {
    await signedIn();
    respond = (request) => request.method == 'GET'
        ? _json(_googleUser())
        : _json({'msg': 'Identity cannot be unlinked.'}, status: 422);
    await expectLater(
      repository.updateAccount(
        const AccountDraft(email: 'new@example.com'),
        disconnectGoogle: true,
      ),
      throwsA(isA<GoogleEmailChangeStatusUnavailableException>()),
    );
    expect(requests.map((request) => request.method), ['GET', 'DELETE', 'GET']);
  });

  test(
    'lost unlink acknowledgement reconciles a completed disconnect',
    () async {
      await signedIn();
      var unlinked = false;
      respond = (request) {
        if (request.method == 'GET') {
          return _json(_googleUser(includeGoogle: !unlinked));
        }
        unlinked = true;
        throw http.ClientException('The response was lost.');
      };
      await expectLater(
        repository.updateAccount(
          const AccountDraft(email: 'new@example.com'),
          disconnectGoogle: true,
        ),
        throwsA(isA<GoogleDisconnectedEmailUpdateException>()),
      );
      expect(requests.map((request) => request.method), [
        'GET',
        'DELETE',
        'GET',
      ]);
      expect(
        requests.any((request) => request.url.path.startsWith('/rest/')),
        isFalse,
      );
    },
  );

  test(
    'lost unlink response and unavailable status never assume rollback',
    () async {
      await signedIn();
      var firstRead = true;
      respond = (request) {
        if (firstRead) {
          firstRead = false;
          return _json(_googleUser());
        }
        throw http.ClientException('Offline.');
      };
      await expectLater(
        repository.updateAccount(
          const AccountDraft(email: 'new@example.com'),
          disconnectGoogle: true,
        ),
        throwsA(isA<GoogleEmailChangeStatusUnavailableException>()),
      );
      expect(requests.map((request) => request.method), [
        'GET',
        'DELETE',
        'GET',
      ]);
      expect(
        requests.any((request) => request.url.path.startsWith('/rest/')),
        isFalse,
      );
    },
  );

  test('unknown post-unlink state does not save the new email', () async {
    await signedIn();
    respond = (request) =>
        request.method == 'GET' ? _json(_googleUser()) : http.Response('', 204);
    await expectLater(
      repository.updateAccount(
        const AccountDraft(email: 'new@example.com'),
        disconnectGoogle: true,
      ),
      throwsA(isA<GoogleEmailChangeStatusUnavailableException>()),
    );
    expect(requests.map((request) => request.method), ['GET', 'DELETE', 'GET']);
  });

  test('changed fallback phone after unlink prevents contact save', () async {
    await signedIn();
    var unlinked = false;
    respond = (request) {
      if (request.method == 'GET') {
        return _json(
          _googleUser(
            includeGoogle: !unlinked,
            phone: unlinked ? '16025550101' : '14807469696',
          ),
        );
      }
      unlinked = true;
      return http.Response('', 204);
    };
    await expectLater(
      repository.updateAccount(
        const AccountDraft(email: 'new@example.com'),
        disconnectGoogle: true,
      ),
      throwsA(isA<GoogleEmailChangeStatusUnavailableException>()),
    );
    expect(
      requests.any((request) => request.url.path.startsWith('/rest/')),
      isFalse,
    );
  });

  test(
    'account switch during fresh identity check does not unlink either account',
    () async {
      await signedIn();
      respond = (_) async {
        await client.auth.recoverSession(jsonEncode(_session(id: 'user-b')));
        return _json(_googleUser());
      };
      await expectLater(
        repository.updateAccount(
          const AccountDraft(email: 'new@example.com'),
          disconnectGoogle: true,
        ),
        throwsA(isA<AuthException>()),
      );
      expect(requests.single.method, 'GET');
      expect(client.auth.currentUser?.id, 'user-b');
    },
  );

  test('a sign-out during unlink prevents all profile writes', () async {
    await signedIn();
    respond = (request) async {
      if (request.method == 'GET') return _json(_googleUser());
      await client.auth.signOut(scope: SignOutScope.local);
      return http.Response('', 204);
    };
    await expectLater(
      repository.updateAccount(
        const AccountDraft(email: 'new@example.com'),
        disconnectGoogle: true,
      ),
      throwsA(isA<GoogleEmailChangeStatusUnavailableException>()),
    );
    expect(
      requests.any((request) => request.url.path.startsWith('/rest/')),
      isFalse,
    );
    expect(client.auth.currentUser, isNull);
  });

  test(
    'email-save failure after unlink reports the partial sign-in change',
    () async {
      await signedIn();
      var unlinked = false;
      respond = (request) {
        if (request.method == 'GET') {
          return _json(_googleUser(includeGoogle: !unlinked));
        }
        if (request.method == 'DELETE') {
          unlinked = true;
          return http.Response('', 204);
        }
        return _json({
          'message': 'Profile unavailable',
          'code': 'XX000',
        }, status: 500);
      };
      await expectLater(
        repository.updateAccount(
          const AccountDraft(email: 'new@example.com'),
          disconnectGoogle: true,
        ),
        throwsA(isA<GoogleDisconnectedEmailUpdateException>()),
      );
      expect(unlinked, isTrue);
      expect(client.auth.currentUser?.id, 'user-a');
    },
  );

  test('other Auth identity cannot authorize a Google unlink', () async {
    await signedIn();
    respond = (_) => _json(_googleUser(id: 'other-user'));
    await expectLater(
      repository.updateAccount(
        const AccountDraft(email: 'new@example.com'),
        disconnectGoogle: true,
      ),
      throwsA(isA<AuthException>()),
    );
    expect(requests.any((request) => request.method == 'DELETE'), isFalse);
    expect(client.auth.currentUser, isNull);
  });

  test(
    'incomplete Google signup cannot bypass unlink through email OTP',
    () async {
      enableEmail();
      await signedIn();
      respond = (_) => _json({
        ..._accountJson(),
        'google_linked': true,
        'google_email': 'google@example.com',
        'email': 'google@example.com',
        'email_verified': true,
        'onboarding_completed': false,
      });
      await expectLater(
        repository.requestEmailVerification('new@example.com'),
        throwsA(isA<GoogleEmailChangeConfirmationRequiredException>()),
      );
      expect(requests.single.url.path, '/rest/v1/rpc/get_my_fieldrush_account');
    },
  );

  test(
    'malformed account response fails instead of making an active profile',
    () async {
      respond = (_) => _json([]);
      await expectLater(
        repository.loadAccount(),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('invalid phone and OTP input never reaches the provider', () async {
    await expectLater(
      repository.sendPhoneCode('4807469696'),
      throwsA(isA<AuthException>()),
    );
    await expectLater(
      repository.verifyPhoneCode('+14807469696', '123'),
      throwsA(isA<AuthException>()),
    );
    expect(requests, isEmpty);
  });

  test('email-change verification cannot switch to another identity', () async {
    enableEmail();
    await signedIn();
    respond = (_) => _json(_session(id: 'other-user'));
    await expectLater(
      repository.verifyEmailCode('other@example.com', '123456'),
      throwsA(isA<AuthException>()),
    );
    expect(client.auth.currentUser, isNull);
  });

  test('email-change verification needs an authenticated account', () async {
    enableEmail();
    await expectLater(
      repository.verifyEmailCode('alex@example.com', '123456'),
      throwsA(isA<AuthException>()),
    );
    expect(requests, isEmpty);
  });

  test(
    'requesting email verification also needs an authenticated account',
    () async {
      enableEmail();
      await expectLater(
        repository.requestEmailVerification('alex@example.com'),
        throwsA(isA<AuthSessionMissingException>()),
      );
      expect(requests, isEmpty);
    },
  );

  test('email and SMS code formats are independently six digits', () async {
    enableEmail();
    await signedIn();
    for (final token in ['12345', '1234567', '12345678', '12345x', ' 123456']) {
      await expectLater(
        repository.verifyEmailCode('alex@example.com', token),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        repository.verifyPhoneCode('+14807469696', token),
        throwsA(isA<AuthException>()),
      );
    }
    await expectLater(
      repository.verifyEmailCode('not-an-email', '123456'),
      throwsA(isA<AuthException>()),
    );
    expect(requests, isEmpty);
    respond = (_) => _json(_session());
    await repository.verifyPhoneCode('+14807469696', '123456');
    expect(_body(requests.single)['type'], 'phone_change');
  });

  test(
    'email verification request uses the existing session and saved address',
    () async {
      enableEmail();
      await signedIn();
      final originalSession = client.auth.currentSession!;
      respond = (request) => request.url.path.startsWith('/rest/')
          ? _json(_accountJson())
          : _json(_pendingEmailUser());
      await repository.requestEmailVerification(' Alex@Example.com ');
      expect(requests.map((request) => request.url.path), [
        '/rest/v1/rpc/get_my_fieldrush_account',
        '/auth/v1/user',
      ]);
      final request = requests.last;
      expect(request.method, 'PUT');
      expect(_body(request), {'email': 'alex@example.com'});
      expect(
        request.headers['authorization'],
        'Bearer ${originalSession.accessToken}',
      );
      expect(request.headers['apikey'], 'test-anon-key-not-a-secret');
      expect(
        request.url.queryParameters['redirect_to'],
        'com.alialtaraif.field.staging://auth-callback/',
      );
      expect(client.auth.currentSession, originalSession);
    },
  );

  test(
    'changing the contact email preserves the latest server draft',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) {
        if (request.url.path == '/rest/v1/rpc/get_my_fieldrush_account') {
          return _json({
            ..._accountJson(),
            'first_name': 'Latest',
            'email': 'old@example.com',
          });
        }
        if (request.url.path == '/rest/v1/rpc/update_my_fieldrush_account') {
          return _json({..._accountJson(), 'first_name': 'Latest'});
        }
        if (request.method == 'GET') return _json(_user());
        return _json(_pendingEmailUser(email: 'old@example.com'));
      };
      await repository.requestEmailVerification('alex@example.com');
      final update = requests.singleWhere(
        (request) => request.url.path.endsWith('/update_my_fieldrush_account'),
      );
      expect((_body(update)['draft'] as Map)['first_name'], 'Latest');
      expect((_body(update)['draft'] as Map)['email'], 'alex@example.com');
      expect(
        (_body(update)['draft'] as Map).containsKey('skill_assessment'),
        isFalse,
      );
      expect(requests.last.url.path, '/auth/v1/user');
    },
  );

  test(
    'an incomplete account stores an email draft without completing signup',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) {
        if (request.url.path == '/rest/v1/rpc/get_my_fieldrush_account') {
          return _json({
            ..._accountJson(),
            'email': '',
            'onboarding_completed': false,
            'status': 'onboarding',
          });
        }
        if (request.url.path ==
            '/rest/v1/rpc/save_fieldrush_onboarding_draft') {
          return _json({});
        }
        return _json(_pendingEmailUser());
      };
      await repository.requestEmailVerification('alex@example.com');
      expect(
        requests[1].url.path,
        '/rest/v1/rpc/save_fieldrush_onboarding_draft',
      );
      expect(
        requests.any(
          (request) =>
              request.url.path.endsWith('/complete_fieldrush_onboarding'),
        ),
        isFalse,
      );
    },
  );

  test(
    'resending an email does not overwrite any saved profile fields',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) => request.url.path.startsWith('/rest/')
          ? _json(_accountJson())
          : _json(_pendingEmailUser());
      await repository.requestEmailVerification('alex@example.com');
      await repository.requestEmailVerification('alex@example.com');
      expect(requests.where((request) => request.method == 'PUT').length, 2);
      expect(
        requests.where(
          (request) => request.url.path.contains('update_my_fieldrush_account'),
        ),
        isEmpty,
      );
      expect(
        requests.where(
          (request) =>
              request.url.path.contains('save_fieldrush_onboarding_draft'),
        ),
        isEmpty,
      );
    },
  );

  test('an already verified email does not send another code', () async {
    enableEmail();
    await signedIn();
    respond = (_) => _json({..._accountJson(), 'email_verified': true});
    await expectLater(
      repository.requestEmailVerification('alex@example.com'),
      throwsA(isA<AuthException>()),
    );
    expect(requests.length, 1);
  });

  test(
    'a failed email send preserves the phone session and reports the provider code',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) => request.url.path.startsWith('/rest/')
          ? _json(_accountJson())
          : _json({
              'error_code': 'over_email_send_rate_limit',
              'msg': 'Email rate limit exceeded',
            }, status: 429);
      await expectLater(
        repository.requestEmailVerification('alex@example.com'),
        throwsA(
          isA<AuthException>().having(
            (error) => error.code,
            'code',
            'over_email_send_rate_limit',
          ),
        ),
      );
      expect(client.auth.currentUser?.id, 'user-a');
    },
  );

  test('a send response must acknowledge the same pending email', () async {
    enableEmail();
    await signedIn();
    respond = (request) => request.url.path.startsWith('/rest/')
        ? _json(_accountJson())
        : _json(_pendingEmailUser(newEmail: 'wrong@example.com'));
    await expectLater(
      repository.requestEmailVerification('alex@example.com'),
      throwsA(isA<FormatException>()),
    );
  });

  test('a wrong send-response identity is never adopted', () async {
    enableEmail();
    await signedIn();
    respond = (request) => request.url.path.startsWith('/rest/')
        ? _json(_accountJson())
        : _json(_pendingEmailUser(id: 'other-user'));
    await expectLater(
      repository.requestEmailVerification('alex@example.com'),
      throwsA(isA<AuthException>()),
    );
    expect(client.auth.currentUser, isNull);
  });

  test('a user switch during account loading prevents the send', () async {
    enableEmail();
    await signedIn();
    respond = (_) async {
      await signedIn(id: 'other-user');
      return _json(_accountJson());
    };
    await expectLater(
      repository.requestEmailVerification('alex@example.com'),
      throwsA(isA<AuthException>()),
    );
    expect(client.auth.currentUser?.id, 'other-user');
    expect(requests.length, 1);
  });

  test(
    'a user switch during sending cannot overwrite the new session',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) async {
        if (request.url.path.startsWith('/rest/')) return _json(_accountJson());
        await signedIn(id: 'other-user');
        return _json(_pendingEmailUser());
      };
      await expectLater(
        repository.requestEmailVerification('alex@example.com'),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser?.id, 'other-user');
    },
  );

  test(
    'completed email confirmation retains the original phone session',
    () async {
      enableEmail();
      await signedIn();
      final originalSession = client.auth.currentSession!;
      respond = (request) => request.method == 'POST'
          ? _json(_emailSession())
          : _json(_verifiedEmailUser());
      await repository.verifyEmailCode(' Alex@Example.com ', '123456');
      expect(_body(requests.first), {
        'email': 'alex@example.com',
        'token': '123456',
        'type': 'email_change',
      });
      expect(requests.last.method, 'GET');
      expect(
        requests.last.headers['authorization'],
        'Bearer ${originalSession.accessToken}',
      );
      expect(client.auth.currentSession, originalSession);
    },
  );

  test(
    'canonical first-of-two confirmation is accepted only with matching pending Auth state',
    () async {
      enableEmail();
      await signedIn();
      final originalSession = client.auth.currentSession!;
      respond = (request) => request.method == 'POST'
          ? _json(_partialEmailAcknowledgement())
          : _json(_pendingEmailUser(email: 'old@example.com'));
      await repository.verifyEmailCode('alex@example.com', '123456');
      expect(client.auth.currentSession, originalSession);
      expect(requests.length, 2);
    },
  );

  test(
    'a concurrent old-inbox confirmation can complete a canonical partial response',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) => request.method == 'POST'
          ? _json(_partialEmailAcknowledgement())
          : _json(_verifiedEmailUser());
      await repository.verifyEmailCode('alex@example.com', '123456');
      expect(client.auth.currentUser?.id, 'user-a');
    },
  );

  test(
    'new inbox code alone changes an existing confirmed Auth email',
    () async {
      enableEmail();
      await client.auth.recoverSession(
        jsonEncode({
          ..._session(),
          'user': _verifiedEmailUser(email: 'old@example.com'),
        }),
      );
      final originalSession = client.auth.currentSession!;
      respond = (request) {
        if (request.url.path.startsWith('/rest/')) {
          return _json(_accountJson());
        }
        if (request.method == 'PUT') {
          return _json(_pendingEmailUser(email: 'old@example.com'));
        }
        return request.method == 'POST'
            ? _json(_emailSession())
            : _json(_verifiedEmailUser());
      };
      await repository.requestEmailVerification('alex@example.com');
      await repository.verifyEmailCode('alex@example.com', '123456');
      expect(
        requests.map((request) => '${request.method} ${request.url.path}'),
        [
          'POST /rest/v1/rpc/get_my_fieldrush_account',
          'PUT /auth/v1/user',
          'POST /auth/v1/verify',
          'GET /auth/v1/user',
        ],
      );
      expect(_body(requests[1]), {'email': 'alex@example.com'});
      expect(_body(requests[2]), {
        'email': 'alex@example.com',
        'token': '123456',
        'type': 'email_change',
      });
      expect(client.auth.currentSession, originalSession);
      expect(client.auth.currentUser?.email, 'old@example.com');
      expect(
        requests.last.headers['authorization'],
        'Bearer ${originalSession.accessToken}',
      );
    },
  );

  for (final entry in <String, Object?>{
    'empty object': {},
    'null body': null,
    'list body': [],
    'generic SDK-like error': {
      'msg': 'An error occurred on token verification.',
    },
    'wrong acknowledgement text': {'code': '200', 'msg': 'Email verified'},
    'numeric acknowledgement code': {
      ..._partialEmailAcknowledgement(),
      'code': 200,
    },
    'extra error in acknowledgement': {
      ..._partialEmailAcknowledgement(),
      'error_code': 'otp_expired',
    },
    'missing acknowledgement code': {
      'msg': _partialEmailAcknowledgement()['msg'],
    },
    'malformed session': {'access_token': 'not-a-session'},
    'missing refresh token': {..._emailSession()}..remove('refresh_token'),
    'empty access token': {..._emailSession(), 'access_token': ''},
    'unconfirmed session user': {
      ..._emailSession(),
      'user': {..._verifiedEmailUser()}..remove('email_confirmed_at'),
    },
    'wrong email in session': {
      ..._emailSession(),
      'user': _verifiedEmailUser(email: 'other@example.com'),
    },
    'invalid confirmation timestamp': {
      ..._emailSession(),
      'user': {..._verifiedEmailUser(), 'email_confirmed_at': 'not-a-date'},
    },
  }.entries) {
    test('email verification rejects ${entry.key}', () async {
      enableEmail();
      await signedIn();
      respond = (_) => _json(entry.value);
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<FormatException>()),
      );
      expect(client.auth.currentUser?.id, 'user-a');
      expect(requests.length, 1);
    });
  }

  test(
    'canonical-looking partial acknowledgement on an error status is never accepted',
    () async {
      enableEmail();
      await signedIn();
      respond = (_) => _json(_partialEmailAcknowledgement(), status: 403);
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<AuthException>()),
      );
      expect(requests.length, 1);
    },
  );

  test(
    'invalid or expired OTP does not become a pending confirmation',
    () async {
      enableEmail();
      await signedIn();
      respond = (_) => _json({
        'error_code': 'otp_expired',
        'msg': 'Token has expired or is invalid',
      }, status: 403);
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(
          isA<AuthException>().having(
            (error) => error.code,
            'code',
            'otp_expired',
          ),
        ),
      );
      expect(client.auth.currentUser?.id, 'user-a');
      expect(requests.length, 1);
    },
  );

  test('transport errors are not treated as accepted codes', () async {
    enableEmail();
    await signedIn();
    respond = (_) => throw http.ClientException('Local test offline');
    await expectLater(
      repository.verifyEmailCode('alex@example.com', '123456'),
      throwsA(isA<http.ClientException>()),
    );
    expect(requests.length, 1);
    expect(client.auth.currentUser?.id, 'user-a');
  });

  test(
    'a partial acknowledgement cannot refer to a different pending address',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) => request.method == 'POST'
          ? _json(_partialEmailAcknowledgement())
          : _json(_pendingEmailUser(newEmail: 'wrong@example.com'));
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'a completed response still needs authoritative confirmed Auth state',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) => request.method == 'POST'
          ? _json(_emailSession())
          : _json(_pendingEmailUser(email: 'old@example.com'));
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'accepted code followed by a status outage requires status-only recovery',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) => request.method == 'POST'
          ? _json(_partialEmailAcknowledgement())
          : _json({'msg': 'Local status lookup failed'}, status: 503);
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<EmailVerificationStatusUnavailableException>()),
      );
      expect(client.auth.currentUser?.id, 'user-a');
    },
  );

  test(
    'completed code followed by offline status lookup is not resubmitted',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) {
        if (request.method == 'POST') return _json(_emailSession());
        throw http.ClientException('Local test offline');
      };
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<EmailVerificationStatusUnavailableException>()),
      );
      expect(requests.where((request) => request.method == 'POST').length, 1);
      expect(client.auth.currentUser?.id, 'user-a');
    },
  );

  testWidgets('accepted code status timeout requires a status-only retry', (
    tester,
  ) async {
    enableEmail();
    await signedIn();
    final status = Completer<http.Response>();
    respond = (request) => request.method == 'POST'
        ? _json(_partialEmailAcknowledgement())
        : status.future;
    Object? failure;
    final verification = repository
        .verifyEmailCode('alex@example.com', '123456')
        .catchError((Object error) {
          failure = error;
        });
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await verification;
    expect(failure, isA<EmailVerificationStatusUnavailableException>());
    expect(requests.length, 2);
    expect(client.auth.currentUser?.id, 'user-a');
    status.complete(_json(_pendingEmailUser()));
    await tester.pump();
  });

  testWidgets('a verification POST timeout is not an accepted-code result', (
    tester,
  ) async {
    enableEmail();
    await signedIn();
    final response = Completer<http.Response>();
    respond = (_) => response.future;
    Object? failure;
    final verification = repository
        .verifyEmailCode('alex@example.com', '123456')
        .catchError((Object error) {
          failure = error;
        });
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await verification;
    expect(failure, isA<TimeoutException>());
    expect(failure, isNot(isA<EmailVerificationStatusUnavailableException>()));
    expect(requests.length, 1);
    response.complete(_json(_partialEmailAcknowledgement()));
    await tester.pump();
  });

  test(
    'status authorization errors do not become accepted-code recovery',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) => request.method == 'POST'
          ? _json(_partialEmailAcknowledgement())
          : _json({'msg': 'Unauthorized', 'code': 'bad_jwt'}, status: 401);
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<AuthException>()),
      );
    },
  );

  test('malformed status does not become accepted-code recovery', () async {
    enableEmail();
    await signedIn();
    respond = (request) => request.method == 'POST'
        ? _json(_partialEmailAcknowledgement())
        : _json({});
    await expectLater(
      repository.verifyEmailCode('alex@example.com', '123456'),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'modern Auth error code is preserved without trusting its message',
    () async {
      enableEmail();
      await signedIn();
      respond = (_) => _json({
        'code': 'otp_expired',
        'msg': 'Untrusted provider details',
      }, status: 403);
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(
          isA<AuthException>()
              .having((error) => error.code, 'code', 'otp_expired')
              .having(
                (error) => error.message,
                'message',
                isNot(contains('Untrusted')),
              ),
        ),
      );
    },
  );

  test('invalid JSON verification response never counts as accepted', () async {
    enableEmail();
    await signedIn();
    respond = (_) => http.Response('<html>not Auth JSON</html>', 200);
    await expectLater(
      repository.verifyEmailCode('alex@example.com', '123456'),
      throwsA(isA<FormatException>()),
    );
    expect(requests.length, 1);
  });

  test('anonymous sessions cannot bypass email verification', () async {
    enableEmail();
    await client.auth.recoverSession(
      jsonEncode({
        ..._session(),
        'user': {..._user(), 'is_anonymous': true},
      }),
    );
    await expectLater(
      repository.requestEmailVerification('alex@example.com'),
      throwsA(isA<AuthSessionMissingException>()),
    );
    await expectLater(
      repository.verifyEmailCode('alex@example.com', '123456'),
      throwsA(isA<AuthSessionMissingException>()),
    );
    expect(requests, isEmpty);
  });

  test('a canonical Auth identity mismatch is signed out', () async {
    enableEmail();
    await signedIn();
    respond = (request) => request.method == 'POST'
        ? _json(_partialEmailAcknowledgement())
        : _json(_pendingEmailUser(id: 'other-user'));
    await expectLater(
      repository.verifyEmailCode('alex@example.com', '123456'),
      throwsA(isA<AuthException>()),
    );
    expect(client.auth.currentUser, isNull);
  });

  test(
    'a user switch during code verification preserves the new account',
    () async {
      enableEmail();
      await signedIn();
      respond = (_) async {
        await signedIn(id: 'other-user');
        return _json(_partialEmailAcknowledgement());
      };
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser?.id, 'other-user');
      expect(requests.length, 1);
    },
  );

  test(
    'a user switch during canonical status lookup preserves the new account',
    () async {
      enableEmail();
      await signedIn();
      respond = (request) async {
        if (request.method == 'POST') {
          return _json(_partialEmailAcknowledgement());
        }
        await signedIn(id: 'other-user');
        return _json(_pendingEmailUser());
      };
      await expectLater(
        repository.verifyEmailCode('alex@example.com', '123456'),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser?.id, 'other-user');
    },
  );
}

Map<String, dynamic> _partialEmailAcknowledgement() => {
  'msg':
      'Confirmation link accepted. Please proceed to confirm link sent to the other email',
  'code': '200',
};

Map<String, dynamic> _pendingEmailUser({
  String id = 'user-a',
  String? email,
  String newEmail = 'alex@example.com',
}) => {
  ..._user(id: id),
  if (email != null) 'email': email,
  if (email != null) 'email_confirmed_at': '2026-10-09T00:00:00Z',
  'new_email': newEmail,
  'email_change_sent_at': '2026-10-15T00:00:00Z',
};

Map<String, dynamic> _verifiedEmailUser({
  String id = 'user-a',
  String email = 'alex@example.com',
}) => {
  ..._user(id: id),
  'email': email,
  'email_confirmed_at': '2026-10-15T00:00:00Z',
};

Map<String, dynamic> _emailSession() => {
  ..._session(),
  'refresh_token': 'discard-this-email-session-token',
  'user': _verifiedEmailUser(),
};

Map<String, dynamic> _body(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

http.Response _json(Object? value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _user({
  String id = 'user-a',
  String phone = '14807469696',
}) => {
  'id': id,
  'aud': 'authenticated',
  'role': 'authenticated',
  'created_at': '2026-10-09T00:00:00Z',
  'app_metadata': {
    'provider': 'google',
    'providers': ['google', 'phone'],
  },
  'user_metadata': {},
  'phone': phone,
  'phone_confirmed_at': '2026-10-09T00:00:00Z',
};

Map<String, dynamic> _googleUser({
  String id = 'user-a',
  String phone = '14807469696',
  bool includeGoogle = true,
  bool includePhone = true,
  bool confirmedPhone = true,
  Object? verifiedGoogle = true,
}) => {
  ..._user(id: id, phone: phone),
  if (!confirmedPhone) 'phone_confirmed_at': null,
  'identities': [
    if (includeGoogle)
      {
        'id': 'google-subject',
        'user_id': id,
        'identity_id': 'google-identity',
        'provider': 'google',
        'identity_data': {
          'email': 'Google@example.com',
          'email_verified': verifiedGoogle,
        },
      },
    if (includePhone)
      {
        'id': id,
        'user_id': id,
        'identity_id': 'phone-identity',
        'provider': 'phone',
        'identity_data': {'phone': phone},
      },
  ],
};

Map<String, dynamic> _session({
  String id = 'user-a',
  String phone = '14807469696',
}) {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  String encoded(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': id, 'exp': expires})}.local-test-signature',
    'refresh_token': 'local-test-refresh-token',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': _user(id: id, phone: phone),
  };
}

Map<String, dynamic> _accountJson() => {
  'first_name': 'Alex',
  'last_name': 'Rivera',
  'username': 'alex.r',
  'date_of_birth': '2000-01-02',
  'email': 'alex@example.com',
  'phone': '+14807469696',
  'phone_verified': true,
  'onboarding_completed': true,
  'tour_completed': true,
  'status': 'active',
};
