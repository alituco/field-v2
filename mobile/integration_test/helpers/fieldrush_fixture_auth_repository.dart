import 'package:field/src/auth/auth_repository.dart';
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
    if (!RegExp(r'^\+9733888367[0-8]$').hasMatch(_bootstrapPhone) ||
        fixture.devOtpCode != '000000') {
      throw TestFailure(
        'Fixture login must use an existing staging-only test phone and OTP.',
      );
    }
  }

  final String _bootstrapPhone;
  final _fixtureAuth = SupabaseAuthRepository();
  bool _fixtureOtpPending = false;

  bool _canUseFixturePhone(String phone) =>
      phone == _bootstrapPhone &&
      Supabase.instance.client.auth.currentUser == null;

  @override
  Future<void> sendPhoneCode(String phone) async {
    _fixtureOtpPending = _canUseFixturePhone(phone);
    if (_fixtureOtpPending) {
      await _fixtureAuth.sendPhoneOtp(phone);
      return;
    }
    await super.sendPhoneCode(phone);
  }

  @override
  Future<void> sendRecoveryCode(String phone) async {
    _fixtureOtpPending = _canUseFixturePhone(phone);
    if (_fixtureOtpPending) {
      await _fixtureAuth.sendPhoneOtp(phone);
      return;
    }
    await super.sendRecoveryCode(phone);
  }

  @override
  Future<void> verifyPhoneCode(String phone, String token) async {
    if (_fixtureOtpPending && _canUseFixturePhone(phone)) {
      await _fixtureAuth.verifyPhoneOtp(phone: phone, token: token);
      _fixtureOtpPending = false;
      return;
    }
    await super.verifyPhoneCode(phone, token);
  }
}
