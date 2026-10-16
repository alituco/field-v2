import 'package:supabase_flutter/supabase_flutter.dart';

import 'date_of_birth.dart';

abstract class AuthRepository {
  Session? get currentSession;
  User? get currentUser;
  Stream<AuthState> get authStateChanges;

  Future<void> sendPhoneOtp(String phone);
  Future<void> verifyPhoneOtp({required String phone, required String token});
  Future<void> updateDisplayName(String displayName);
  Future<void> updateDateOfBirth(DateTime dateOfBirth);
  Future<void> switchToUserForDevelopment(String profileId);
  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository({this.beforeSignOut});

  /// Device-token cleanup supplied by the app, while the current JWT is usable.
  final Future<void> Function()? beforeSignOut;

  static const _appEnvironment = String.fromEnvironment('APP_ENV');
  static const _devOtpPhones = {
    '+97338883670',
    '+97338883671',
    '+97338883672',
    '+97338883673',
    '+97338883674',
    '+97338883675',
    '+97338883676',
    '+97338883677',
    '+97338883678',
  };
  static const _devOtpToken = '000000';

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Session? get currentSession => _client.auth.currentSession;

  @override
  User? get currentUser => _client.auth.currentUser;

  @override
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  @override
  Future<void> sendPhoneOtp(String phone) {
    if (_isLocalEnvironment ||
        (_appEnvironment == 'staging' && _isDevOtpPhone(phone))) {
      return Future.value();
    }
    return _client.auth.signInWithOtp(phone: phone);
  }

  @override
  Future<void> verifyPhoneOtp({required String phone, required String token}) {
    if (_isLocalEnvironment ||
        (_appEnvironment == 'staging' && _isDevOtpPhone(phone))) {
      return _verifyDevOtp(phone: phone, token: token);
    }

    return _client.auth.verifyOTP(
      phone: phone,
      token: token,
      type: OtpType.sms,
    );
  }

  Future<void> _verifyDevOtp({
    required String phone,
    required String token,
  }) async {
    if (token != _devOtpToken) {
      throw const AuthException('Invalid verification code.');
    }

    try {
      final response = await _client.functions.invoke(
        'dev-phone-login',
        body: {'phone': phone, 'token': token},
      );
      final data = response.data;
      if (data is! Map) {
        throw const AuthException('Dev login returned an invalid response.');
      }

      final accessToken = data['access_token'];
      final refreshToken = data['refresh_token'];
      if (accessToken is! String || refreshToken is! String) {
        throw const AuthException('Dev login returned an invalid session.');
      }

      await _client.auth.setSession(refreshToken, accessToken: accessToken);
    } on FunctionException catch (error) {
      final details = error.details;
      final message = details is Map && details['error'] is String
          ? details['error'] as String
          : 'Dev login is not configured yet.';
      throw AuthException(message);
    }
  }

  bool _isDevOtpPhone(String phone) => _devOtpPhones.contains(phone);
  bool get _isLocalEnvironment => _appEnvironment == 'local';

  @override
  Future<void> updateDisplayName(String displayName) async {
    final trimmedName = displayName.trim();
    final user = currentUser;
    if (user == null) {
      throw AuthSessionMissingException();
    }

    await _client.rpc(
      'save_my_onboarding_profile',
      params: {
        'display_name_to_use': trimmedName,
        'date_of_birth_to_use': null,
      },
    );

    await _client.auth.updateUser(
      UserAttributes(data: {'display_name': trimmedName, 'name': trimmedName}),
    );
  }

  @override
  Future<void> updateDateOfBirth(DateTime dateOfBirth) async {
    if (!isEligibleDateOfBirth(dateOfBirth)) {
      throw const AuthException('You must be at least 18 years old to play.');
    }
    final user = currentUser;
    if (user == null) {
      throw AuthSessionMissingException();
    }

    final isoDate = dateOfBirthToIso(dateOfBirth);
    await _client.rpc(
      'save_my_onboarding_profile',
      params: {'display_name_to_use': null, 'date_of_birth_to_use': isoDate},
    );

    await _client.auth.updateUser(
      UserAttributes(data: {'date_of_birth': isoDate}),
    );
  }

  @override
  Future<void> switchToUserForDevelopment(String profileId) async {
    final targetProfileId = profileId.trim();
    if (targetProfileId.isEmpty) {
      throw const AuthException('Choose a user to switch to.');
    }
    if (targetProfileId == currentUser?.id) return;

    try {
      final session = currentSession;
      final response = await _client.functions.invoke(
        'dev-switch-user',
        headers: session == null
            ? null
            : {'Authorization': 'Bearer ${session.accessToken}'},
        body: {'profile_id': targetProfileId},
      );
      final data = response.data;
      if (data is! Map) {
        throw const AuthException(
          'Dev user switch returned an invalid response.',
        );
      }

      final targetAccessToken = data['access_token'];
      final refreshToken = data['refresh_token'];
      if (targetAccessToken is! String || refreshToken is! String) {
        throw const AuthException(
          'Dev user switch returned an invalid session.',
        );
      }

      await _client.auth.setSession(
        refreshToken,
        accessToken: targetAccessToken,
      );
      if (currentUser?.id != targetProfileId) {
        throw const AuthException(
          'The selected dev session could not be opened.',
        );
      }
    } on FunctionException catch (error) {
      final details = error.details;
      final message = details is Map && details['error'] is String
          ? details['error'] as String
          : 'Dev user switching is not configured.';
      throw AuthException(message);
    }
  }

  @override
  Future<void> signOut() async {
    final userId = currentUser?.id;
    if (userId != null) {
      await beforeSignOut?.call();
      if (currentUser?.id != userId) {
        throw const AuthException('The account changed. Please try again.');
      }
    }
    await _client.auth.signOut();
  }
}
