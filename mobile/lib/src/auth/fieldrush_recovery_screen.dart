import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth_repository.dart';
import 'fieldrush_account.dart';
import 'fieldrush_account_screen.dart' show fieldrushAccountError;
import 'fieldrush_auth_theme.dart';
import 'fieldrush_auth_platform.dart';
import 'fieldrush_phone_field.dart';

/// Recovery verifies an existing sign-in method; names and birthdays are never
/// accepted as proof of ownership, and unverified email cannot recover accounts.
class FieldrushRecoveryScreen extends StatefulWidget {
  const FieldrushRecoveryScreen({
    super.key,
    required this.authRepository,
    required this.accountRepository,
  });

  final AuthRepository authRepository;
  final FieldrushAccountRepository accountRepository;

  @override
  State<FieldrushRecoveryScreen> createState() =>
      _FieldrushRecoveryScreenState();
}

class _FieldrushRecoveryScreenState extends State<FieldrushRecoveryScreen>
    with WidgetsBindingObserver {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  IsoCode _country = IsoCode.US;
  String? _sentPhone;
  String? _error;
  String? _notice;
  bool _busy = false;
  bool _waitingForGoogle = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForGoogle) {
      _waitingForGoogle = false;
      if (widget.authRepository.currentUser != null) _run(_finishRecovery);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = fieldrushAccountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishRecovery() async {
    final account = await widget.accountRepository.loadAccount();
    if (!mounted) return;
    if (account.deletionPending) {
      setState(
        () => _error =
            'This account has a pending deletion request. It cannot be recovered here.',
      );
      return;
    }
    if (!account.completed || !account.phoneVerified) {
      setState(
        () => _error =
            'This sign-in method is not connected to a completed account. Use the phone number or Google account you originally used.',
      );
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _submitPhone() async {
    final phone =
        _sentPhone ?? normalizeFieldrushPhone(_phone.text, country: _country);
    if (phone == null) {
      setState(() => _error = 'Enter a valid phone number.');
      return;
    }
    if (_sentPhone != null && !RegExp(r'^\d{6}$').hasMatch(_code.text)) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    await _run(() async {
      if (_sentPhone == null) {
        await widget.accountRepository.sendRecoveryCode(phone);
        if (mounted) {
          setState(() {
            _sentPhone = phone;
            _notice =
                'If this number belongs to an account, a sign-in code will arrive shortly.';
          });
        }
      } else {
        await widget.accountRepository.verifyPhoneCode(phone, _code.text);
        await _finishRecovery();
      }
    });
  }

  Future<void> _google() => _run(() async {
    _waitingForGoogle = true;
    try {
      await widget.accountRepository.signInWithGoogle();
      if (mounted) {
        setState(
          () => _notice =
              'Choose the Google account already linked to your profile.',
        );
      }
    } catch (_) {
      _waitingForGoogle = false;
      rethrow;
    }
  });

  Future<void> _support() => _run(() async {
    if (!await launchUrl(
      Uri.parse('https://field.bh'),
      mode: LaunchMode.externalApplication,
    )) {
      if (mounted) {
        setState(
          () => _error =
              'Could not open the website. Please visit https://field.bh.',
        );
      }
    }
  });

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Builder(
      builder: (context) => Scaffold(
        backgroundColor: FieldrushAuthTheme.cream,
        appBar: AppBar(title: const Text('Get back into your account')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(
                Icons.lock_outline_rounded,
                size: 52,
                color: FieldrushAuthTheme.forest,
              ),
              const SizedBox(height: 24),
              Text(
                'Let’s get you back.',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontFamily: 'Outfit',
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Use the verified phone number on your account. We’ll send you a code—no password needed.',
              ),
              const SizedBox(height: 28),
              FieldrushPhoneField(
                controller: _phone,
                enabled: !_busy && _sentPhone == null,
                onCountryChanged: (country) => _country = country,
              ),
              if (_sentPhone != null) ...[
                const SizedBox(height: 20),
                TextField(
                  key: const Key('fieldrush-recovery-code'),
                  controller: _code,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: const InputDecoration(
                    labelText: 'Verification code',
                  ),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _sentPhone = null;
                          _code.clear();
                          _notice = null;
                        }),
                  child: const Text('Use a different number'),
                ),
              ],
              const SizedBox(height: 20),
              if (_error != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: FieldrushAuthTheme.danger),
                    ),
                  ),
                ),
              if (_notice != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(_notice!),
                  ),
                ),
              FilledButton(
                key: const Key('fieldrush-recovery-submit'),
                onPressed: _busy ? null : _submitPhone,
                child: Text(
                  _busy
                      ? 'Please wait…'
                      : _sentPhone == null
                      ? 'Send sign-in code'
                      : 'Verify & sign in',
                ),
              ),
              if (fieldrushGoogleAuthAvailable) ...[
                const SizedBox(height: 28),
                const Text(
                  'No longer have that number?',
                  style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'You can use a Google account that you previously linked. Using a different Google account will not recover your profile.',
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const Key('fieldrush-recovery-google'),
                  onPressed: _busy ? null : _google,
                  icon: const Icon(Icons.link),
                  label: const Text('Use your linked Google account'),
                ),
                if (_waitingForGoogle)
                  TextButton(
                    onPressed: _busy ? null : () => _run(_finishRecovery),
                    child: const Text('I’ve finished signing in'),
                  ),
              ],
              const SizedBox(height: 28),
              const Text(
                'Still locked out?',
                style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Do not create a second account. Your name, birthday, or an unverified email cannot be used to prove ownership. Visit our website for help.',
              ),
              TextButton(
                onPressed: _busy ? null : _support,
                child: const Text('Open support website'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
