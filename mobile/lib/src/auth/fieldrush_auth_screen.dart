import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/user_facing_error.dart';
import '../legal/fieldrush_policy_links.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import 'auth_repository.dart';
import 'date_of_birth.dart';
import 'fieldrush_account.dart';
import 'fieldrush_auth_theme.dart';
import 'fieldrush_phone_field.dart';
import 'fieldrush_recovery_screen.dart';
import 'fieldrush_skill_assessment_step.dart';
import 'fieldrush_welcome_painter.dart';

enum _Step {
  welcome,
  phone,
  code,
  name,
  username,
  birthday,
  email,
  skillAssessment,
  review,
}

class FieldrushAuthScreen extends StatefulWidget {
  const FieldrushAuthScreen({
    super.key,
    required this.authRepository,
    required this.accountRepository,
    required this.onOnboardingCompleted,
    this.account,
    this.onPhoneAccountSwitching,
  });

  final AuthRepository authRepository;
  final FieldrushAccountRepository accountRepository;
  final VoidCallback onOnboardingCompleted;
  final FieldrushAccount? account;
  final ValueChanged<bool>? onPhoneAccountSwitching;

  @override
  State<FieldrushAuthScreen> createState() => _FieldrushAuthScreenState();
}

class _FieldrushAuthScreenState extends State<FieldrushAuthScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _username = TextEditingController();
  final _month = TextEditingController();
  final _day = TextEditingController();
  final _year = TextEditingController();
  final _email = TextEditingController();
  final _scroll = ScrollController();

  FieldrushAccount? _account;
  _Step _step = _Step.welcome;
  IsoCode _country = IsoCode.US;
  String? _pendingPhone;
  String? _error;
  String? _notice;
  bool _busy = false;
  bool _login = false;
  bool _editingReview = false;
  bool _awaitingAccount = false;
  bool _openingApp = false;
  bool _switchConfirmationOpen = false;
  AccountDraft? _beforeEdit;
  SkillAssessment? _skillAssessment;
  Timer? _cooldownTimer;
  DateTime? _resendAt;
  int _secondsLeft = 0;
  Timer? _usernameDebounce;
  int _usernameRequest = 0;
  bool _checkingUsername = false;
  UsernameAvailability? _usernameAvailability;
  List<String> _suggestions = [];

  @override
  void initState() {
    super.initState();
    if (widget.account != null) _applyAccount(widget.account!);
    _username.addListener(_scheduleUsernameCheck);
  }

  @override
  void didUpdateWidget(covariant FieldrushAuthScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The gate supplies OAuth callback state. Do not reset an in-flight OTP or
    // discard draft edits for unrelated token-refresh events.
    if (!_busy && _account == null && widget.account != null) {
      _applyAccount(widget.account!);
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _usernameDebounce?.cancel();
    for (final controller in [
      _phone,
      _code,
      _firstName,
      _lastName,
      _username,
      _month,
      _day,
      _year,
      _email,
    ]) {
      controller.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _fillDraft(AccountDraft draft) {
    _firstName.text = draft.firstName;
    _lastName.text = draft.lastName;
    _username.text = draft.username;
    _email.text = draft.email;
    _skillAssessment = draft.skillAssessment;
    _month.text = draft.dateOfBirth?.month.toString().padLeft(2, '0') ?? '';
    _day.text = draft.dateOfBirth?.day.toString().padLeft(2, '0') ?? '';
    _year.text = draft.dateOfBirth?.year.toString() ?? '';
  }

  void _applyAccount(FieldrushAccount account) {
    _account = account;
    _openingApp = account.completed && account.phoneVerified;
    if (_openingApp) return;
    // OTP proves ownership before deciding whether to resume signup. Both
    // welcome actions use the same phone flow; only new/incomplete accounts
    // need the signup details and review.
    _login = false;
    _fillDraft(account.draft);
    if (account.phone.isNotEmpty) {
      try {
        final parsed = PhoneNumber.parse(account.phone);
        _country = parsed.isoCode;
        _phone.text = parsed.nsn;
      } catch (_) {
        _phone.text = account.phone;
      }
    }
    if (!account.phoneVerified) {
      _step = _Step.phone;
    } else if (account.draft.firstName.isEmpty ||
        account.draft.lastName.isEmpty) {
      _step = _Step.name;
    } else if (account.draft.username.isEmpty) {
      _step = _Step.username;
    } else if (account.draft.dateOfBirth == null) {
      _step = _Step.birthday;
    } else if (account.draft.email.isEmpty) {
      _step = _Step.email;
    } else if (account.skillAssessmentRequired &&
        account.draft.skillAssessment == null) {
      _step = _Step.skillAssessment;
    } else {
      _step = _Step.review;
    }
  }

  DateTime? get _birthday {
    final year = int.tryParse(_year.text);
    final month = int.tryParse(_month.text);
    final day = int.tryParse(_day.text);
    if (year == null || month == null || day == null || year < 1900) {
      return null;
    }
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }

  AccountDraft get _draft => AccountDraft(
    firstName: _firstName.text.trim(),
    lastName: _lastName.text.trim(),
    username: _username.text.trim().toLowerCase(),
    dateOfBirth: _birthday,
    email: _email.text.trim(),
    skillAssessment: _skillAssessment,
  );

  bool get _needsSkillAssessment => _account?.skillAssessmentRequired == true;

  int get _setupStepCount => _needsSkillAssessment ? 8 : 7;

  int get _setupStepNumber =>
      _step == _Step.review ? _setupStepCount : _step.index;

  void _go(_Step step) {
    FocusScope.of(context).unfocus();
    setState(() {
      _step = step;
      _error = null;
      _notice = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (step == _Step.username) _scheduleUsernameCheck();
  }

  void _back() {
    if (_busy || _openingApp) return;
    if (_editingReview) {
      if (_beforeEdit != null) _fillDraft(_beforeEdit!);
      _editingReview = false;
      _beforeEdit = null;
      _go(_Step.review);
      return;
    }
    _go(switch (_step) {
      _Step.welcome || _Step.phone => _Step.welcome,
      _Step.code => _Step.phone,
      _Step.name => _Step.phone,
      _Step.username => _Step.name,
      _Step.birthday => _Step.username,
      _Step.email => _Step.birthday,
      _Step.skillAssessment => _Step.email,
      _Step.review =>
        _needsSkillAssessment ? _Step.skillAssessment : _Step.email,
    });
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
      if (!mounted) return;
      final code = error is AuthException ? error.code : null;
      if (code == 'phone_exists' || code == 'identity_already_exists') {
        setState(() {
          _error =
              'This number already belongs to an account. Sign in with '
              'that phone number, then connect Google in Account settings.';
        });
      } else {
        setState(() => _error = userFacingError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startCooldown() {
    _resendAt = DateTime.now().add(const Duration(seconds: 60));
    _secondsLeft = 60;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      final remaining = _resendAt!.difference(DateTime.now()).inSeconds;
      setState(() => _secondsLeft = math.max(0, remaining));
      if (_secondsLeft == 0) timer.cancel();
    });
  }

  Future<void> _sendCode({bool resend = false}) async {
    if (_busy || _switchConfirmationOpen) return;
    final phone = resend
        ? _pendingPhone
        : normalizeFieldrushPhone(_phone.text, country: _country);
    if (phone == null) {
      setState(() => _error = 'Enter a valid phone number and country code.');
      return;
    }
    // OTP can succeed before its account read does. Do not let a failed read
    // turn the next number into a phone-change request on that signed-in user.
    if (_account == null && widget.authRepository.currentUser != null) {
      final enteredPhone = _phone.text;
      final enteredCountry = _country;
      await _run(_loadSignedInAccount);
      if (!mounted || _account == null || _openingApp) return;
      _phone.text = enteredPhone;
      _country = enteredCountry;
      _go(_Step.phone);
    }
    if (_account?.phoneVerified == true && phone == _account?.phone) {
      _go(_editingReview ? _Step.review : _Step.name);
      _editingReview = false;
      return;
    }
    if (_account?.phoneVerified == true &&
        _account?.completed == false &&
        _account?.googleLinked == false &&
        phone != _account?.phone) {
      await _switchPhoneAccount(phone);
      return;
    }
    if (_secondsLeft > 0 && phone == _pendingPhone) {
      _go(_Step.code);
      return;
    }
    await _run(() async {
      await widget.accountRepository.sendPhoneCode(phone);
      if (!mounted) return;
      _pendingPhone = phone;
      _code.clear();
      _startCooldown();
      _go(_Step.code);
      if (resend) setState(() => _notice = 'A new code has been sent.');
    });
  }

  Future<void> _switchPhoneAccount(String phone) async {
    _switchConfirmationOpen = true;
    final bool? confirmed;
    try {
      confirmed = await showFieldrushModal<bool>(
        context: context,
        builder: (context) => FieldrushModal(
          title: 'Use a different account?',
          description:
              'You’ll sign out of this unfinished signup before we send a code '
              'to $phone. Your existing account won’t be deleted.',
          actions: [
            FilledButton(
              key: const Key('fieldrush-confirm-phone-account-switch'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Sign out and continue'),
            ),
            OutlinedButton(
              key: const Key('fieldrush-cancel-phone-account-switch'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep this account'),
            ),
          ],
        ),
      );
    } finally {
      _switchConfirmationOpen = false;
    }
    if (!mounted || confirmed != true) return;
    await _run(() async {
      widget.onPhoneAccountSwitching?.call(true);
      try {
        await widget.accountRepository.switchIncompletePhoneAccount(phone);
        if (!mounted) return;
        if (widget.authRepository.currentUser != null ||
            widget.authRepository.currentSession != null) {
          throw const AuthException(
            'Sign out could not be confirmed. Start again before entering a code.',
          );
        }
        _clearPreviousSignup();
        _pendingPhone = phone;
        _startCooldown();
        _go(_Step.code);
      } catch (_) {
        if (mounted &&
            widget.authRepository.currentUser == null &&
            widget.authRepository.currentSession == null) {
          // Supabase clears local state before revoking the session. A failed
          // sign-out/send must not leave the old account's signup draft shown.
          _clearPreviousSignup();
          _go(_Step.phone);
        }
        rethrow;
      } finally {
        widget.onPhoneAccountSwitching?.call(false);
      }
    });
  }

  void _clearPreviousSignup() {
    _account = null;
    _pendingPhone = null;
    _code.clear();
    _cooldownTimer?.cancel();
    _resendAt = null;
    _secondsLeft = 0;
    _awaitingAccount = false;
    _editingReview = false;
    _beforeEdit = null;
    _login = true;
    _openingApp = false;
    _fillDraft(const AccountDraft());
  }

  Future<void> _loadSignedInAccount() async {
    final expectedId = widget.authRepository.currentUser?.id;
    final account = await widget.accountRepository.loadAccount();
    if (!mounted) return;
    if (expectedId != null &&
        widget.authRepository.currentUser?.id != expectedId) {
      throw const AuthException('The account changed. Please start again.');
    }
    final editing = _editingReview;
    final draft = _draft;
    setState(() {
      _awaitingAccount = false;
      _applyAccount(account);
      if (editing) {
        _fillDraft(draft);
        _step = _Step.review;
        _editingReview = false;
      }
    });
    if (account.completed && account.phoneVerified) {
      widget.onOnboardingCompleted();
    }
  }

  Future<void> _verifyCode() async {
    if (!RegExp(r'^\d{6}$').hasMatch(_code.text)) {
      setState(
        () => _error = 'Enter the six-digit code from your text message.',
      );
      return;
    }
    await _run(() async {
      if (!_awaitingAccount) {
        await widget.accountRepository.verifyPhoneCode(
          _pendingPhone!,
          _code.text,
        );
        if (!mounted) return;
        FocusScope.of(context).unfocus();
        setState(() => _awaitingAccount = true);
      }
      await _loadSignedInAccount();
    });
  }

  Future<void> _google() => _run(() async {
    await widget.accountRepository.signInWithGoogle();
    if (mounted) {
      setState(() {
        _notice =
            'Continue in Google, then return here. '
            'If you closed the browser, you can try again.';
      });
    }
  });

  void _scheduleUsernameCheck() {
    _usernameDebounce?.cancel();
    final request = ++_usernameRequest;
    if (_step != _Step.username) return;
    final value = _username.text.trim().toLowerCase();
    setState(() {
      _usernameAvailability = null;
      _checkingUsername = false;
      _suggestions = [];
    });
    if (validateFieldrushUsername(value) != null) return;
    _usernameDebounce = Timer(const Duration(milliseconds: 450), () async {
      if (!mounted) return;
      setState(() => _checkingUsername = true);
      try {
        final result = await widget.accountRepository.checkUsername(value);
        if (!mounted || request != _usernameRequest) return;
        setState(() => _usernameAvailability = result);
        if (!result.available) await _loadSuggestions(request);
      } catch (_) {
        if (mounted && request == _usernameRequest) {
          setState(
            () => _usernameAvailability = const UsernameAvailability(
              available: false,
              message: 'Could not check availability. Continue to try again.',
            ),
          );
        }
      } finally {
        if (mounted && request == _usernameRequest) {
          setState(() => _checkingUsername = false);
        }
      }
    });
  }

  Future<void> _loadSuggestions(int request) async {
    final first = _firstName.text.toLowerCase().replaceAll(
      RegExp('[^a-z0-9]'),
      '',
    );
    final last = _lastName.text.toLowerCase().replaceAll(
      RegExp('[^a-z0-9]'),
      '',
    );
    if (first.isEmpty) return;
    final candidates = <String>{
      '$first.$last',
      '${first}plays',
      '$first.$last${DateTime.now().year % 100}',
    }.where((value) => validateFieldrushUsername(value) == null);
    final available = <String>[];
    for (final candidate in candidates) {
      final result = await widget.accountRepository.checkUsername(candidate);
      if (!mounted || request != _usernameRequest) return;
      if (result.available) available.add(candidate);
    }
    if (mounted && request == _usernameRequest) {
      setState(() => _suggestions = available);
    }
  }

  Future<void> _saveStep() async {
    String? error;
    switch (_step) {
      case _Step.name:
        error =
            validateFieldrushName(_firstName.text) ??
            validateFieldrushName(_lastName.text);
        if (error != null) {
          error = 'Enter a first and last name, up to 50 characters each.';
        }
      case _Step.username:
        error = validateFieldrushUsername(_username.text.trim().toLowerCase());
      case _Step.birthday:
        final birthday = _birthday;
        final now = DateTime.now();
        if (birthday == null || birthday.isAfter(now)) {
          error = 'Enter a real birthday using month, day and four-digit year.';
        } else if (!isEligibleDateOfBirth(birthday)) {
          error = 'You must be 18 or older to join Fieldrush.';
        }
      case _Step.email:
        if (!isFieldrushEmail(_email.text)) {
          error = 'Enter a valid email address.';
        }
      case _Step.skillAssessment:
        if (_skillAssessment == null) {
          error = 'Choose your current level, or select Not sure.';
        }
      default:
        return;
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final currentStep = _step;
    await _run(() async {
      if (currentStep == _Step.username) {
        final availability = await widget.accountRepository.checkUsername(
          _draft.username,
        );
        if (!availability.available) {
          throw StateError(
            availability.message.isEmpty
                ? 'That username is not available. Choose another.'
                : availability.message,
          );
        }
      }
      await widget.accountRepository.saveDraft(_draft);
      if (!mounted) return;
      final next = _editingReview
          ? _Step.review
          : switch (currentStep) {
              _Step.name => _Step.username,
              _Step.username => _Step.birthday,
              _Step.birthday => _Step.email,
              _Step.email =>
                _needsSkillAssessment ? _Step.skillAssessment : _Step.review,
              _Step.skillAssessment => _Step.review,
              _ => _Step.review,
            };
      _editingReview = false;
      _beforeEdit = null;
      _go(next);
    });
  }

  Future<void> _complete() async {
    if (_needsSkillAssessment && _skillAssessment == null) {
      _go(_Step.skillAssessment);
      return;
    }
    await _run(() async {
      final account = await widget.accountRepository.completeOnboarding(_draft);
      if (!mounted) return;
      if (!account.completed || !account.phoneVerified) {
        throw StateError('Your account is not complete yet. Please try again.');
      }
      setState(() => _applyAccount(account));
      widget.onOnboardingCompleted();
    });
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Builder(
      builder: (context) => PopScope(
        canPop: _step == _Step.welcome && !_openingApp,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _back();
        },
        child: Scaffold(
          backgroundColor: FieldrushAuthTheme.cream,
          // Verification is complete, but the account read and the gate's
          // access checks may still be pending. Keep the same quiet handoff
          // until we know whether to enter the app or resume signup. The code
          // screen's recovery message belongs only to a failed account read.
          body: _openingApp || (_awaitingAccount && _busy)
              ? const SafeArea(
                  key: Key('fieldrush-signing-in'),
                  child: FieldLoadingContent(label: 'Signing you in'),
                )
              : _step == _Step.welcome
              ? _welcome(context)
              : _step == _Step.skillAssessment
              ? FieldrushSkillAssessmentStep(
                  selected: _skillAssessment,
                  onSelected: (value) => setState(() {
                    _skillAssessment = value;
                    _error = null;
                  }),
                  onBack: _back,
                  onSkip: () {
                    setState(() => _skillAssessment = SkillAssessment.notSure);
                    unawaited(_saveStep());
                  },
                  onContinue: _saveStep,
                  stepNumber: _setupStepNumber,
                  stepCount: _setupStepCount,
                  busy: _busy,
                  error: _error,
                  notice: _notice,
                  controller: _scroll,
                )
              : _flow(context),
        ),
      ),
    ),
  );

  Widget _welcome(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const ExcludeSemantics(
        child: CustomPaint(painter: FieldrushWelcomePainter()),
      ),
      SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: math.min(
                          constraints.maxWidth / 372 * 390,
                          constraints.maxHeight * 0.52,
                        ),
                      ),
                      const Text(
                        'Fieldrush',
                        style: TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 50,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Every game counts.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 40),
                      const Spacer(),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: FieldrushSignupPolicyNotice(
                          light: true,
                          textKey: Key('fieldrush-welcome-agreement'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        key: const Key('fieldrush-create-account'),
                        onPressed: () {
                          _login = false;
                          _go(_account == null ? _Step.phone : _Step.name);
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFF3EBD6),
                          foregroundColor: const Color(0xFF14201A),
                        ),
                        child: const Text('Create account'),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        key: const Key('fieldrush-log-in'),
                        onPressed: () {
                          _login = true;
                          _go(_Step.phone);
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Log in'),
                      ),
                      if (_error != null)
                        _message(_error!, error: true, light: true),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _flow(BuildContext context) => SafeArea(
    child: LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          if (_step.index > 0 && _step.index < _Step.review.index)
            Positioned(
              top: 85,
              right: -18,
              child: ExcludeSemantics(
                child: Text(
                  '${_step.index}',
                  style: const TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 320,
                    height: 0.9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -18,
                    color: FieldrushAuthTheme.watermark,
                  ),
                ),
              ),
            ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                controller: _scroll,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _progress(),
                              const SizedBox(height: 42),
                              Text(
                                _title,
                                style: const TextStyle(
                                  fontFamily: 'Outfit',
                                  fontSize: 44,
                                  height: 0.98,
                                  letterSpacing: -1.76,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                _subtitle,
                                style: const TextStyle(
                                  color: FieldrushAuthTheme.muted,
                                  fontSize: 13,
                                  height: 1.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 28),
                              ..._fields(context),
                              if (_error != null)
                                _message(_error!, error: true),
                              if (_notice != null) _message(_notice!),
                              const SizedBox(height: 28),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: _actions(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  String get _title => switch (_step) {
    _Step.phone => _login ? 'Welcome\nback' : 'What’s your\nnumber?',
    _Step.code => 'Enter the\ncode',
    _Step.name => 'What’s your\nname?',
    _Step.username => 'Pick a\nusername',
    _Step.birthday => 'When’s your\nbirthday?',
    _Step.email => 'And your\nemail?',
    _Step.skillAssessment => 'What’s your\nlevel?',
    _Step.review => 'Look\nright?',
    _Step.welcome => 'Fieldrush',
  };

  String get _subtitle => switch (_step) {
    _Step.phone =>
      _account?.googleLinked == true
          ? 'Google is connected. Verify your number for sign-in and game-day contact.'
          : 'We’ll text you a code. Your number is how you log in.',
    _Step.code => 'Sent to ${_pendingPhone ?? _phone.text}.',
    _Step.name => 'Other players see your first name and last initial.',
    _Step.username => 'It’s how players find and tag you.',
    _Step.birthday =>
      'Only you can see this. Fieldrush is for players 18 and older.',
    _Step.email => 'For receipts and game reminders. You can verify it later.',
    _Step.skillAssessment => 'So your first games are fair.',
    _Step.review => 'Tap Edit to change anything.',
    _Step.welcome => '',
  };

  Widget _progress() => Row(
    children: [
      IconButton.outlined(
        key: const Key('fieldrush-back'),
        tooltip: _editingReview ? 'Back to review' : 'Back',
        onPressed: _busy ? null : _back,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white,
          side: const BorderSide(color: FieldrushAuthTheme.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: const Icon(Icons.chevron_left),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Semantics(
          label: 'Account setup, step $_setupStepNumber of $_setupStepCount',
          child: Row(
            children: List.generate(
              _setupStepCount,
              (index) => Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  height: 4,
                  decoration: BoxDecoration(
                    color: index < _setupStepNumber
                        ? FieldrushAuthTheme.forest
                        : FieldrushAuthTheme.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  List<Widget> _fields(BuildContext context) => switch (_step) {
    _Step.phone => [
      FieldrushPhoneField(
        controller: _phone,
        enabled: !_busy,
        initialCountry: _country,
        onCountryChanged: (country) => _country = country,
      ),
      if (_account?.googleLinked == true) ...[
        const SizedBox(height: 18),
        _message('Google connected · ${_account!.draft.email}'),
        TextButton(
          onPressed: _busy ? null : _signOutForPhone,
          child: const Text(
            'Already have a phone account? Sign in to link Google',
          ),
        ),
      ],
    ],
    _Step.code => [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: _busy
              ? null
              : () {
                  _code.clear();
                  _go(_Step.phone);
                },
          child: const Text('Change number'),
        ),
      ),
      _codeField(),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const Key('fieldrush-resend-code'),
          onPressed: _busy || _secondsLeft > 0 || _awaitingAccount
              ? null
              : () => _sendCode(resend: true),
          child: Text(
            _secondsLeft > 0
                ? 'Resend code in 0:${_secondsLeft.toString().padLeft(2, '0')}'
                : 'Resend code',
          ),
        ),
      ),
      if (_awaitingAccount)
        const Text(
          'Your number was verified. Try again to finish loading your account; '
          'you do not need another code.',
          style: TextStyle(color: FieldrushAuthTheme.muted),
        ),
    ],
    _Step.name => [
      _textField(
        _firstName,
        'FIRST NAME',
        'fieldrush-first-name',
        autofill: AutofillHints.givenName,
        capitalization: TextCapitalization.words,
      ),
      const SizedBox(height: 22),
      _textField(
        _lastName,
        'LAST NAME',
        'fieldrush-last-name',
        autofill: AutofillHints.familyName,
        capitalization: TextCapitalization.words,
      ),
    ],
    _Step.username => [
      _textField(
        _username,
        'USERNAME',
        'fieldrush-username',
        autofill: AutofillHints.newUsername,
        prefix: '@',
      ),
      const SizedBox(height: 12),
      Text(
        _checkingUsername
            ? 'Checking availability…'
            : _usernameAvailability == null
            ? '3–20 letters, numbers, dots or underscores.'
            : _usernameAvailability!.available
            ? 'Available — it’s yours to claim.'
            : _usernameAvailability!.message.isEmpty
            ? 'That username is not available.'
            : _usernameAvailability!.message,
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          color: _usernameAvailability?.available == false
              ? FieldrushAuthTheme.danger
              : FieldrushAuthTheme.muted,
        ),
      ),
      if (_suggestions.isNotEmpty) ...[
        const SizedBox(height: 18),
        const Text(
          'ALSO AVAILABLE',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: FieldrushAuthTheme.muted,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: _suggestions
              .map(
                (value) => ActionChip(
                  label: Text('@$value'),
                  onPressed: _busy ? null : () => _username.text = value,
                  backgroundColor: Colors.white,
                ),
              )
              .toList(),
        ),
      ],
    ],
    _Step.birthday => [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _textField(
              _month,
              'MONTH',
              'fieldrush-month',
              hint: 'MM',
              numeric: true,
              maxLength: 2,
              autofill: AutofillHints.birthdayMonth,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _textField(
              _day,
              'DAY',
              'fieldrush-day',
              hint: 'DD',
              numeric: true,
              maxLength: 2,
              autofill: AutofillHints.birthdayDay,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 2,
            child: _textField(
              _year,
              'YEAR',
              'fieldrush-year',
              hint: 'YYYY',
              numeric: true,
              maxLength: 4,
              autofill: AutofillHints.birthdayYear,
            ),
          ),
        ],
      ),
    ],
    _Step.email => [
      _textField(
        _email,
        'EMAIL',
        'fieldrush-email',
        autofill: AutofillHints.email,
        keyboard: TextInputType.emailAddress,
        fontSize: 22,
      ),
      const SizedBox(height: 16),
      const Text(
        'Until verified, this email cannot be used to recover your account.',
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          color: FieldrushAuthTheme.muted,
        ),
      ),
    ],
    _Step.skillAssessment => [], // Dedicated reference layout above.
    _Step.review => [
      const Divider(color: FieldrushAuthTheme.ink, thickness: 2.5),
      _reviewRow(
        'PHONE',
        _account?.phone ?? _phone.text,
        _Step.phone,
        verified: _account?.phoneVerified == true,
      ),
      _reviewRow(
        'NAME',
        '${_firstName.text.trim()} ${_lastName.text.trim()}',
        _Step.name,
      ),
      _reviewRow('USERNAME', '@${_draft.username}', _Step.username),
      _reviewRow(
        'BIRTHDAY',
        _birthday == null ? 'Not set' : formatDateOfBirth(_birthday!),
        _Step.birthday,
      ),
      _reviewRow(
        'EMAIL',
        _email.text.trim(),
        _Step.email,
        verified:
            _account?.emailVerified == true &&
            _email.text.trim() == _account?.draft.email,
      ),
      if (_needsSkillAssessment)
        _reviewRow(
          'STARTING LEVEL',
          _skillAssessment?.label ?? 'Not set',
          _Step.skillAssessment,
        ),
    ],
    _Step.welcome => [],
  };

  Future<void> _signOutForPhone() => _run(() async {
    await widget.authRepository.signOut();
    if (!mounted) return;
    setState(() {
      _account = null;
      _pendingPhone = null;
      _editingReview = false;
      _login = true;
      _fillDraft(const AccountDraft());
      _step = _Step.phone;
      _notice =
          'Sign in with your existing phone number. Then connect Google '
          'from Account settings.';
    });
  });

  List<Widget> _actions(BuildContext context) => [
    if (_step == _Step.review) ...[
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: FieldrushSignupPolicyNotice(
          creatingAccount: true,
          textKey: Key('fieldrush-review-agreement'),
        ),
      ),
      const SizedBox(height: 12),
    ],
    FilledButton(
      key: const Key('fieldrush-continue'),
      onPressed: _busy
          ? null
          : switch (_step) {
              _Step.phone => _sendCode,
              _Step.code => _verifyCode,
              _Step.review => _complete,
              _ => _saveStep,
            },
      child: _busy
          ? Semantics(liveRegion: true, child: const Text('Please wait…'))
          : Text(switch (_step) {
              _Step.code => _awaitingAccount ? 'Finish signing in' : 'Verify',
              _Step.review => 'Create account',
              _ => _editingReview ? 'Save changes' : 'Continue',
            }),
    ),
    if (_step == _Step.phone && _account == null) ...[
      const SizedBox(height: 12),
      const Row(
        children: [
          Expanded(child: Divider(color: FieldrushAuthTheme.border)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'or',
              style: TextStyle(fontSize: 11, color: FieldrushAuthTheme.muted),
            ),
          ),
          Expanded(child: Divider(color: FieldrushAuthTheme.border)),
        ],
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const Key('fieldrush-google'),
        onPressed: _busy ? null : _google,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 54),
          backgroundColor: Colors.white,
          foregroundColor: FieldrushAuthTheme.ink,
          side: const BorderSide(color: FieldrushAuthTheme.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
        icon: const FieldrushGoogleMark(),
        label: const Text(
          'Continue with Google',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      TextButton(
        onPressed: _busy ? null : _openRecovery,
        child: const Text('Need help signing in?'),
      ),
    ],
  ];

  Widget _textField(
    TextEditingController controller,
    String label,
    String key, {
    String? autofill,
    String? prefix,
    String? hint,
    bool numeric = false,
    int? maxLength,
    double fontSize = 26,
    TextInputType? keyboard,
    TextCapitalization capitalization = TextCapitalization.none,
  }) => TextField(
    key: Key(key),
    controller: controller,
    enabled: !_busy,
    keyboardType: numeric ? TextInputType.number : keyboard,
    textCapitalization: capitalization,
    autocorrect: capitalization != TextCapitalization.none,
    enableSuggestions: capitalization != TextCapitalization.none,
    autofillHints: autofill == null ? null : [autofill],
    inputFormatters: [
      if (numeric) FilteringTextInputFormatter.digitsOnly,
      if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
    ],
    style: TextStyle(
      fontFamily: 'Outfit',
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
    ),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      prefixText: prefix,
    ),
  );

  Widget _codeField() => ValueListenableBuilder<TextEditingValue>(
    valueListenable: _code,
    builder: (context, value, _) => SizedBox(
      height: 64,
      child: Stack(
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              child: Row(
                children: List.generate(
                  6,
                  (index) => Expanded(
                    child: Container(
                      margin: EdgeInsets.only(right: index == 5 ? 0 : 9),
                      padding: const EdgeInsets.only(bottom: 8),
                      alignment: Alignment.bottomCenter,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: index == value.text.length
                                ? FieldrushAuthTheme.forest
                                : index < value.text.length
                                ? FieldrushAuthTheme.ink
                                : FieldrushAuthTheme.border,
                            width: 2.5,
                          ),
                        ),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          index < value.text.length ? value.text[index] : '',
                          style: const TextStyle(
                            fontFamily: 'Outfit',
                            fontSize: 40,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: TextField(
              key: const Key('fieldrush-code'),
              controller: _code,
              enabled: !_busy && !_awaitingAccount,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              showCursor: false,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: const TextStyle(color: Colors.transparent, fontSize: 32),
              decoration: const InputDecoration(
                labelText: 'Six-digit code',
                floatingLabelBehavior: FloatingLabelBehavior.never,
                labelStyle: TextStyle(color: Colors.transparent),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _openRecovery() async {
    final recovered = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => FieldrushRecoveryScreen(
          authRepository: widget.authRepository,
          accountRepository: widget.accountRepository,
        ),
      ),
    );
    if (mounted && recovered == true) await _run(_loadSignedInAccount);
  }

  Widget _reviewRow(
    String label,
    String value,
    _Step step, {
    bool verified = false,
  }) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w800,
                      color: FieldrushAuthTheme.muted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    value,
                    style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            if (verified)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.check_circle,
                  color: FieldrushAuthTheme.forest,
                  size: 18,
                  semanticLabel: 'Verified',
                ),
              ),
            TextButton(
              key: Key('fieldrush-edit-${step.name}'),
              onPressed: _busy
                  ? null
                  : () {
                      _beforeEdit = _draft;
                      _editingReview = true;
                      _go(step);
                    },
              child: Text(
                'Edit',
                semanticsLabel: 'Edit ${label.toLowerCase()}',
              ),
            ),
          ],
        ),
      ),
      const Divider(height: 1, color: FieldrushAuthTheme.border),
    ],
  );

  Widget _message(String text, {bool error = false, bool light = false}) =>
      Semantics(
        liveRegion: true,
        child: Container(
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: light
                ? Colors.black.withValues(alpha: 0.25)
                : error
                ? const Color(0xFFF5E7E1)
                : const Color(0xFFEAF0E3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: light
                  ? Colors.white
                  : error
                  ? FieldrushAuthTheme.danger
                  : FieldrushAuthTheme.ink,
            ),
          ),
        ),
      );
}
