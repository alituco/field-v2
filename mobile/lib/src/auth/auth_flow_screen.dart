import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/user_facing_error.dart';
import 'auth_repository.dart';
import 'date_of_birth.dart';
import 'onboarding_status.dart';
import '../ui/fieldrush_toast.dart';

enum AuthStep { welcome, phone, otp, name, dateOfBirth }

const _steps = AuthStep.values;

class _PhoneCountry {
  const _PhoneCountry({
    required this.name,
    required this.flag,
    required this.dialCode,
    required this.maxDigits,
    required this.placeholder,
  });

  final String name;
  final String flag;
  final String dialCode;
  final int maxDigits;
  final String placeholder;
}

const _phoneCountries = [
  _PhoneCountry(
    name: 'United States',
    flag: '🇺🇸',
    dialCode: '+1',
    maxDigits: 10,
    placeholder: '(555) 123-4567',
  ),
  _PhoneCountry(
    name: 'Bahrain',
    flag: '🇧🇭',
    dialCode: '+973',
    maxDigits: 8,
    placeholder: '3333 3333',
  ),
];

class AuthFlowScreen extends StatefulWidget {
  const AuthFlowScreen({
    super.key,
    required this.authRepository,
    required this.initialStep,
    required this.onOnboardingCompleted,
  });

  final AuthRepository authRepository;
  final AuthStep initialStep;
  final VoidCallback onOnboardingCompleted;

  @override
  State<AuthFlowScreen> createState() => _AuthFlowScreenState();
}

class _AuthFlowScreenState extends State<AuthFlowScreen>
    with TickerProviderStateMixin {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneFocusNode = FocusNode();
  final _otpFocusNode = FocusNode();
  final _nameFocusNode = FocusNode();

  late final AnimationController _ringController;
  late final AnimationController _glowAController;
  late final AnimationController _glowBController;
  late final AnimationController _verifyingController;

  late AuthStep _step;
  int _direction = 1;
  String? _phoneForVerification;
  _PhoneCountry _selectedCountry = _phoneCountries.first;
  bool _isSendingCode = false;
  bool _isVerifying = false;
  bool _isResending = false;
  bool _isSavingName = false;
  bool _isSavingDateOfBirth = false;
  DateTime? _dateOfBirth;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _glowAController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
    _glowBController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    )..repeat();
    _verifyingController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _focusForStep(_step);
  }

  @override
  void didUpdateWidget(covariant AuthFlowScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialStep != oldWidget.initialStep &&
        widget.initialStep != _step) {
      _go(widget.initialStep);
    }
  }

  @override
  void dispose() {
    _ringController.dispose();
    _glowAController.dispose();
    _glowBController.dispose();
    _verifyingController.dispose();
    _phoneController.dispose();
    _otpController.dispose();
    _nameController.dispose();
    _phoneFocusNode.dispose();
    _otpFocusNode.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  void _go(AuthStep next) {
    setState(() {
      _direction = _steps.indexOf(next) > _steps.indexOf(_step) ? 1 : -1;
      _step = next;
      _errorText = null;
    });
    _focusForStep(next);
  }

  void _back() {
    switch (_step) {
      case AuthStep.welcome:
        break;
      case AuthStep.phone:
        _go(AuthStep.welcome);
      case AuthStep.otp:
        _go(AuthStep.phone);
      case AuthStep.name:
        _go(AuthStep.otp);
      case AuthStep.dateOfBirth:
        _go(AuthStep.name);
    }
  }

  void _focusForStep(AuthStep step) {
    final focusNode = switch (step) {
      AuthStep.phone => _phoneFocusNode,
      AuthStep.otp => _otpFocusNode,
      AuthStep.name => _nameFocusNode,
      AuthStep.dateOfBirth => null,
      AuthStep.welcome => null,
    };
    if (focusNode == null) return;
    Future<void>.delayed(const Duration(milliseconds: 320), () {
      if (mounted && focusNode.canRequestFocus) {
        focusNode.requestFocus();
      }
    });
  }

  Future<void> _sendCode() async {
    final phone = _normalizedPhone;
    if (phone == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _isSendingCode = true;
      _errorText = null;
    });

    try {
      await widget.authRepository.sendPhoneOtp(phone);
      if (!mounted) return;
      _phoneForVerification = phone;
      _go(AuthStep.otp);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not send the code. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSendingCode = false);
      }
    }
  }

  Future<void> _verifyCode() async {
    final phone = _phoneForVerification;
    final token = _otpController.text.trim();
    if (phone == null || !RegExp(r'^\d{6}$').hasMatch(token)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _isVerifying = true;
      _errorText = null;
    });

    try {
      await widget.authRepository.verifyPhoneOtp(phone: phone, token: token);
      if (!mounted) return;
      final requirement = onboardingRequirementForUser(
        widget.authRepository.currentSession?.user ??
            widget.authRepository.currentUser,
      );
      switch (requirement) {
        case OnboardingRequirement.displayName:
          _go(AuthStep.name);
          return;
        case OnboardingRequirement.dateOfBirth:
          _go(AuthStep.dateOfBirth);
          return;
        case OnboardingRequirement.complete:
          widget.onOnboardingCompleted();
          return;
      }
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not verify the code. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isVerifying = false);
      }
    }
  }

  Future<void> _resendCode() async {
    final phone = _phoneForVerification;
    if (phone == null) return;
    setState(() {
      _isResending = true;
      _errorText = null;
    });

    try {
      await widget.authRepository.sendPhoneOtp(phone);
      if (!mounted) return;
      showFieldrushToast(context, 'Code sent again.');
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not resend the code. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isResending = false);
      }
    }
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.length < 2) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _isSavingName = true;
      _errorText = null;
    });

    try {
      await widget.authRepository.updateDisplayName(name);
      if (!mounted) return;
      _go(AuthStep.dateOfBirth);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not save your name. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSavingName = false);
      }
    }
  }

  Future<void> _chooseDateOfBirth() async {
    FocusScope.of(context).unfocus();
    final today = DateTime.now();
    final lastDate = latestEligibleDateOfBirth(today: today);
    final initialDate =
        _dateOfBirth ??
        DateTime(lastDate.year - 2, lastDate.month, lastDate.day);
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(today.year - 100, 1, 1),
      lastDate: lastDate,
      helpText: 'SELECT DATE OF BIRTH',
      fieldLabelText: 'Date of birth',
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      builder: (context, child) {
        final theme = Theme.of(context);
        return Theme(
          data: theme.copyWith(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF10B981),
            ),
          ),
          child: child!,
        );
      },
    );
    if (selected == null || !mounted) return;
    setState(() {
      _dateOfBirth = selected;
      _errorText = null;
    });
  }

  Future<void> _saveDateOfBirth() async {
    final dateOfBirth = _dateOfBirth;
    if (dateOfBirth == null || !isEligibleDateOfBirth(dateOfBirth)) {
      setState(() {
        _errorText = 'You must be at least 18 years old to play.';
      });
      return;
    }

    setState(() {
      _isSavingDateOfBirth = true;
      _errorText = null;
    });
    try {
      await widget.authRepository.updateDateOfBirth(dateOfBirth);
      if (!mounted) return;
      widget.onOnboardingCompleted();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not save your date of birth. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSavingDateOfBirth = false);
      }
    }
  }

  String? get _normalizedPhone {
    final digits = _phoneDigits;
    if (digits.length != _selectedCountry.maxDigits) return null;
    return '${_selectedCountry.dialCode}$digits';
  }

  String get _phoneDigits =>
      _phoneController.text.replaceAll(RegExp(r'\D'), '');

  bool get _phoneIsValid => _phoneDigits.length == _selectedCountry.maxDigits;

  bool get _nameIsValid => _nameController.text.trim().length >= 2;

  bool get _dateOfBirthIsValid =>
      _dateOfBirth != null && isEligibleDateOfBirth(_dateOfBirth!);

  void _changeCountry(_PhoneCountry country) {
    if (country == _selectedCountry) return;
    final digits = _phoneDigits;
    final clipped = digits.length > country.maxDigits
        ? digits.substring(0, country.maxDigits)
        : digits;
    final formatted = _formatPhoneForCountry(country, clipped);
    setState(() {
      _selectedCountry = country;
      _errorText = null;
      _phoneController.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    });
    _phoneFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF022C22),
                  Color(0xFF064E3B),
                  Color(0xFF172554),
                ],
              ),
            ),
          ),
          _PitchBackdrop(
            glowAController: _glowAController,
            glowBController: _glowBController,
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 34,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _TopBar(step: _step, onBack: _back),
                        const SizedBox(height: 30),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 420),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) {
                              final slide = Tween<Offset>(
                                begin: Offset(_direction * 0.12, 0),
                                end: Offset.zero,
                              ).animate(animation);
                              return FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: slide,
                                  child: child,
                                ),
                              );
                            },
                            child: KeyedSubtree(
                              key: ValueKey(_step),
                              child: _buildStep(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep() {
    return switch (_step) {
      AuthStep.welcome => _WelcomeStep(
        ringController: _ringController,
        onStart: () => _go(AuthStep.phone),
      ),
      AuthStep.phone => _StepShell(
        icon: Icons.phone_iphone_rounded,
        title: "What's your number?",
        subtitle: "We'll send you a quick code to verify. No spam, ever.",
        errorText: _errorText,
        child: _PhoneStepBody(
          controller: _phoneController,
          focusNode: _phoneFocusNode,
          country: _selectedCountry,
          countries: _phoneCountries,
          isValid: _phoneIsValid,
          isSubmitting: _isSendingCode,
          onCountryChanged: _changeCountry,
          onChanged: () => setState(() => _errorText = null),
          onSubmit: _sendCode,
        ),
      ),
      AuthStep.otp => _StepShell(
        icon: Icons.shield_outlined,
        title: 'Enter the code',
        subtitleWidget: RichText(
          text: TextSpan(
            style: const TextStyle(
              color: Color(0xB3D1FAE5),
              fontSize: 16,
              height: 1.45,
            ),
            children: [
              const TextSpan(text: 'We sent a 6-digit code to '),
              TextSpan(
                text: _phoneForVerification ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        errorText: _errorText,
        child: _OtpStepBody(
          controller: _otpController,
          focusNode: _otpFocusNode,
          isVerifying: _isVerifying,
          isResending: _isResending,
          verifyingController: _verifyingController,
          onChanged: () {
            setState(() => _errorText = null);
            if (_otpController.text.length == 6 && !_isVerifying) {
              _verifyCode();
            }
          },
          onResend: _resendCode,
        ),
      ),
      AuthStep.name => _StepShell(
        icon: Icons.auto_awesome_rounded,
        title: 'What should we call you?',
        subtitle: 'This is how your clan and rivals will see you.',
        errorText: _errorText,
        child: _NameStepBody(
          controller: _nameController,
          focusNode: _nameFocusNode,
          isValid: _nameIsValid,
          isSaving: _isSavingName,
          onChanged: () => setState(() => _errorText = null),
          onSubmit: _saveName,
        ),
      ),
      AuthStep.dateOfBirth => _StepShell(
        icon: Icons.cake_outlined,
        title: 'When were you born?',
        subtitle: 'Your age helps us keep matches safe and age-appropriate.',
        errorText: _errorText,
        child: _DateOfBirthStepBody(
          dateOfBirth: _dateOfBirth,
          isValid: _dateOfBirthIsValid,
          isSaving: _isSavingDateOfBirth,
          onChoose: _chooseDateOfBirth,
          onSubmit: _saveDateOfBirth,
        ),
      ),
    };
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.step, required this.onBack});

  final AuthStep step;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: step == AuthStep.welcome
                ? const SizedBox(key: ValueKey('spacer'), width: 40, height: 40)
                : _BackButton(key: const ValueKey('back'), onPressed: onBack),
          ),
          _StepDots(step: step),
          const SizedBox(width: 40, height: 40),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedScale(
        scale: 1,
        duration: const Duration(milliseconds: 90),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          child: const Icon(
            Icons.arrow_back_rounded,
            color: Colors.white,
            size: 18,
          ),
        ),
      ),
    );
  }
}

class _StepDots extends StatelessWidget {
  const _StepDots({required this.step});

  final AuthStep step;

  @override
  Widget build(BuildContext context) {
    final currentIndex = _steps.indexOf(step);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _steps.length; i++) ...[
          AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            width: i == currentIndex ? 24 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: const Color(
                0xFF6EE7B7,
              ).withValues(alpha: i <= currentIndex ? 1 : 0.3),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          if (i != _steps.length - 1) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep({required this.ringController, required this.onStart});

  final AnimationController ringController;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 40),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 620),
          curve: Curves.easeOutBack,
          builder: (context, value, child) {
            return Opacity(
              opacity: value.clamp(0, 1),
              child: Transform.rotate(
                angle: (-20 + (20 * value)) * math.pi / 180,
                child: Transform.scale(
                  scale: 0.6 + (0.4 * value),
                  child: child,
                ),
              ),
            );
          },
          child: _WelcomeIcon(ringController: ringController),
        ),
        const SizedBox(height: 32),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, 20 * (1 - value)),
              child: child,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Welcome to',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 48,
                  height: 1.05,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [
                    Color(0xFF6EE7B7),
                    Color(0xFFA7F3D0),
                    Color(0xFF93C5FD),
                  ],
                ).createShader(bounds),
                child: const Text(
                  'Field.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 48,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Form your clan. Challenge rivals. Climb from Division 5 to Division 1.',
                style: TextStyle(
                  color: Color(0xCCD1FAE5),
                  fontSize: 18,
                  height: 1.5,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, 20 * (1 - value)),
              child: child,
            ),
          ),
          child: Column(
            children: [
              _PrimaryButton(
                key: const ValueKey('auth-get-started'),
                label: 'Get started',
                onPressed: onStart,
              ),
              const SizedBox(height: 16),
              Text(
                'By continuing you agree to our Terms'.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0x66FFFFFF),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WelcomeIcon extends StatelessWidget {
  const _WelcomeIcon({required this.ringController});

  final AnimationController ringController;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedBuilder(
          animation: ringController,
          builder: (context, child) {
            final phase = math.sin(ringController.value * math.pi);
            return Opacity(
              opacity: 0.7 * (1 - phase),
              child: Transform.scale(
                scale: 1 + (0.25 * phase),
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.30),
                      width: 2,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF34D399), Color(0xFF10B981), Color(0xFF3B82F6)],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF10B981).withValues(alpha: 0.40),
                blurRadius: 34,
                offset: const Offset(0, 20),
              ),
            ],
          ),
          child: const Icon(
            Icons.auto_awesome_rounded,
            color: Colors.white,
            size: 36,
          ),
        ),
      ],
    );
  }
}

class _StepShell extends StatelessWidget {
  const _StepShell({
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    required this.child,
    this.errorText,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Widget child;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        TweenAnimationBuilder<double>(
          key: ValueKey(icon),
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutBack,
          builder: (context, value, child) => Opacity(
            opacity: value.clamp(0, 1),
            child: Transform.scale(scale: 0.7 + (0.3 * value), child: child),
          ),
          child: _StepIcon(icon: icon),
        ),
        const SizedBox(height: 32),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 40,
            height: 1.1,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 12),
        subtitleWidget ??
            Text(
              subtitle ?? '',
              style: const TextStyle(
                color: Color(0xB3D1FAE5),
                fontSize: 16,
                height: 1.45,
                fontWeight: FontWeight.w400,
              ),
            ),
        const SizedBox(height: 32),
        child,
        if (errorText != null) ...[
          const SizedBox(height: 16),
          _InlineError(message: errorText!),
        ],
      ],
    );
  }
}

class _StepIcon extends StatelessWidget {
  const _StepIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF34D399), Color(0xFF3B82F6)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF10B981).withValues(alpha: 0.40),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 28),
    );
  }
}

class _PhoneStepBody extends StatelessWidget {
  const _PhoneStepBody({
    required this.controller,
    required this.focusNode,
    required this.country,
    required this.countries,
    required this.isValid,
    required this.isSubmitting,
    required this.onCountryChanged,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final _PhoneCountry country;
  final List<_PhoneCountry> countries;
  final bool isValid;
  final bool isSubmitting;
  final ValueChanged<_PhoneCountry> onCountryChanged;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GlassField(
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                ),
                child: _CountryPickerButton(
                  country: country,
                  countries: countries,
                  onSelected: onCountryChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const ValueKey('auth-phone-field'),
                  controller: controller,
                  focusNode: focusNode,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (value) {
                    final digits = value.replaceAll(RegExp(r'\D'), '');
                    final clipped = digits.length > country.maxDigits
                        ? digits.substring(0, country.maxDigits)
                        : digits;
                    final formatted = _formatPhoneForCountry(country, clipped);
                    if (controller.text != formatted) {
                      controller.value = TextEditingValue(
                        text: formatted,
                        selection: TextSelection.collapsed(
                          offset: formatted.length,
                        ),
                      );
                    }
                    onChanged();
                  },
                  onSubmitted: (_) {
                    if (isValid && !isSubmitting) onSubmit();
                  },
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                  cursorColor: Color(0xFF6EE7B7),
                  decoration: InputDecoration(
                    filled: false,
                    fillColor: Colors.transparent,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: country.placeholder,
                    hintStyle: const TextStyle(
                      color: Color(0x4DFFFFFF),
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        _PrimaryButton(
          key: const ValueKey('auth-send-code'),
          label: isSubmitting ? 'Sending code' : 'Send code',
          disabled: !isValid || isSubmitting,
          isLoading: isSubmitting,
          onPressed: isValid && !isSubmitting ? onSubmit : null,
        ),
      ],
    );
  }
}

class _CountryPickerButton extends StatelessWidget {
  const _CountryPickerButton({
    required this.country,
    required this.countries,
    required this.onSelected,
  });

  final _PhoneCountry country;
  final List<_PhoneCountry> countries;
  final ValueChanged<_PhoneCountry> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_PhoneCountry>(
      key: const ValueKey('auth-country-picker'),
      initialValue: country,
      tooltip: 'Country code',
      color: const Color(0xFF064E3B),
      elevation: 14,
      offset: const Offset(0, 12),
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        borderRadius: BorderRadius.circular(14),
      ),
      onSelected: onSelected,
      itemBuilder: (context) {
        return [
          for (final option in countries)
            PopupMenuItem<_PhoneCountry>(
              value: option,
              child: SizedBox(
                width: 190,
                child: Row(
                  children: [
                    Text(option.flag, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        option.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      option.dialCode,
                      style: const TextStyle(
                        color: Color(0xFF6EE7B7),
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ];
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(country.flag, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 8),
          Text(
            country.dialCode,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(width: 2),
          const Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Color(0xB3FFFFFF),
            size: 18,
          ),
        ],
      ),
    );
  }
}

class _OtpStepBody extends StatelessWidget {
  const _OtpStepBody({
    required this.controller,
    required this.focusNode,
    required this.isVerifying,
    required this.isResending,
    required this.verifyingController,
    required this.onChanged,
    required this.onResend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isVerifying;
  final bool isResending;
  final AnimationController verifyingController;
  final VoidCallback onChanged;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: focusNode.requestFocus,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  final value = controller.text;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < 6; i++) ...[
                        _OtpSlot(
                          value: i < value.length ? value[i] : '',
                          active: value.length == i && !isVerifying,
                        ),
                        if (i != 5) const SizedBox(width: 8),
                      ],
                    ],
                  );
                },
              ),
              SizedBox(
                width: 328,
                height: 64,
                child: Opacity(
                  opacity: 0.01,
                  child: TextField(
                    key: const ValueKey('auth-otp-field'),
                    controller: controller,
                    focusNode: focusNode,
                    enabled: !isVerifying,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => onChanged(),
                    onSubmitted: (_) => onChanged(),
                    decoration: const InputDecoration(
                      filled: false,
                      fillColor: Colors.transparent,
                      counterText: '',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: isVerifying
              ? _VerifyingLabel(
                  key: const ValueKey('verifying'),
                  controller: verifyingController,
                )
              : TextButton(
                  key: const ValueKey('resend'),
                  onPressed: isResending ? null : onResend,
                  child: Text(
                    isResending ? 'Sending again' : 'Resend code',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.50),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 10),
        Text(
          'Use the latest 6-digit code'.toUpperCase(),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0x4DFFFFFF),
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}

class _OtpSlot extends StatelessWidget {
  const _OtpSlot({required this.value, required this.active});

  final String value;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      width: 48,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: active ? 0.10 : 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active
              ? const Color(0xFF6EE7B7)
              : Colors.white.withValues(alpha: 0.20),
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: const Color(0xFF6EE7B7).withValues(alpha: 0.28),
                  blurRadius: 18,
                ),
              ]
            : null,
      ),
      child: Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 24,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _VerifyingLabel extends StatelessWidget {
  const _VerifyingLabel({super.key, required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final pulse = math.sin(controller.value * math.pi);
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Transform.scale(
              scale: 1 + (0.5 * pulse),
              child: Opacity(
                opacity: 1 - (0.6 * pulse),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF6EE7B7),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'VERIFYING',
              style: TextStyle(
                color: Color(0xFF6EE7B7),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.8,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NameStepBody extends StatelessWidget {
  const _NameStepBody({
    required this.controller,
    required this.focusNode,
    required this.isValid,
    required this.isSaving,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isValid;
  final bool isSaving;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GlassField(
          child: TextField(
            key: const ValueKey('auth-name-field'),
            controller: controller,
            focusNode: focusNode,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.words,
            maxLength: 24,
            onChanged: (_) => onChanged(),
            onSubmitted: (_) {
              if (isValid && !isSaving) onSubmit();
            },
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
            cursorColor: Color(0xFF6EE7B7),
            decoration: const InputDecoration(
              filled: false,
              fillColor: Colors.transparent,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isCollapsed: true,
              contentPadding: EdgeInsets.zero,
              counterText: '',
              hintText: 'Your name',
              hintStyle: TextStyle(
                color: Color(0x4DFFFFFF),
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        _PrimaryButton(
          key: const ValueKey('auth-save-name'),
          label: isSaving ? 'Saving' : 'Enter the pitch',
          disabled: !isValid || isSaving,
          isLoading: isSaving,
          onPressed: isValid && !isSaving ? onSubmit : null,
        ),
      ],
    );
  }
}

class _DateOfBirthStepBody extends StatelessWidget {
  const _DateOfBirthStepBody({
    required this.dateOfBirth,
    required this.isValid,
    required this.isSaving,
    required this.onChoose,
    required this.onSubmit,
  });

  final DateTime? dateOfBirth;
  final bool isValid;
  final bool isSaving;
  final VoidCallback onChoose;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          label: dateOfBirth == null
              ? 'Choose date of birth'
              : 'Date of birth ${formatDateOfBirth(dateOfBirth!)}',
          child: InkWell(
            key: const ValueKey('date-of-birth-selector'),
            onTap: isSaving ? null : onChoose,
            borderRadius: BorderRadius.circular(16),
            child: _GlassField(
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF6EE7B7).withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.calendar_month_rounded,
                      color: Color(0xFF6EE7B7),
                      size: 23,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'DATE OF BIRTH',
                          style: TextStyle(
                            color: Color(0x996EE7B7),
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          dateOfBirth == null
                              ? 'Choose your birthday'
                              : formatDateOfBirth(dateOfBirth!),
                          style: TextStyle(
                            color: dateOfBirth == null
                                ? const Color(0x80FFFFFF)
                                : Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0x99FFFFFF),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              color: Color(0x806EE7B7),
              size: 16,
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'You must be 18 or older. Your full birthday stays private.',
                style: TextStyle(
                  color: Color(0x99FFFFFF),
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 30),
        _PrimaryButton(
          key: const ValueKey('auth-save-date-of-birth'),
          label: isSaving ? 'Saving' : 'Finish setup',
          disabled: !isValid || isSaving,
          isLoading: isSaving,
          onPressed: isValid && !isSaving ? onSubmit : null,
        ),
      ],
    );
  }
}

class _GlassField extends StatelessWidget {
  const _GlassField({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: child,
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  const _PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.disabled = false,
    this.isLoading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool disabled;
  final bool isLoading;

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.disabled || widget.onPressed == null;
    return GestureDetector(
      onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
      onTapCancel: disabled ? null : () => setState(() => _pressed = false),
      onTapUp: disabled
          ? null
          : (_) {
              setState(() => _pressed = false);
              widget.onPressed?.call();
            },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: Container(
          width: double.infinity,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: disabled
                ? null
                : const LinearGradient(
                    colors: [
                      Color(0xFF34D399),
                      Color(0xFF34D399),
                      Color(0xFF60A5FA),
                    ],
                  ),
            color: disabled ? Colors.white.withValues(alpha: 0.10) : null,
            borderRadius: BorderRadius.circular(16),
            boxShadow: disabled
                ? null
                : [
                    BoxShadow(
                      color: const Color(0xFF10B981).withValues(alpha: 0.40),
                      blurRadius: 26,
                      offset: const Offset(0, 13),
                    ),
                  ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.isLoading ? 'PLEASE WAIT…' : widget.label.toUpperCase(),
                style: TextStyle(
                  color: disabled
                      ? Colors.white.withValues(alpha: 0.30)
                      : const Color(0xFF022C22),
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                ),
              ),
              if (!disabled && !widget.isLoading) ...[
                const SizedBox(width: 8),
                const Icon(
                  Icons.arrow_forward_rounded,
                  color: Color(0xFF022C22),
                  size: 18,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFFCA5A5).withValues(alpha: 0.22),
        ),
      ),
      child: Text(
        message,
        style: const TextStyle(
          color: Color(0xFFFECACA),
          fontSize: 13,
          height: 1.35,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PitchBackdrop extends StatelessWidget {
  const _PitchBackdrop({
    required this.glowAController,
    required this.glowBController,
  });

  final AnimationController glowAController;
  final AnimationController glowBController;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: glowAController,
          builder: (context, _) {
            final value =
                (math.sin(glowAController.value * math.pi * 2) + 1) / 2;
            return Positioned(
              top: -128,
              right: -96,
              child: Transform.scale(
                scale: 1 + (0.15 * value),
                child: _BlurGlow(
                  size: 320,
                  color: const Color(
                    0xFF34D399,
                  ).withValues(alpha: 0.30 + (0.12 * value)),
                ),
              ),
            );
          },
        ),
        AnimatedBuilder(
          animation: glowBController,
          builder: (context, _) {
            final value =
                (math.sin((glowBController.value * math.pi * 2) + 1) + 1) / 2;
            return Positioned(
              bottom: -128,
              left: -96,
              child: Transform.scale(
                scale: 1 + (0.10 * value),
                child: _BlurGlow(
                  size: 384,
                  color: const Color(
                    0xFF3B82F6,
                  ).withValues(alpha: 0.30 + (0.10 * value)),
                ),
              ),
            );
          },
        ),
        Center(
          child: FractionallySizedBox(
            widthFactor: 1.4,
            child: AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
        ),
        Center(
          child: Container(
            height: 1,
            color: Colors.white.withValues(alpha: 0.06),
          ),
        ),
      ],
    );
  }
}

class _BlurGlow extends StatelessWidget {
  const _BlurGlow({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color, blurRadius: 90, spreadRadius: 42)],
      ),
    );
  }
}

String _formatPhoneForCountry(_PhoneCountry country, String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  final clipped = digits.length > country.maxDigits
      ? digits.substring(0, country.maxDigits)
      : digits;

  if (country.dialCode == '+973') {
    if (clipped.length <= 4) return clipped;
    return '${clipped.substring(0, 4)} ${clipped.substring(4)}';
  }

  return _formatUsPhone(clipped);
}

String _formatUsPhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.length <= 3) return digits;
  if (digits.length <= 6) {
    return '(${digits.substring(0, 3)}) ${digits.substring(3)}';
  }
  return '(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6)}';
}
