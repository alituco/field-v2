import 'dart:async';
import 'dart:convert';

import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/auth/fieldrush_account_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late SupabaseClient client;
  late SupabaseFieldrushAccountRepository repository;
  late List<http.Request> requests;
  late FutureOr<http.Response> Function(http.Request) respond;

  setUp(() {
    requests = [];
    respond = (request) => throw StateError(
      'Unexpected local mock request: ${request.method} ${request.url.path}',
    );
    client = SupabaseClient(
      'https://fieldrush-tests.invalid',
      'test-anon-key-not-a-secret',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/auth/v1/logout') {
          return http.Response('', 204);
        }
        final response = await respond(request);
        return http.Response.bytes(
          response.bodyBytes,
          response.statusCode,
          headers: response.headers,
          request: request,
        );
      }),
    );
    repository = SupabaseFieldrushAccountRepository(
      client: client,
      emailDeliveryEnabled: false,
    );
  });

  tearDown(() async {
    await client.dispose();
  });

  Future<void> signedIn({String id = 'user-a'}) async {
    await client.auth.recoverSession(jsonEncode(_session(id: id)));
  }

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
      respond = (_) => _json(_accountJson());
      await repository.updateAccount(
        const AccountDraft(
          firstName: 'Alex',
          skillAssessment: SkillAssessment.highlyCompetitive,
        ),
      );
      expect(
        requests.single.url.path,
        '/rest/v1/rpc/update_my_fieldrush_account',
      );
      expect(
        _body(requests.single)['draft'],
        isNot(contains('skill_assessment')),
      );
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
    repository = SupabaseFieldrushAccountRepository(
      client: client,
      emailDeliveryEnabled: true,
    );
    await signedIn();
    respond = (_) => _json(_session(id: 'other-user'));
    await expectLater(
      repository.verifyEmailCode('other@example.com', '123456'),
      throwsA(isA<AuthException>()),
    );
    expect(client.auth.currentUser, isNull);
  });

  test('email-change verification needs an authenticated account', () async {
    repository = SupabaseFieldrushAccountRepository(
      client: client,
      emailDeliveryEnabled: true,
    );
    await expectLater(
      repository.verifyEmailCode('alex@example.com', '123456'),
      throwsA(isA<AuthException>()),
    );
    expect(requests, isEmpty);
  });
}

Map<String, dynamic> _body(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

http.Response _json(Object value, {int status = 200}) => http.Response(
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
