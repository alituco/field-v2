import 'package:field/src/auth/fieldrush_account_repository.dart';
import 'package:field/src/config/app_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'staging_test_helpers.dart';

/// Only the test entrypoint imports this transport. All account persistence and
/// onboarding still use the real server RPCs; SMS delivery is not under test.
class FieldrushFixtureAuthRepository
    extends SupabaseFieldrushAccountRepository {
  FieldrushFixtureAuthRepository(StagingE2EConfig fixture)
    : _bootstrapPhone = fixture.bootstrapPhone {
    fixture.validate();
    final config = AppConfig.fromEnvironment();
    if (config.environment != AppEnvironment.staging ||
        config.validationError(nativeFlavor: appFlavor) != null) {
      throw TestFailure(
        'Fixture login requires the staging flavor and exact staging backend.',
      );
    }
    if (_bootstrapPhone != '+97339009099' || fixture.devOtpCode != '000000') {
      throw TestFailure(
        'Fixture login must use the isolated staging bootstrap phone and OTP.',
      );
    }
  }

  final String _bootstrapPhone;
  bool _fixtureOtpPending = false;

  bool _canUseFixturePhone(String phone) =>
      phone == _bootstrapPhone &&
      Supabase.instance.client.auth.currentUser == null;

  @override
  Future<void> sendPhoneCode(String phone) async {
    _fixtureOtpPending = _canUseFixturePhone(phone);
    if (_fixtureOtpPending) {
      return;
    }
    await super.sendPhoneCode(phone);
  }

  @override
  Future<void> sendRecoveryCode(String phone) async {
    _fixtureOtpPending = _canUseFixturePhone(phone);
    if (_fixtureOtpPending) {
      return;
    }
    await super.sendRecoveryCode(phone);
  }

  @override
  Future<void> verifyPhoneCode(String phone, String token) async {
    if (_fixtureOtpPending && _canUseFixturePhone(phone)) {
      if (token != '000000') {
        throw const AuthException('Invalid verification code.');
      }
      final client = Supabase.instance.client;
      final response = await client.functions.invoke(
        'dev-phone-login',
        body: {'phone': phone, 'token': token},
      );
      final data = response.data;
      if (data is! Map ||
          data['access_token'] is! String ||
          data['refresh_token'] is! String) {
        throw const AuthException('Fixture login returned an invalid session.');
      }
      await client.auth.setSession(
        data['refresh_token'] as String,
        accessToken: data['access_token'] as String,
      );
      _fixtureOtpPending = false;
      return;
    }
    await super.verifyPhoneCode(phone, token);
  }
}
