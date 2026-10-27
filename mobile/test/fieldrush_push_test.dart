import 'dart:async';
import 'dart:convert';

import 'package:field/src/notifications/fieldrush_push.dart';
import 'package:field/src/home/activity_revision.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = FieldrushPushConfiguration(
    enabled: true,
    environment: 'staging',
    apiKey: 'AIza-public-client-fixture',
    projectId: 'fieldrush-fixture',
    senderId: '123456789',
    iosAppId: '1:123456789:ios:abcdef',
    androidAppId: '1:123456789:android:abcdef',
  );
  test(
    'phone push defaults off and cannot activate production, desktop or invalid config',
    () {
      expect(FieldrushPushConfiguration.fromEnvironment().enabled, isFalse);
      expect(config.isValidFor(TargetPlatform.android), isTrue);
      expect(config.isValidFor(TargetPlatform.iOS), isTrue);
      expect(config.isValidFor(TargetPlatform.macOS), isFalse);
      const production = FieldrushPushConfiguration(
        enabled: true,
        environment: 'production',
        apiKey: 'AIza-public-client-fixture',
        projectId: 'fieldrush-fixture',
        senderId: '123456789',
        iosAppId: '1:123456789:ios:abcdef',
        androidAppId: '1:123456789:android:abcdef',
      );
      expect(production.isValidFor(TargetPlatform.android), isFalse);
    },
  );

  test(
    'persistent binding clock is monotonic even for concurrent lifecycle work',
    () async {
      SharedPreferences.setMockInitialValues({
        'push.binding.version': 9000000000000000,
      });
      final clock = PushBindingClock(await SharedPreferences.getInstance());
      expect(await Future.wait([clock.next(), clock.next(), clock.next()]), [
        9000000000000001,
        9000000000000002,
        9000000000000003,
      ]);
    },
  );

  late SupabaseClient client;
  late SharedPreferences storage;
  late _Messaging messaging;
  late List<http.Request> requests;
  Future<http.Response> Function(http.Request)? respond;
  FieldrushPush? push;
  setUp(() async {
    clearFieldrushActivityOpenRequest();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({
      'push.opted_in': true,
      'push.opted_in.user_id': 'user-a',
    });
    storage = await SharedPreferences.getInstance();
    messaging = _Messaging();
    requests = [];
    respond = null;
    client = SupabaseClient(
      'https://test.supabase.co',
      'public-test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        final response =
            await (respond?.call(request) ??
                Future.value(
                  http.Response(
                    'null',
                    200,
                    headers: {'content-type': 'application/json'},
                  ),
                ));
        return http.Response.bytes(
          response.bodyBytes,
          response.statusCode,
          headers: response.headers,
          request: request,
        );
      }),
    );
    await client.auth.setInitialSession(jsonEncode(_session('user-a')));
  });
  tearDown(() async {
    clearFieldrushActivityOpenRequest();
    push?.dispose();
    push = null;
    await client.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  FieldrushPush create({bool listenToAuth = false}) =>
      push = FieldrushPush.testing(
        client: client,
        messaging: messaging,
        storage: storage,
        installationId: '20000000-0000-4000-8000-000000000001',
        projectId: 'fieldrush-fixture',
        listenToAuth: listenToAuth,
      );
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<http.Request> registrations() => requests
      .where((r) => r.url.path.endsWith('register_my_push_device'))
      .toList();

  test('phone tap accepts only receipt ID and binds it to current account', () {
    const id = '20000000-0000-4000-8000-000000000099';
    create().openMessageForTesting(
      const RemoteMessage(
        data: {
          'notification_id': id,
          'game_id': 'untrusted-game',
          'route': '/private-payment',
        },
      ),
    );
    expect(fieldrushNotificationOpenRequest?.notificationId, id);
    expect(fieldrushNotificationOpenRequest?.userId, 'user-a');
    expect(fieldrushActivityOpenRequested.value, isTrue);
  });

  test('malformed phone receipt opens Activity without a destination', () {
    create().openMessageForTesting(
      const RemoteMessage(
        data: {'notification_id': 'not-a-receipt', 'game_id': 'untrusted-game'},
      ),
    );
    expect(fieldrushNotificationOpenRequest, isNull);
    expect(fieldrushActivityOpenRequested.value, isTrue);
  });

  test('account switching clears an old pending phone tap', () async {
    final controller = create(listenToAuth: true);
    controller.openMessageForTesting(
      const RemoteMessage(
        data: {'notification_id': '20000000-0000-4000-8000-000000000099'},
      ),
    );
    await client.auth.setInitialSession(jsonEncode(_session('user-b')));
    await settle();
    expect(fieldrushNotificationOpenRequest, isNull);
    expect(fieldrushActivityOpenRequested.value, isFalse);
  });

  test(
    'signed-out phone tap waits for owner-checked lookup after sign-in',
    () async {
      final controller = create(listenToAuth: true);
      await client.auth.signOut(scope: SignOutScope.local);
      await settle();
      controller.openMessageForTesting(
        const RemoteMessage(
          data: {
            'notification_id': '20000000-0000-4000-8000-000000000099',
            'route': '/untrusted',
          },
        ),
      );
      expect(fieldrushActivityOpenRequested.value, isFalse);
      await client.auth.setInitialSession(jsonEncode(_session('user-b')));
      await settle();
      expect(
        fieldrushNotificationOpenRequest?.notificationId,
        '20000000-0000-4000-8000-000000000099',
      );
      // The opaque ID is looked up as the new signed-in user. The owner RPC,
      // rather than the old phone payload, determines whether it can be opened.
      expect(fieldrushNotificationOpenRequest?.userId, 'user-b');
      expect(fieldrushActivityOpenRequested.value, isTrue);
    },
  );

  test(
    'booking permission request is contextual and never repeats denial',
    () async {
      await storage.remove('push.opted_in');
      await storage.remove('push.opted_in.user_id');
      messaging.permission = AuthorizationStatus.denied;
      final controller = create();
      expect(messaging.permissionRequests, 0);
      await controller.offerAfterBooking();
      await controller.offerAfterBooking();
      expect(messaging.permissionRequests, 1);
      expect(controller.phoneEnabled, isFalse);
      expect(registrations(), isEmpty);
    },
  );

  test(
    'background booking and explicit opt-out do not prompt permission',
    () async {
      await storage.remove('push.opted_in');
      await storage.remove('push.opted_in.user_id');
      final controller = create();
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await controller.offerAfterBooking();
      expect(messaging.permissionRequests, 0);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      await controller.disableOnThisPhone();
      await controller.offerAfterBooking();
      expect(messaging.permissionRequests, 0);
    },
  );

  test(
    'logout invalidates an in-flight register and persists a newer server tombstone',
    () async {
      final controller = create();
      await controller.synchronizeForTesting();
      expect(controller.phoneEnabled, isTrue);
      final hold = Completer<http.Response>();
      respond = (request) async =>
          request.url.path.endsWith('register_my_push_device')
          ? hold.future
          : http.Response(
              'null',
              200,
              headers: {'content-type': 'application/json'},
            );
      final pending = controller.synchronizeForTesting();
      await settle();
      await controller.prepareForSignOut();
      final oldVersion =
          jsonDecode(registrations().last.body)['binding_version_to_use']
              as int;
      final revocation = requests.lastWhere(
        (r) => r.url.path.endsWith('revoke_my_push_device'),
      );
      expect(
        jsonDecode(revocation.body)['binding_version_to_use'],
        greaterThan(oldVersion),
      );
      hold.complete(
        http.Response(
          'null',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await pending;
      expect(controller.phoneEnabled, isFalse);
      expect(storage.getBool('push.opted_in'), isFalse);
      expect(messaging.deletions, greaterThanOrEqualTo(2));
    },
  );

  test(
    'token refresh cannot undo logout suppression while server revocation is pending',
    () async {
      final controller = create(listenToAuth: true);
      await settle();
      await controller.synchronizeForTesting();
      final count = registrations().length;
      final hold = Completer<http.Response>();
      respond = (request) async =>
          request.url.path.endsWith('revoke_my_push_device')
          ? hold.future
          : http.Response(
              request.url.path.endsWith('/token')
                  ? jsonEncode(_session('user-a'))
                  : 'null',
              200,
              headers: {'content-type': 'application/json'},
            );
      final logout = controller.prepareForSignOut();
      await settle();
      await client.auth.refreshSession();
      await settle();
      expect(registrations().length, count);
      hold.complete(
        http.Response(
          'null',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await logout;
      await settle();
      expect(controller.phoneEnabled, isFalse);
    },
  );

  test(
    'new account waits for prior token deletion and needs explicit phone opt-in',
    () async {
      final controller = create(listenToAuth: true);
      await settle();
      await controller.synchronizeForTesting();
      final count = registrations().length;
      final deletion = Completer<void>();
      messaging.deleteHold = deletion;
      final logout = controller.prepareForSignOut();
      await settle();
      await client.auth.setInitialSession(jsonEncode(_session('user-b')));
      await settle();
      expect(registrations().length, count);
      deletion.complete();
      await logout;
      await settle();
      expect(controller.phoneEnabled, isFalse);
      expect(registrations().length, count);
      messaging.deleteHold = null;
      await controller.enableOnThisPhone();
      expect(controller.phoneEnabled, isTrue);
      expect(registrations().length, greaterThan(count));
    },
  );

  test(
    'denied OS permission never registers a device or claims phone delivery',
    () async {
      messaging.permission = AuthorizationStatus.denied;
      final controller = create();
      await controller.synchronizeForTesting();
      expect(controller.phoneEnabled, isFalse);
      expect(registrations(), isEmpty);
      expect(controller.status, contains('off'));
    },
  );

  test(
    'offline opt-out persists cleanup and retries server and provider when online',
    () async {
      final controller = create();
      await controller.synchronizeForTesting();
      final registrationsBeforeDisable = registrations().length;
      messaging.deleteError = StateError('Fixture provider is offline');
      respond = (request) async => http.Response(
        request.url.path.endsWith('revoke_my_push_device')
            ? '{"message":"Fixture network is offline"}'
            : 'null',
        request.url.path.endsWith('revoke_my_push_device') ? 503 : 200,
        headers: {'content-type': 'application/json'},
      );
      await controller.disableOnThisPhone();
      expect(controller.phoneEnabled, isFalse);
      expect(controller.status, contains('pending'));
      expect(storage.getBool('push.opted_in'), isFalse);
      expect(storage.getBool('push.cleanup.pending'), isTrue);
      expect(storage.getString('push.cleanup.user_id'), 'user-a');
      final deletionAttempts = messaging.deletions;
      final revokeAttempts = requests
          .where((r) => r.url.path.endsWith('revoke_my_push_device'))
          .length;

      messaging.deleteError = null;
      respond = null;
      await controller.synchronizeForTesting();
      expect(messaging.deletions, greaterThan(deletionAttempts));
      expect(
        requests
            .where((r) => r.url.path.endsWith('revoke_my_push_device'))
            .length,
        greaterThan(revokeAttempts),
      );
      expect(storage.getBool('push.cleanup.pending'), isFalse);
      expect(controller.status, contains('off'));
      expect(registrations().length, registrationsBeforeDisable);
    },
  );

  test(
    'persisted cleanup survives restart and blocks a new owner until provider deletion succeeds',
    () async {
      await storage.setBool('push.opted_in', false);
      await storage.remove('push.opted_in.user_id');
      await storage.setBool('push.cleanup.pending', true);
      await storage.setString('push.cleanup.user_id', 'user-a');
      await client.auth.setInitialSession(jsonEncode(_session('user-b')));
      final controller = create();
      messaging.deleteError = StateError('Fixture provider is offline');
      await controller.enableOnThisPhone();
      expect(registrations(), isEmpty);
      expect(storage.getBool('push.opted_in'), isFalse);
      expect(storage.getBool('push.cleanup.pending'), isTrue);
      expect(controller.status, contains('pending'));
      expect(
        requests.where((r) => r.url.path.endsWith('revoke_my_push_device')),
        isEmpty,
      );

      messaging.deleteError = null;
      await controller.synchronizeForTesting();
      expect(storage.getBool('push.cleanup.pending'), isFalse);
      expect(registrations(), isEmpty);
      await controller.enableOnThisPhone();
      expect(controller.phoneEnabled, isTrue);
      expect(storage.getString('push.opted_in.user_id'), 'user-b');
      expect(registrations(), hasLength(1));
    },
  );

  testWidgets(
    'pending opt-out automatically retries after 30 foreground seconds',
    (tester) async {
      try {
        final controller = create();
        await controller.synchronizeForTesting();
        final registrationsBeforeDisable = registrations().length;
        messaging.deleteError = StateError('Fixture provider is offline');
        respond = (request) async => http.Response(
          '{"message":"Fixture network is offline"}',
          503,
          headers: {'content-type': 'application/json'},
        );
        await controller.disableOnThisPhone();
        final deletionAttempts = messaging.deletions;
        expect(storage.getBool('push.cleanup.pending'), isTrue);

        messaging.deleteError = null;
        respond = null;
        await tester.pump(const Duration(seconds: 29));
        expect(messaging.deletions, deletionAttempts);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(messaging.deletions, greaterThan(deletionAttempts));
        expect(storage.getBool('push.cleanup.pending'), isFalse);
        expect(controller.phoneEnabled, isFalse);
        expect(registrations().length, registrationsBeforeDisable);
      } finally {
        // Widget-test invariants run before the enclosing ordinary tearDown.
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test(
    'a different account cannot inherit another user phone opt-in',
    () async {
      final controller = create();
      await controller.synchronizeForTesting();
      final count = registrations().length;
      await client.auth.setInitialSession(jsonEncode(_session('user-b')));
      await controller.synchronizeForTesting();
      expect(controller.phoneEnabled, isFalse);
      expect(registrations().length, count);
      await controller.enableOnThisPhone();
      expect(controller.phoneEnabled, isTrue);
      expect(storage.getString('push.opted_in.user_id'), 'user-b');
    },
  );

  test(
    'account change during permission dialog cannot reuse former consent',
    () async {
      final controller = create();
      final permission = Completer<NotificationSettings>();
      messaging.permissionHold = permission;
      final enabling = controller.enableOnThisPhone();
      await settle();
      await client.auth.setInitialSession(jsonEncode(_session('user-b')));
      permission.complete(_Permission(AuthorizationStatus.authorized));
      await enabling;
      expect(controller.phoneEnabled, isFalse);
      expect(registrations(), isEmpty);
      expect(storage.getString('push.opted_in.user_id'), 'user-a');
    },
  );
  test(
    'same-user resume during permission dialog does not discard granted consent',
    () async {
      final controller = create();
      await storage.setBool('push.opted_in', false);
      await storage.remove('push.opted_in.user_id');
      final permission = Completer<NotificationSettings>();
      messaging.permissionHold = permission;
      final enabling = controller.enableOnThisPhone();
      await settle();
      // Foreground/resume performs an ordinary generation-changing refresh.
      await controller.synchronizeForTesting();
      permission.complete(_Permission(AuthorizationStatus.authorized));
      await enabling;
      expect(controller.phoneEnabled, isTrue);
      expect(registrations(), hasLength(1));
      expect(storage.getString('push.opted_in.user_id'), 'user-a');
    },
  );
  test(
    'restoring OS permission uses a binding newer than its revocation',
    () async {
      final controller = create();
      await controller.synchronizeForTesting();
      messaging.permission = AuthorizationStatus.denied;
      await controller.synchronizeForTesting();
      final revocation = requests.lastWhere(
        (r) => r.url.path.endsWith('revoke_my_push_device'),
      );
      final revokedVersion =
          jsonDecode(revocation.body)['binding_version_to_use'] as int;
      messaging.permission = AuthorizationStatus.authorized;
      await controller.synchronizeForTesting();
      final renewed =
          jsonDecode(registrations().last.body)['binding_version_to_use']
              as int;
      expect(renewed, greaterThan(revokedVersion));
      expect(controller.phoneEnabled, isTrue);
    },
  );
  test(
    'iOS starts APNs registration only after explicit opt-in and permission',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final controller = create();
      await controller.synchronizeForTesting();
      expect(controller.phoneEnabled, isTrue);
      expect(jsonDecode(registrations().single.body)['platform_to_use'], 'ios');
      expect(messaging.autoInit, isTrue);
    },
  );
}

Map<String, Object?> _session(String id) => {
  'access_token': 'fixture-jwt-$id',
  'refresh_token': 'fixture-refresh-$id',
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
  'user': {
    'id': id,
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
    'aud': 'authenticated',
    'created_at': '2026-01-01T00:00:00Z',
  },
};

class _Permission extends Fake implements NotificationSettings {
  _Permission(this.authorizationStatus);
  @override
  final AuthorizationStatus authorizationStatus;
}

class _Messaging extends Fake implements FirebaseMessaging {
  int deletions = 0;
  int permissionRequests = 0;
  bool autoInit = false;
  AuthorizationStatus permission = AuthorizationStatus.authorized;
  Completer<void>? deleteHold;
  Object? deleteError;
  Completer<NotificationSettings>? permissionHold;
  @override
  Future<NotificationSettings> getNotificationSettings() async =>
      _Permission(permission);
  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    permissionRequests++;
    return permissionHold == null
        ? _Permission(permission)
        : await permissionHold!.future;
  }

  @override
  Future<void> setAutoInitEnabled(bool enabled) async {
    autoInit = enabled;
  }

  @override
  Future<String?> getAPNSToken() async =>
      autoInit ? 'fixture-apns-token' : null;
  @override
  Future<void> deleteToken() async {
    deletions++;
    await deleteHold?.future;
    if (deleteError != null) throw deleteError!;
  }

  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async => 'fixture-device-token-not-a-real-registration';
}
