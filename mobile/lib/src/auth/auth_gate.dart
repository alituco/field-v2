import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../home/home_screen.dart';
import 'auth_flow_screen.dart';
import 'auth_repository.dart';
import 'onboarding_status.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.authRepository, this.isDev = false});

  final AuthRepository authRepository;
  final bool isDev;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _authSubscription;
  Session? _session;

  @override
  void initState() {
    super.initState();
    _session = widget.authRepository.currentSession;
    _authSubscription = widget.authRepository.authStateChanges.listen((state) {
      if (!mounted) return;
      setState(() {
        _session = state.session;
      });
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _session?.user;
    final requirement = onboardingRequirementForUser(user);

    if (_session != null && requirement == OnboardingRequirement.complete) {
      return HomeScreen(
        key: ValueKey(_session!.user.id),
        authRepository: widget.authRepository,
        isDev: widget.isDev,
      );
    }

    return AuthFlowScreen(
      authRepository: widget.authRepository,
      initialStep: _initialStep(requirement),
      onOnboardingCompleted: () =>
          setState(() => _session = widget.authRepository.currentSession),
    );
  }

  AuthStep _initialStep(OnboardingRequirement requirement) {
    if (_session == null) return AuthStep.welcome;
    return switch (requirement) {
      OnboardingRequirement.displayName => AuthStep.name,
      OnboardingRequirement.dateOfBirth => AuthStep.dateOfBirth,
      OnboardingRequirement.complete => AuthStep.dateOfBirth,
    };
  }
}
