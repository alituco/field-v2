import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../home/activity_revision.dart';
import 'firebase_staging_options.dart';

class FieldrushPushConfiguration {
  const FieldrushPushConfiguration({
    required this.enabled,
    required this.environment,
    required this.apiKey,
    required this.projectId,
    required this.senderId,
    required this.iosAppId,
    required this.androidAppId,
  });

  factory FieldrushPushConfiguration.fromEnvironment() {
    const environment = String.fromEnvironment('APP_ENV');
    const suppliedApiKey = String.fromEnvironment('PUSH_FIREBASE_API_KEY');
    return FieldrushPushConfiguration(
      enabled: const bool.fromEnvironment('PUSH_NOTIFICATIONS_ENABLED'),
      environment: environment,
      apiKey: suppliedApiKey.isNotEmpty
          ? suppliedApiKey
          : environment == 'staging'
          ? (defaultTargetPlatform == TargetPlatform.iOS
                ? fieldrushStagingFirebaseIosApiKey
                : fieldrushStagingFirebaseAndroidApiKey)
          : '',
      projectId:
          const String.fromEnvironment('PUSH_FIREBASE_PROJECT_ID').isNotEmpty
          ? const String.fromEnvironment('PUSH_FIREBASE_PROJECT_ID')
          : environment == 'staging'
          ? fieldrushStagingFirebaseProjectId
          : '',
      senderId:
          const String.fromEnvironment('PUSH_FIREBASE_SENDER_ID').isNotEmpty
          ? const String.fromEnvironment('PUSH_FIREBASE_SENDER_ID')
          : environment == 'staging'
          ? fieldrushStagingFirebaseSenderId
          : '',
      iosAppId:
          const String.fromEnvironment('PUSH_FIREBASE_IOS_APP_ID').isNotEmpty
          ? const String.fromEnvironment('PUSH_FIREBASE_IOS_APP_ID')
          : environment == 'staging'
          ? fieldrushStagingFirebaseIosAppId
          : '',
      androidAppId:
          const String.fromEnvironment(
            'PUSH_FIREBASE_ANDROID_APP_ID',
          ).isNotEmpty
          ? const String.fromEnvironment('PUSH_FIREBASE_ANDROID_APP_ID')
          : environment == 'staging'
          ? fieldrushStagingFirebaseAndroidAppId
          : '',
    );
  }

  final bool enabled;
  final String environment;
  final String apiKey;
  final String projectId;
  final String senderId;
  final String iosAppId;
  final String androidAppId;

  bool isValidFor(TargetPlatform platform) =>
      enabled &&
      !kIsWeb &&
      (environment == 'staging' || environment == 'local') &&
      (platform == TargetPlatform.iOS || platform == TargetPlatform.android) &&
      apiKey.startsWith('AIza') &&
      RegExp(r'^[a-z][a-z0-9-]{4,62}$').hasMatch(projectId) &&
      RegExp(r'^\d+$').hasMatch(senderId) &&
      RegExp(
        platform == TargetPlatform.iOS
            ? r'^1:\d+:ios:[a-f0-9]+$'
            : r'^1:\d+:android:[a-f0-9]+$',
      ).hasMatch(platform == TargetPlatform.iOS ? iosAppId : androidAppId);

  FirebaseOptions options(TargetPlatform platform) => FirebaseOptions(
    apiKey: apiKey,
    appId: platform == TargetPlatform.iOS ? iosAppId : androidAppId,
    messagingSenderId: senderId,
    projectId: projectId,
    iosBundleId: platform == TargetPlatform.iOS
        ? 'com.alialtaraif.field.staging'
        : null,
  );
}

/// Server binding versions complement the client generation guard: an old
/// in-flight registration cannot resurrect a binding revoked during logout.
class PushBindingClock {
  PushBindingClock(this.preferences);
  final SharedPreferences preferences;
  Future<void> _pending = Future.value();

  Future<int> next() {
    final result = Completer<int>();
    _pending = _pending.then((_) async {
      try {
        final previous = preferences.getInt('push.binding.version') ?? 0;
        final now = DateTime.now().microsecondsSinceEpoch;
        final value = now > previous ? now : previous + 1;
        await preferences.setInt('push.binding.version', value);
        result.complete(value);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}

class FieldrushPush extends ChangeNotifier with WidgetsBindingObserver {
  FieldrushPush._();
  static final instance = FieldrushPush._();

  @visibleForTesting
  factory FieldrushPush.testing({
    required SupabaseClient client,
    required FirebaseMessaging messaging,
    required SharedPreferences storage,
    required String installationId,
    required String projectId,
    bool listenToAuth = true,
  }) {
    final push = FieldrushPush._()
      .._client = client
      .._messaging = messaging
      .._storage = storage
      .._clock = PushBindingClock(storage)
      .._installationId = installationId
      .._projectId = projectId
      .._propagateErrorsForTesting = true
      .._configured = true;
    if (listenToAuth) push._listenToAuth();
    return push;
  }

  @visibleForTesting
  Future<void> synchronizeForTesting() => _synchronize();

  @visibleForTesting
  void openMessageForTesting(RemoteMessage message) => _openMessage(message);

  SupabaseClient? _client;
  FirebaseMessaging? _messaging;
  SharedPreferences? _storage;
  PushBindingClock? _clock;
  String? _installationId;
  String? _bindingUser;
  int _bindingVersion = 0;
  int _generation = 0;
  int _consentEpoch = 0;
  String? _observedAuthUser;
  String? _pendingSignedOutTapId;
  bool _configured = false;
  bool _registered = false;
  bool _busy = false;
  bool _loggingOut = false;
  bool _configuring = false;
  bool _propagateErrorsForTesting = false;
  bool _pendingCleanup = false;
  String? _pendingCleanupUser;
  bool _foregroundActive = true;
  Timer? _cleanupRetry;
  String? _logoutUser;
  String _projectId = '';
  FieldrushPushConfiguration? _configuration;
  Future<void> _cleanup = Future.value();
  Future<void> _providerOperations = Future.value();
  StreamSubscription<AuthState>? _auth;
  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<RemoteMessage>? _foreground;
  StreamSubscription<RemoteMessage>? _opened;

  String status =
      'Phone notifications are not configured yet. Your Activity is still available in the app.';
  bool get canEnable => _configured && !_busy && !_registered && !_loggingOut;
  bool get busy => _busy;
  bool get phoneEnabled => _registered;
  bool get canRefreshSetup =>
      _configuration != null && !_configured && !_configuring;

  Future<void> initialize(
    SupabaseClient client,
    FieldrushPushConfiguration configuration,
  ) async {
    if (!configuration.isValidFor(defaultTargetPlatform)) return;
    _client = client;
    _projectId = configuration.projectId;
    _configuration = configuration;
    WidgetsBinding.instance.addObserver(this);
    _listenToAuth();
    await _configureForCurrentSession();
  }

  void _listenToAuth() {
    _observedAuthUser = _client!.auth.currentUser?.id;
    _auth = _client!.auth.onAuthStateChange.listen((event) {
      final observedUser = event.session?.user.id;
      if (observedUser != _observedAuthUser ||
          event.event == AuthChangeEvent.signedOut) {
        clearFieldrushActivityOpenRequest();
        _consentEpoch++;
        _observedAuthUser = observedUser;
      }
      if (_loggingOut &&
          event.event != AuthChangeEvent.signedOut &&
          event.session?.user.id == _logoutUser) {
        return;
      }
      _loggingOut = false;
      _logoutUser = null;
      final pendingTap = _pendingSignedOutTapId;
      if (observedUser != null && pendingTap != null) {
        _pendingSignedOutTapId = null;
        requestFieldrushNotificationOpen(pendingTap, observedUser);
      }
      unawaited(_configured ? _synchronize() : _configureForCurrentSession());
    });
  }

  Future<void> _configureForCurrentSession() async {
    if (_configuring || _configured || _client?.auth.currentUser == null) {
      return;
    }
    _configuring = true;
    try {
      final capability = await _client!
          .rpc('get_my_push_capability')
          .timeout(const Duration(seconds: 8));
      if (capability is! Map ||
          capability['enabled'] != true ||
          capability['firebase_project_id'] != _projectId) {
        return;
      }
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: _configuration!.options(defaultTargetPlatform),
        );
      } else if (Firebase.app().options.projectId != _projectId) {
        throw StateError('The Firebase project does not match this build.');
      }
      _messaging = FirebaseMessaging.instance;
      _storage = await SharedPreferences.getInstance();
      _clock = PushBindingClock(_storage!);
      _installationId = _storage!.getString('push.installation.id');
      if (_installationId == null) {
        _installationId = const Uuid().v4();
        await _storage!.setString('push.installation.id', _installationId!);
      }
      _configured = true;
      status = 'Enable phone notifications on this device.';
      _tokenRefresh = _messaging!.onTokenRefresh.listen(
        (_) => unawaited(_synchronize()),
      );
      _foreground = FirebaseMessaging.onMessage.listen(
        (_) => notifyFieldrushActivityChanged(),
      );
      _opened = FirebaseMessaging.onMessageOpenedApp.listen(_openMessage);
      final initialMessage = await _messaging!.getInitialMessage();
      if (initialMessage != null) _openMessage(initialMessage);
      await _messaging!.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: false,
      );
      await _synchronize();
    } catch (_) {
      status =
          'Phone notifications are unavailable. Your Activity is still available in the app.';
      notifyListeners();
    } finally {
      _configuring = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foregroundActive = state == AppLifecycleState.resumed;
    if (!_foregroundActive) {
      _cleanupRetry?.cancel();
      _cleanupRetry = null;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_configured ? _synchronize() : _configureForCurrentSession());
    }
  }

  Future<void> refreshSetup() => _configureForCurrentSession();

  void _openMessage(RemoteMessage message) {
    final owner = _client?.auth.currentUser?.id;
    final id = message.data['notification_id'];
    if (_loggingOut) return;
    if (id is String &&
        RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(id)) {
      if (owner == null) {
        // Retain only an opaque ID until sign-in. The eventual owner's RPC
        // decides whether it belongs to them; a different account sees nothing.
        _pendingSignedOutTapId = id;
      } else {
        requestFieldrushNotificationOpen(id, owner);
      }
    } else if (owner != null) {
      requestFieldrushActivityOpen();
    }
  }

  /// Called from the visible success screen, never at app launch. A dismissed
  /// or denied request is not repeated on every subsequent booking.
  Future<void> offerAfterBooking() async {
    try {
      final owner = _client?.auth.currentUser?.id;
      final storage = _storage;
      if (!canEnable ||
          owner == null ||
          storage == null ||
          !_foregroundActive) {
        return;
      }
      if (storage.getBool('push.opted_in') == true &&
          storage.getString('push.opted_in.user_id') == owner) {
        return;
      }
      final key = 'push.booking_prompt.$owner';
      if (storage.getBool(key) == true) return;
      await storage.setBool(key, true);
      if (_client?.auth.currentUser?.id != owner || _loggingOut) return;
      await enableOnThisPhone();
    } catch (_) {
      // Notification setup is optional and cannot turn a confirmed booking
      // into an error. Settings keeps the explicit retry action available.
    }
  }

  Future<void> enableOnThisPhone() async {
    if (!canEnable || _client?.auth.currentUser == null) return;
    final userId = _client!.auth.currentUser!.id;
    final consentEpoch = _consentEpoch;
    _busy = true;
    notifyListeners();
    try {
      // A new account must not reuse a token whose previous owner's offline
      // sign-out/opt-out is still awaiting provider cleanup.
      await _drainPendingCleanup();
      if (_hasPendingCleanup ||
          _loggingOut ||
          consentEpoch != _consentEpoch ||
          _client?.auth.currentUser?.id != userId) {
        return;
      }
      await _storage!.setBool('push.booking_prompt.$userId', true);
      if (_loggingOut ||
          consentEpoch != _consentEpoch ||
          _client?.auth.currentUser?.id != userId) {
        return;
      }
      final permission = await _messaging!.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      // Permission dialogs commonly resume the app and refresh its token. Only
      // logout/account changes invalidate this explicit consent operation.
      if (_loggingOut ||
          consentEpoch != _consentEpoch ||
          _client?.auth.currentUser?.id != userId) {
        return;
      }
      if (permission.authorizationStatus != AuthorizationStatus.authorized &&
          permission.authorizationStatus != AuthorizationStatus.provisional) {
        status =
            'Phone notifications are off. You can allow them in your device settings; Activity remains available.';
        return;
      }
      await _storage!.setBool('push.opted_in', true);
      await _storage!.setString('push.opted_in.user_id', userId);
      await _synchronize();
    } catch (_) {
      status =
          'Could not enable phone notifications. Try again; Activity remains available.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _synchronize() async {
    if (!_configured || _loggingOut) return;
    final generation = ++_generation;
    final userId = _client!.auth.currentUser?.id;
    try {
      await _cleanup;
      if (!_isCurrent(generation, userId)) return;
      await _drainPendingCleanup();
      if (!_isCurrent(generation, userId) || _hasPendingCleanup) return;
      if (userId == null) {
        await _recordPendingCleanup(
          _bindingUser ?? _storage!.getString('push.opted_in.user_id'),
        );
        await _storage!.setBool('push.opted_in', false);
        await _storage!.remove('push.opted_in.user_id');
        await _drainPendingCleanup();
        if (!_isCurrent(generation, userId) || _hasPendingCleanup) return;
        status = 'Sign in to enable phone notifications.';
        notifyListeners();
        return;
      }
      if (_storage!.getBool('push.opted_in') != true ||
          _storage!.getString('push.opted_in.user_id') != userId) {
        if (_storage!.getString('push.opted_in.user_id') != null &&
            _storage!.getString('push.opted_in.user_id') != userId) {
          await _recordPendingCleanup(
            _storage!.getString('push.opted_in.user_id'),
          );
          await _storage!.setBool('push.opted_in', false);
          await _storage!.remove('push.opted_in.user_id');
          await _drainPendingCleanup();
          if (!_isCurrent(generation, userId) || _hasPendingCleanup) return;
        }
        _registered = false;
        status =
            'Phone notifications are off on this device. Activity remains available.';
        notifyListeners();
        return;
      }
      final permission = await _messaging!.getNotificationSettings();
      if (!_isCurrent(generation, userId)) return;
      if (permission.authorizationStatus != AuthorizationStatus.authorized &&
          permission.authorizationStatus != AuthorizationStatus.provisional) {
        if (_bindingUser == userId && _bindingVersion > 0) {
          await _revoke(userId);
        }
        if (!_isCurrent(generation, userId)) return;
        _bindingUser = null;
        _bindingVersion = 0;
        _registered = false;
        status =
            'Phone notifications are off. Activity remains available in the app.';
        notifyListeners();
        return;
      }
      if (_bindingUser != userId) {
        // Serialize token deletion before another account binds this installation.
        await _deleteToken();
        if (!_isCurrent(generation, userId)) return;
        final version = await _clock!.next();
        if (!_isCurrent(generation, userId)) return;
        _bindingVersion = version;
        _bindingUser = userId;
      }
      // Opt-in is now explicit and permissions are granted. Enabling auto-init
      // requests APNs registration; checking APNs first would wait forever while
      // native auto-init is intentionally disabled in Info.plist.
      await _messaging!.setAutoInitEnabled(true);
      if (!_isCurrent(generation, userId)) return;
      if (defaultTargetPlatform == TargetPlatform.iOS &&
          await _messaging!.getAPNSToken() == null) {
        _registered = false;
        status =
            'Phone notifications are waiting for Apple device registration. Try again on a configured physical device.';
        notifyListeners();
        return;
      }
      final token = await _provider(
        () => _messaging!.getToken().timeout(const Duration(seconds: 8)),
      );
      if (!_isCurrent(generation, userId)) return;
      if (token == null) {
        _registered = false;
        status =
            'Could not get a phone notification token. Try again; Activity remains available.';
        notifyListeners();
        return;
      }
      await _client!
          .rpc(
            'register_my_push_device',
            params: {
              'installation_id_to_use': _installationId,
              'binding_version_to_use': _bindingVersion,
              'token_to_use': token,
              'platform_to_use': defaultTargetPlatform == TargetPlatform.iOS
                  ? 'ios'
                  : 'android',
              'firebase_project_id_to_use': _projectId,
            },
          )
          .timeout(const Duration(seconds: 8));
      if (!_isCurrent(generation, userId)) return;
      _registered = true;
      status = 'Phone notifications are enabled on this device.';
      notifyListeners();
    } catch (_) {
      if (_propagateErrorsForTesting) rethrow;
      if (_isCurrent(generation, userId)) {
        // A response may be lost after the server accepted a revocation.
        // Retry with a fresh version rather than resurrecting that binding.
        _bindingUser = null;
        _bindingVersion = 0;
        _registered = false;
        status =
            'Could not register phone notifications. Try again; Activity remains available.';
        notifyListeners();
      }
    }
  }

  bool _isCurrent(int generation, String? userId) =>
      generation == _generation &&
      !_loggingOut &&
      _client?.auth.currentUser?.id == userId;

  Future<void> _deleteToken() async {
    await _provider(() async {
      await _messaging
          ?.setAutoInitEnabled(false)
          .timeout(const Duration(seconds: 4));
      await _messaging?.deleteToken().timeout(const Duration(seconds: 4));
    });
  }

  Future<T> _provider<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _providerOperations = _providerOperations.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> _revoke(String userId) async {
    final version = await _clock!.next();
    if (_client?.auth.currentUser?.id != userId) return;
    await _client!
        .rpc(
          'revoke_my_push_device',
          params: {
            'installation_id_to_use': _installationId,
            'binding_version_to_use': version,
          },
        )
        .timeout(const Duration(seconds: 4));
    _bindingVersion = version;
  }

  bool get _hasPendingCleanup =>
      _pendingCleanup || _storage?.getBool('push.cleanup.pending') == true;

  Future<void> _recordPendingCleanup(String? userId) async {
    if (_hasPendingCleanup) return;
    _pendingCleanup = true;
    _pendingCleanupUser = userId;
    try {
      // Persist before network work, so app termination cannot silently turn a
      // failed revocation into a permanently forgotten opt-out.
      await _storage!.setBool('push.cleanup.pending', true);
      if (userId == null) {
        await _storage!.remove('push.cleanup.user_id');
      } else {
        await _storage!.setString('push.cleanup.user_id', userId);
      }
    } catch (_) {
      // Keep the in-memory tombstone when local persistence is unavailable.
    }
  }

  Future<void> _drainPendingCleanup() async {
    if (!_hasPendingCleanup) return;
    _cleanup = _cleanup.then((_) => _performPendingCleanup());
    await _cleanup;
  }

  Future<void> _performPendingCleanup() async {
    if (!_hasPendingCleanup) return;
    final owner =
        _pendingCleanupUser ?? _storage!.getString('push.cleanup.user_id');
    // Never retain or replay a previous account's JWT. Once its session has
    // gone, deleting the provider token is the available privacy boundary.
    var revoked = owner == null || _client?.auth.currentUser?.id != owner;
    if (!revoked) {
      try {
        await _revoke(owner);
        revoked = true;
      } catch (_) {
        // Resume/reconnect will retry while the original owner is signed in.
      }
    }
    var deleted = false;
    try {
      await _deleteToken();
      deleted = true;
    } catch (_) {
      // Provider cleanup must succeed before another account can register.
    }
    if (revoked && deleted) {
      try {
        await _storage!.remove('push.cleanup.user_id');
        await _storage!.setBool('push.cleanup.pending', false);
        _pendingCleanup = false;
        _pendingCleanupUser = null;
      } catch (_) {
        // Retrying successful cleanup is safe; losing a failed cleanup is not.
      }
    }
    _registered = false;
    _bindingUser = null;
    _bindingVersion = 0;
    status = _hasPendingCleanup
        ? 'Turning off phone notifications is pending. We will retry when online; Activity remains available.'
        : 'Phone notifications are off on this device.';
    if (_hasPendingCleanup) {
      _scheduleCleanupRetry();
    } else {
      _cleanupRetry?.cancel();
      _cleanupRetry = null;
    }
    notifyListeners();
  }

  void _scheduleCleanupRetry() {
    if (!_foregroundActive || !_hasPendingCleanup || _cleanupRetry != null) {
      return;
    }
    _cleanupRetry = Timer(const Duration(seconds: 30), () {
      _cleanupRetry = null;
      if (_foregroundActive && _hasPendingCleanup) {
        // Retry only cleanup, never registration or a permission request. This
        // also works while an offline sign-out is still completing.
        unawaited(_drainPendingCleanup());
      }
    });
  }

  /// Called while the original JWT still exists. Always bounded, including when
  /// offline. Generic lock-screen previews contain no private account content.
  Future<void> prepareForSignOut() async {
    clearFieldrushActivityOpenRequest();
    _pendingSignedOutTapId = null;
    if (!_configured) return;
    ++_generation;
    ++_consentEpoch;
    _loggingOut = true;
    final userId = _client?.auth.currentUser?.id;
    _logoutUser = userId;
    _cleanup = _cleanup.then((_) async {
      await _recordPendingCleanup(userId);
      try {
        await _storage!.setBool('push.opted_in', false);
        await _storage!.remove('push.opted_in.user_id');
      } catch (_) {
        /* Still revoke and delete the token if local persistence is unavailable. */
      }
      await _performPendingCleanup();
    });
    await _cleanup;
  }

  Future<void> disableOnThisPhone() async {
    _busy = true;
    notifyListeners();
    try {
      final owner = _client?.auth.currentUser?.id;
      if (owner != null) {
        await _storage?.setBool('push.booking_prompt.$owner', true);
      }
      await prepareForSignOut();
    } finally {
      _loggingOut = false;
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _cleanupRetry?.cancel();
    _cleanupRetry = null;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_auth?.cancel());
    unawaited(_tokenRefresh?.cancel());
    unawaited(_foreground?.cancel());
    unawaited(_opened?.cancel());
    super.dispose();
  }
}
