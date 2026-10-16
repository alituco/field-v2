import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
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
    http.Client? emailVerificationHttpClient,
    this.beforeSignOut,
  }) : _supabase = client,
       _emailVerificationHttpClient = emailVerificationHttpClient,
       redirectUrl = redirectUrl ?? fieldrushAuthRedirect();

  final SupabaseClient? _supabase;
  final http.Client? _emailVerificationHttpClient;
  SupabaseClient get _client => _supabase ?? Supabase.instance.client;
  final String redirectUrl;
  final Future<void> Function()? beforeSignOut;
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
  Future<void> switchIncompletePhoneAccount(String phone) async {
    _requirePhone(phone);
    final session = _requireEmailSession();
    final user =
        (await _client.auth
                .getUser(session.accessToken)
                .timeout(const Duration(seconds: 30)))
            .user;
    if (user == null) {
      throw const AuthException('Could not confirm your account. Try again.');
    }
    await _requireEmailResponseUser(session.user.id, user.id);
    final account = await loadAccount();
    _requireSameEmailUser(session.user.id);
    final identities = user.identities;
    final currentPhone = user.phone == null
        ? ''
        : '+${user.phone!.replaceAll('+', '')}';
    if (account.completed ||
        account.status != 'onboarding' ||
        account.deletionPending ||
        account.googleLinked ||
        !account.phoneVerified ||
        !_hasConfirmedPhoneIdentity(user) ||
        identities == null ||
        identities.any((identity) => identity.provider != 'phone') ||
        phone == currentPhone ||
        account.phone != currentPhone) {
      throw const AuthException(
        'Could not switch this signup. Refresh your account, or sign out before using another number.',
      );
    }
    // Local scope revokes only this device's session. The previous account,
    // saved signup details, bookings, wallet and other devices remain intact.
    await beforeSignOut?.call();
    _requireSameEmailUser(session.user.id);
    await _client.auth
        .signOut(scope: SignOutScope.local)
        .timeout(const Duration(seconds: 30));
    if (_client.auth.currentSession != null ||
        _client.auth.currentUser != null) {
      throw const AuthException(
        'Sign out could not be confirmed. No code was requested. Try again.',
      );
    }
    _pendingPhoneType = null;
    _reauthPhone = null;
    _reauthUserId = null;
    await _client.auth
        .signInWithOtp(phone: phone, shouldCreateUser: true)
        .timeout(const Duration(seconds: 30));
    if (_client.auth.currentSession != null ||
        _client.auth.currentUser != null) {
      throw const AuthException(
        'The account changed. Start again before entering a verification code.',
      );
    }
    _pendingPhoneType = OtpType.sms;
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
    final normalizedEmail = _requireEmail(email);
    final session = _requireEmailSession();
    final account = await loadAccount();
    _requireSameEmailUser(session.user.id);
    if (account.googleLinked &&
        account.draft.email.trim().toLowerCase() != normalizedEmail) {
      // Email verification must not provide a back door around the explicit
      // Google-disconnection warning, including during incomplete onboarding.
      throw const GoogleEmailChangeConfirmationRequiredException();
    }
    if (account.emailVerified &&
        account.draft.email.toLowerCase() == normalizedEmail) {
      throw const AuthException(
        'This email is already verified. Refresh your account details.',
      );
    }
    // Resends must not rewrite the player's other account details. If the email
    // changed, copy the latest server draft, not unsaved form/controller values.
    if (account.draft.email.toLowerCase() != normalizedEmail) {
      final draft = account.draft.copyWith(email: normalizedEmail);
      if (account.completed) {
        await updateAccount(draft);
      } else {
        await saveDraft(draft);
      }
      _requireSameEmailUser(session.user.id);
    }
    final response = await _emailAuthRequest(
      session: session,
      method: 'PUT',
      path: 'user',
      query: {'redirect_to': redirectUrl},
      body: {'email': normalizedEmail},
    );
    final user = _emailResponseUser(response);
    await _requireEmailResponseUser(session.user.id, user.id);
    if (user.newEmail?.toLowerCase() != normalizedEmail ||
        !_isTimestamp(user.emailChangeSentAt)) {
      throw const FormatException(
        'The email service did not confirm a pending verification request.',
      );
    }
  }

  @override
  Future<void> verifyEmailCode(String email, String token) async {
    if (!emailDeliveryEnabled) {
      throw const AuthException('Email verification is not available yet.');
    }
    final normalizedEmail = _requireEmail(email);
    _requireEmailCode(token);
    final session = _requireEmailSession();
    // New requests complete with the new inbox code alone. Retain compatibility
    // with pending requests from the older two-inbox policy: GoTrue Dart 2.21
    // throws for their successful first-of-two acknowledgement. Recognize only
    // that exact wire response, and never present it as verified without the
    // subsequent canonical confirmed-address read.
    final response = await _emailAuthRequest(
      session: session,
      method: 'POST',
      path: 'verify',
      body: {'email': normalizedEmail, 'token': token, 'type': 'email_change'},
    );
    final partial =
        response.length == 2 &&
        response['code'] == '200' &&
        response['msg'] ==
            'Confirmation link accepted. Please proceed to confirm link sent to the other email';
    if (!partial) {
      final value = response['user'];
      if (value is! Map<String, dynamic> ||
          response['access_token'] is! String ||
          (response['access_token'] as String).isEmpty ||
          response['refresh_token'] is! String ||
          (response['refresh_token'] as String).isEmpty ||
          response['token_type'] != 'bearer' ||
          response['expires_in'] is! int ||
          (response['expires_in'] as int) <= 0) {
        throw const FormatException(
          'The email service returned an invalid verification response.',
        );
      }
      final user = _emailResponseUser(value);
      await _requireEmailResponseUser(session.user.id, user.id);
      if (user.email?.toLowerCase() != normalizedEmail ||
          !_isTimestamp(user.emailConfirmedAt)) {
        throw const FormatException(
          'The email service did not confirm the requested address.',
        );
      }
    }
    // Verification is not a second login. Never install the session returned
    // by /verify: retain the existing phone/Google session and check Auth using
    // its original token. The caller still reloads the canonical account RPC.
    final User? user;
    try {
      user =
          (await _client.auth
                  .getUser(session.accessToken)
                  .timeout(const Duration(seconds: 30)))
              .user;
    } on AuthRetryableFetchException {
      _requireSameEmailUser(session.user.id);
      // The code may already be consumed. Tell the caller to retry status,
      // never to submit that code again or claim the email is verified.
      throw const EmailVerificationStatusUnavailableException();
    } on TimeoutException {
      _requireSameEmailUser(session.user.id);
      throw const EmailVerificationStatusUnavailableException();
    }
    _requireSameEmailUser(session.user.id);
    if (user == null) {
      throw const FormatException(
        'The email service returned an invalid account response.',
      );
    }
    await _requireEmailResponseUser(session.user.id, user.id);
    final verified =
        user.email?.toLowerCase() == normalizedEmail &&
        _isTimestamp(user.emailConfirmedAt);
    final pending =
        user.newEmail?.toLowerCase() == normalizedEmail &&
        _isTimestamp(user.emailChangeSentAt);
    if (!verified && !(partial && pending)) {
      throw const FormatException(
        'The email service could not confirm this verification state.',
      );
    }
  }

  Session _requireEmailSession() {
    final session = _client.auth.currentSession;
    if (session == null || session.user.isAnonymous) {
      throw AuthSessionMissingException();
    }
    return session;
  }

  void _requireSameEmailUser(String expectedId) {
    if (_client.auth.currentUser?.id != expectedId) {
      throw const AuthException(
        'The account changed. Request a new email verification code.',
      );
    }
  }

  Future<void> _requireEmailResponseUser(
    String expectedId,
    String responseId,
  ) async {
    _requireSameEmailUser(expectedId);
    if (responseId != expectedId) {
      await _client.auth.signOut(scope: SignOutScope.local);
      throw const AuthException(
        'The account changed unexpectedly. Please sign in again.',
      );
    }
  }

  Future<Map<String, dynamic>> _emailAuthRequest({
    required Session session,
    required String method,
    required String path,
    required Map<String, dynamic> body,
    Map<String, String>? query,
  }) async {
    _requireSameEmailUser(session.user.id);
    final origin = Uri.parse(_client.rest.url);
    final uri = origin.replace(path: '/auth/v1/$path', queryParameters: query);
    final headers = {
      ..._client.auth.headers,
      'Authorization': 'Bearer ${session.accessToken}',
      'Content-Type': 'application/json',
      'X-Supabase-Api-Version': '2024-01-01',
    };
    final transport = _emailVerificationHttpClient;
    final requestBody = jsonEncode(body);
    final http.Response result;
    if (method == 'PUT') {
      result =
          await (transport?.put(uri, headers: headers, body: requestBody) ??
                  http.put(uri, headers: headers, body: requestBody))
              .timeout(const Duration(seconds: 30));
    } else {
      result =
          await (transport?.post(uri, headers: headers, body: requestBody) ??
                  http.post(uri, headers: headers, body: requestBody))
              .timeout(const Duration(seconds: 30));
    }
    _requireSameEmailUser(session.user.id);
    dynamic decoded;
    try {
      decoded = jsonDecode(result.body);
    } on FormatException {
      throw const FormatException(
        'The email service returned an invalid response. Please try again.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'The email service returned an invalid response. Please try again.',
      );
    }
    if (result.statusCode != 200) {
      final code = decoded['code'] is String
          ? decoded['code']
          : decoded['error_code'];
      throw AuthException(
        code == 'otp_expired'
            ? 'That code is invalid or has expired. Request a new code.'
            : result.statusCode == 429
            ? 'Please wait before requesting another verification code.'
            : 'Email verification could not be completed. Please try again.',
        statusCode: result.statusCode.toString(),
        code: code is String ? code : null,
      );
    }
    return decoded;
  }

  static User _emailResponseUser(Map<String, dynamic> value) {
    try {
      final user = User.fromJson(value);
      if (user != null && user.id.isNotEmpty) return user;
    } catch (_) {
      // Provider data is never presented as verified without a valid user.
    }
    throw const FormatException(
      'The email service returned an invalid account response.',
    );
  }

  static bool _isTimestamp(String? value) =>
      value != null && DateTime.tryParse(value) != null;

  static String _requireEmail(String email) {
    if (!isFieldrushEmail(email)) {
      throw const AuthException('Enter a valid email address.');
    }
    return email.trim().toLowerCase();
  }

  static void _requireEmailCode(String token) {
    if (!RegExp(r'^\d{6}$').hasMatch(token)) {
      throw const AuthException('Enter the six-digit email code.');
    }
  }

  @override
  Future<FieldrushAccount> updateAccount(
    AccountDraft draft, {
    bool disconnectGoogle = false,
  }) async {
    final targetEmail = _requireEmail(draft.email);
    final session = _requireEmailSession();
    // The screen may predate an OAuth callback. Ask Auth for current identities
    // before deciding whether an email edit also changes a sign-in method.
    final user =
        (await _client.auth
                .getUser(session.accessToken)
                .timeout(const Duration(seconds: 30)))
            .user;
    if (user == null) {
      throw const AuthException('Could not confirm your account. Try again.');
    }
    await _requireEmailResponseUser(session.user.id, user.id);
    final googleIdentities =
        user.identities
            ?.where((identity) => identity.provider == 'google')
            .toList() ??
        const <UserIdentity>[];
    if (googleIdentities.length > 1) {
      throw const AuthException(
        'Could not confirm your Google sign-in. Refresh your account.',
      );
    }
    final google = googleIdentities.isEmpty ? null : googleIdentities.single;
    final googleEmail = _trustedGoogleEmail(google, user.id);
    var disconnected = false;
    if (google != null && googleEmail != targetEmail) {
      if (googleEmail == null) {
        // Never infer a verified Google address from mutable user_metadata.
        throw const AuthException(
          'Could not confirm your linked Google email. Refresh your account before changing it.',
        );
      }
      if (!disconnectGoogle) {
        throw const GoogleEmailChangeConfirmationRequiredException();
      }
      if (!_hasConfirmedPhoneIdentity(user)) {
        throw const GoogleEmailChangeRequiresPhoneException();
      }
      if (google.identityId.isEmpty || google.userId != user.id) {
        throw const AuthException(
          'Could not confirm your Google sign-in. Refresh your account.',
        );
      }
      _requireSameEmailUser(session.user.id);
      try {
        await _client.auth
            .unlinkIdentity(google)
            .timeout(const Duration(seconds: 30));
      } catch (_) {
        // A server unlink can commit even if its response is lost. Never save
        // the new contact email after an ambiguous request, or tell the player
        // that Google definitely remains linked merely because it timed out.
        var confirmedDisconnected = false;
        try {
          final reconciled =
              (await _client.auth
                      .getUser(session.accessToken)
                      .timeout(const Duration(seconds: 30)))
                  .user;
          if (reconciled != null) {
            await _requireEmailResponseUser(session.user.id, reconciled.id);
            confirmedDisconnected =
                reconciled.identities != null &&
                !reconciled.identities!.any(
                  (identity) => identity.provider == 'google',
                ) &&
                _hasConfirmedPhoneIdentity(reconciled) &&
                reconciled.phone == user.phone;
          }
        } catch (_) {
          // Canonical identity status is still unknown. The dedicated outcome
          // tells the account screen to refresh, not to assume a rollback.
        }
        if (confirmedDisconnected) {
          throw const GoogleDisconnectedEmailUpdateException();
        }
        throw const GoogleEmailChangeStatusUnavailableException();
      }
      try {
        final updated =
            (await _client.auth
                    .getUser(session.accessToken)
                    .timeout(const Duration(seconds: 30)))
                .user;
        if (updated == null) {
          throw const FormatException('Missing updated account.');
        }
        await _requireEmailResponseUser(session.user.id, updated.id);
        if (updated.identities?.any(
                  (identity) => identity.provider == 'google',
                ) ==
                true ||
            !_hasConfirmedPhoneIdentity(updated) ||
            updated.phone != user.phone) {
          throw const AuthException(
            'The sign-in change could not be confirmed.',
          );
        }
      } catch (_) {
        throw const GoogleEmailChangeStatusUnavailableException();
      }
      disconnected = true;
    }
    _requireSameEmailUser(session.user.id);
    try {
      final account = await _updateAccountDraft(draft);
      _requireSameEmailUser(session.user.id);
      return account;
    } catch (_) {
      if (disconnected) {
        throw const GoogleDisconnectedEmailUpdateException();
      }
      rethrow;
    }
  }

  static String? _trustedGoogleEmail(UserIdentity? identity, String userId) {
    if (identity == null ||
        identity.userId != userId ||
        identity.identityData?['email_verified'] != true) {
      return null;
    }
    final email = identity.identityData?['email'];
    return email is String && isFieldrushEmail(email)
        ? email.trim().toLowerCase()
        : null;
  }

  static bool _hasConfirmedPhoneIdentity(User user) =>
      _isTimestamp(user.phoneConfirmedAt) &&
      RegExp(r'^\+?[1-9]\d{7,14}$').hasMatch(user.phone ?? '') &&
      user.identities?.any(
            (identity) =>
                identity.provider == 'phone' &&
                identity.userId == user.id &&
                identity.identityId.isNotEmpty,
          ) ==
          true;

  Future<FieldrushAccount> _updateAccountDraft(AccountDraft draft) async {
    // Self-assessment is an onboarding-only answer, never a profile-edit input.
    // The server must also reject attempts to alter the established seed.
    final profileDraft = draft.toJson()..remove('skill_assessment');
    final value = await _client.rpc(
      'update_my_fieldrush_account',
      params: {'draft': profileDraft},
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
        body: {'confirmation': 'DELETE', 'wallet_forfeiture_confirmed': true},
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
