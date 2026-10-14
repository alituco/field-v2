import 'package:supabase_flutter/supabase_flutter.dart';

import 'fieldrush_account.dart';

/// Authentication remains owned by Supabase. Profile RPCs never accept a user ID,
/// verification flag or a client-controlled completion flag.
class SupabaseFieldrushAccountRepository implements FieldrushAccountRepository {
  SupabaseFieldrushAccountRepository({
    SupabaseClient? client,
    this.emailDeliveryEnabled = const bool.fromEnvironment(
      'EMAIL_DELIVERY_ENABLED',
    ),
    String? redirectUrl,
  }) : _supabase = client,
       redirectUrl = redirectUrl ?? fieldrushAuthRedirect();

  final SupabaseClient? _supabase;
  SupabaseClient get _client => _supabase ?? Supabase.instance.client;
  final String redirectUrl;
  @override
  final bool emailDeliveryEnabled;
  OtpType? _pendingPhoneType;
  String? _reauthPhone;
  String? _reauthUserId;

  @override
  Future<FieldrushAccount> loadAccount() async {
    final value = await _client.rpc('get_my_fieldrush_account');
    return FieldrushAccount.fromJson(_object(value));
  }

  @override
  Future<void> saveDraft(AccountDraft draft) async {
    await _client.rpc(
      'save_fieldrush_onboarding_draft',
      params: {'draft': draft.toJson()},
    );
  }

  @override
  Future<FieldrushAccount> completeOnboarding(AccountDraft draft) async {
    final value = await _client.rpc(
      'complete_fieldrush_onboarding',
      params: {
        'draft': draft.toJson(),
        'terms_version': fieldrushTermsVersion,
        'privacy_version': fieldrushPrivacyVersion,
      },
    );
    return FieldrushAccount.fromJson(_object(value));
  }

  @override
  Future<UsernameAvailability> checkUsername(String username) async {
    final value = _object(
      await _client.rpc(
        'check_fieldrush_username',
        params: {'candidate': username.trim().toLowerCase()},
      ),
    );
    return UsernameAvailability(
      available: value['available'] == true,
      message: value['message'] as String? ?? '',
    );
  }

  @override
  Future<void> signInWithGoogle() async {
    final launched = await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: redirectUrl,
      authScreenLaunchMode: LaunchMode.externalApplication,
      queryParams: {'prompt': 'select_account'},
    );
    if (!launched) {
      throw const AuthException('Could not open Google. Please try again.');
    }
  }

  @override
  Future<void> linkGoogle() async {
    if (_client.auth.currentUser == null) throw AuthSessionMissingException();
    final launched = await _client.auth.linkIdentity(
      OAuthProvider.google,
      redirectTo: redirectUrl,
      authScreenLaunchMode: LaunchMode.externalApplication,
      queryParams: {'prompt': 'select_account'},
    );
    if (!launched) {
      throw const AuthException(
        'Could not open Google. Your account has not changed.',
      );
    }
  }

  @override
  Future<void> sendPhoneCode(String phone) async {
    _requirePhone(phone);
    // Adding a phone to a Google account must update that authenticated account,
    // not sign into a second phone account and accidentally discard the identity.
    if (_client.auth.currentUser != null) {
      await _client.auth.updateUser(UserAttributes(phone: phone));
      _pendingPhoneType = OtpType.phoneChange;
    } else {
      await _client.auth.signInWithOtp(phone: phone, shouldCreateUser: true);
      _pendingPhoneType = OtpType.sms;
    }
  }

  @override
  Future<void> sendRecoveryCode(String phone) async {
    _requirePhone(phone);
    if (_client.auth.currentUser != null) {
      throw const AuthException('Sign out before recovering another account.');
    }
    await _client.auth.signInWithOtp(phone: phone, shouldCreateUser: false);
    _pendingPhoneType = OtpType.sms;
  }

  @override
  Future<void> verifyPhoneCode(String phone, String token) async {
    _requirePhone(phone);
    _requireCode(token);
    final before = _client.auth.currentUser?.id;
    final type =
        _pendingPhoneType ??
        (before == null ? OtpType.sms : OtpType.phoneChange);
    final response = await _client.auth.verifyOTP(
      phone: phone,
      token: token,
      type: type,
    );
    if (type == OtpType.phoneChange && before != response.user?.id) {
      await _client.auth.signOut(scope: SignOutScope.local);
      throw const AuthException(
        'The account changed unexpectedly. Please sign in again.',
      );
    }
    _pendingPhoneType = null;
  }

  @override
  Future<void> sendReauthenticationCode() async {
    final user = (await _client.auth.getUser()).user;
    final phone = user?.phone;
    if (user == null ||
        phone == null ||
        phone.isEmpty ||
        user.phoneConfirmedAt == null) {
      throw const AuthException(
        'Verify your phone number before changing account security.',
      );
    }
    _reauthUserId = user.id;
    _reauthPhone = phone.startsWith('+') ? phone : '+$phone';
    await _client.auth.signInWithOtp(
      phone: _reauthPhone,
      shouldCreateUser: false,
    );
  }

  @override
  Future<void> verifyReauthenticationCode(String token) async {
    _requireCode(token);
    final phone = _reauthPhone;
    final id = _reauthUserId;
    if (phone == null || id == null || _client.auth.currentUser?.id != id) {
      throw const AuthException('Request a new confirmation code.');
    }
    final result = await _client.auth.verifyOTP(
      phone: phone,
      token: token,
      type: OtpType.sms,
    );
    if (result.user?.id != id) {
      await _client.auth.signOut(scope: SignOutScope.local);
      throw const AuthException(
        'Could not confirm this account. Please sign in again.',
      );
    }
    _reauthPhone = null;
    _reauthUserId = null;
  }

  @override
  Future<void> requestEmailVerification(String email) async {
    if (!emailDeliveryEnabled) {
      throw const AuthException(
        'Email verification is not available yet. Use your verified phone or linked Google account to sign in.',
      );
    }
    if (!isFieldrushEmail(email)) {
      throw const AuthException('Enter a valid email address.');
    }
    final account = await loadAccount();
    final draft = account.draft.copyWith(email: email.trim());
    if (account.completed) {
      await updateAccount(draft);
    } else {
      await saveDraft(draft);
    }
    await _client.auth.updateUser(
      UserAttributes(email: email.trim()),
      emailRedirectTo: redirectUrl,
    );
  }

  @override
  Future<void> verifyEmailCode(String email, String token) async {
    if (!emailDeliveryEnabled) {
      throw const AuthException('Email verification is not available yet.');
    }
    _requireCode(token);
    final before = _client.auth.currentUser?.id;
    if (before == null) throw AuthSessionMissingException();
    final result = await _client.auth.verifyOTP(
      email: email.trim(),
      token: token,
      type: OtpType.emailChange,
    );
    if (result.user?.id != before) {
      await _client.auth.signOut(scope: SignOutScope.local);
      throw const AuthException(
        'The account changed unexpectedly. Please sign in again.',
      );
    }
  }

  @override
  Future<FieldrushAccount> updateAccount(AccountDraft draft) async {
    final value = await _client.rpc(
      'update_my_fieldrush_account',
      params: {'draft': draft.toJson()},
    );
    return FieldrushAccount.fromJson(_object(value));
  }

  @override
  Future<void> markTourCompleted() async {
    await _client.rpc('complete_fieldrush_tour');
  }

  @override
  Future<void> deleteAccount() async {
    try {
      final result = await _client.functions.invoke(
        'fieldrush-delete-account',
        body: {'confirmation': 'DELETE'},
      );
      if (result.status != 200 ||
          result.data is! Map ||
          result.data['deleted'] != true) {
        throw const AuthException(
          'Account deletion could not be completed. Please try again or contact support.',
        );
      }
      await _client.auth.signOut(scope: SignOutScope.local);
    } on FunctionException catch (error) {
      final details = error.details;
      throw AuthException(
        details is Map && details['error'] is String
            ? details['error'] as String
            : 'Account deletion could not be completed. Please try again.',
      );
    }
  }

  static Map<String, dynamic> _object(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const FormatException(
      'The account service returned an invalid response.',
    );
  }

  static void _requirePhone(String phone) {
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone)) {
      throw const AuthException(
        'Enter a valid phone number including its country code.',
      );
    }
  }

  static void _requireCode(String token) {
    if (!RegExp(r'^\d{6}$').hasMatch(token)) {
      throw const AuthException('Enter the six-digit code.');
    }
  }
}

String fieldrushAuthRedirect({String? environment}) {
  final env = environment ?? const String.fromEnvironment('APP_ENV');
  return env == 'production'
      ? 'com.alialtaraif.field://auth-callback/'
      : 'com.alialtaraif.field.staging://auth-callback/';
}
