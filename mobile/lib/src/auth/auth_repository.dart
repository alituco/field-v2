import 'package:supabase_flutter/supabase_flutter.dart';

abstract class AuthRepository {
  Session? get currentSession;
  User? get currentUser;
  Stream<AuthState> get authStateChanges;

  Future<void> sendPhoneOtp(String phone);
  Future<void> verifyPhoneOtp({required String phone, required String token});
  Future<void> updateDisplayName(String displayName);
  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  static const _devOtpPhone = '+97338883670';
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
    if (_isDevOtpPhone(phone)) {
      return Future.value();
    }
    return _client.auth.signInWithOtp(phone: phone);
  }

  @override
  Future<void> verifyPhoneOtp({required String phone, required String token}) {
    if (_isDevOtpPhone(phone)) {
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

  bool _isDevOtpPhone(String phone) => phone == _devOtpPhone;

  @override
  Future<void> updateDisplayName(String displayName) async {
    final trimmedName = displayName.trim();
    final user = currentUser;
    if (user == null) {
      throw AuthSessionMissingException();
    }

    await _client.auth.updateUser(
      UserAttributes(data: {'display_name': trimmedName, 'name': trimmedName}),
    );

    await _client.from('profiles').upsert({
      'id': user.id,
      'phone': user.phone,
      'display_name': trimmedName,
    }, onConflict: 'id');
  }

  @override
  Future<void> signOut() {
    return _client.auth.signOut();
  }
}
