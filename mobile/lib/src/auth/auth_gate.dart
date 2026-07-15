import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../home/home_screen.dart';
import 'auth_flow_screen.dart';
import 'auth_repository.dart';
import 'date_of_birth.dart';

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
    if (_session != null &&
        _hasCompletedOnboarding(widget.authRepository.currentUser)) {
      return HomeScreen(
        key: ValueKey(_session!.user.id),
        authRepository: widget.authRepository,
        isDev: widget.isDev,
      );
    }

    return AuthFlowScreen(
      authRepository: widget.authRepository,
      initialStep: _initialStep(widget.authRepository.currentUser),
      onOnboardingCompleted: () =>
          setState(() => _session = widget.authRepository.currentSession),
    );
  }

  AuthStep _initialStep(User? user) {
    if (_session == null) return AuthStep.welcome;
    if (!_hasDisplayName(user)) return AuthStep.name;
    return AuthStep.dateOfBirth;
  }

  bool _hasCompletedOnboarding(User? user) {
    if (!_hasDisplayName(user)) return false;
    final dateOfBirth = parseDateOfBirth(user?.userMetadata?['date_of_birth']);
    return dateOfBirth != null && isEligibleDateOfBirth(dateOfBirth);
  }

  bool _hasDisplayName(User? user) {
    final metadata = user?.userMetadata;
    final displayName = metadata?['display_name'] ?? metadata?['name'];
    return displayName is String && displayName.trim().isNotEmpty;
  }
}
