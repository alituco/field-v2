import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../home/home_screen.dart';
import 'auth_repository.dart';
import 'sign_in_screen.dart';
import 'verify_otp_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.authRepository});

  final AuthRepository authRepository;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _authSubscription;
  Session? _session;
  String? _pendingPhone;

  @override
  void initState() {
    super.initState();
    _session = widget.authRepository.currentSession;
    _authSubscription = widget.authRepository.authStateChanges.listen((state) {
      if (!mounted) return;
      setState(() {
        _session = state.session;
        if (state.session != null) {
          _pendingPhone = null;
        }
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
    if (_session != null) {
      return HomeScreen(authRepository: widget.authRepository);
    }

    final pendingPhone = _pendingPhone;
    if (pendingPhone != null) {
      return VerifyOtpScreen(
        authRepository: widget.authRepository,
        phone: pendingPhone,
        onBack: () => setState(() => _pendingPhone = null),
      );
    }

    return SignInScreen(
      authRepository: widget.authRepository,
      onOtpSent: (phone) => setState(() => _pendingPhone = phone),
    );
  }
}
