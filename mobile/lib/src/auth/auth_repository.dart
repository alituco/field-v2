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
  SupabaseClient get _client => Supabase.instance.client;

  @override
  Session? get currentSession => _client.auth.currentSession;

  @override
  User? get currentUser => _client.auth.currentUser;

  @override
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  @override
  Future<void> sendPhoneOtp(String phone) {
    return _client.auth.signInWithOtp(phone: phone);
  }

  @override
  Future<void> verifyPhoneOtp({required String phone, required String token}) {
    return _client.auth.verifyOTP(
      phone: phone,
      token: token,
      type: OtpType.sms,
    );
  }

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
