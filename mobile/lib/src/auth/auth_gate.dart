import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../home/home_screen.dart';
import '../moderation/account_restriction_screen.dart';
import '../moderation/moderation.dart';
import '../moderation/moderation_repository.dart';
import '../support/support_repository.dart';
import 'auth_flow_screen.dart';
import 'auth_repository.dart';
import 'onboarding_status.dart';

typedef AuthenticatedAppBuilder =
    Widget Function(BuildContext context, ModerationStatus status);

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authRepository,
    this.moderationRepository,
    this.supportRepository,
    this.authenticatedAppBuilder,
    this.isDev = false,
  });

  final AuthRepository authRepository;
  final ModerationRepository? moderationRepository;
  final SupportRepository? supportRepository;
  final AuthenticatedAppBuilder? authenticatedAppBuilder;
  final bool isDev;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  StreamSubscription<AuthState>? _authSubscription;
  late final ModerationRepository _moderationRepository;
  late final SupportRepository _supportRepository;
  Session? _session;
  ModerationStatus? _moderationStatus;
  bool _isLoadingModerationStatus = false;
  int _moderationRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _moderationRepository =
        widget.moderationRepository ?? SupabaseModerationRepository();
    _supportRepository =
        widget.supportRepository ?? SupabaseSupportRepository();
    _session = widget.authRepository.currentSession;
    if (_session != null) {
      _isLoadingModerationStatus = true;
      unawaited(_loadModerationStatus(_session!));
    }
    _authSubscription = widget.authRepository.authStateChanges.listen((state) {
      _setSession(state.session);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed ||
        _session == null ||
        _isLoadingModerationStatus) {
      return;
    }
    unawaited(_loadModerationStatus(_session!));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _moderationRequestGeneration++;
    _authSubscription?.cancel();
    super.dispose();
  }

  void _setSession(Session? nextSession) {
    if (!mounted) return;
    final previousUserId = _session?.user.id;
    final nextUserId = nextSession?.user.id;
    final userChanged = previousUserId != nextUserId;
    final shouldLoad =
        nextSession != null &&
        (userChanged ||
            (_moderationStatus == null && !_isLoadingModerationStatus));

    setState(() {
      _session = nextSession;
      if (userChanged) {
        _moderationRequestGeneration++;
        _moderationStatus = null;
        _isLoadingModerationStatus = nextSession != null;
      }
    });

    if (shouldLoad) {
      unawaited(_loadModerationStatus(nextSession));
    }
  }

  Future<void> _loadModerationStatus(Session session) async {
    final requestGeneration = ++_moderationRequestGeneration;
    final previousStatus = _moderationStatus;
    if (mounted && !_isLoadingModerationStatus) {
      setState(() => _isLoadingModerationStatus = true);
    }

    try {
      final status = await _moderationRepository.getMyModerationStatus();
      if (!_isCurrentModerationRequest(requestGeneration, session.user.id)) {
        return;
      }
      setState(() {
        _moderationStatus = status;
        _isLoadingModerationStatus = false;
      });
    } catch (_) {
      if (!_isCurrentModerationRequest(requestGeneration, session.user.id)) {
        return;
      }
      setState(() {
        _moderationStatus = previousStatus ?? const ModerationStatus.active();
        _isLoadingModerationStatus = false;
      });
    }
  }

  bool _isCurrentModerationRequest(int generation, String userId) {
    return mounted &&
        generation == _moderationRequestGeneration &&
        _session?.user.id == userId;
  }

  @override
  Widget build(BuildContext context) {
    final user = _session?.user;
    final requirement = onboardingRequirementForUser(user);

    if (_session != null && _moderationStatus == null) {
      return const ModerationStatusLoadingScreen();
    }

    final moderationStatus = _moderationStatus;
    if (_session != null && moderationStatus?.blocksAccount == true) {
      return RestrictedAccountScreen(
        status: moderationStatus!,
        supportRepository: _supportRepository,
        onSignOut: widget.authRepository.signOut,
      );
    }

    if (_session != null &&
        moderationStatus != null &&
        requirement == OnboardingRequirement.complete) {
      final authenticatedAppBuilder = widget.authenticatedAppBuilder;
      if (authenticatedAppBuilder != null) {
        return authenticatedAppBuilder(context, moderationStatus);
      }
      return HomeScreen(
        key: ValueKey(_session!.user.id),
        authRepository: widget.authRepository,
        supportRepository: _supportRepository,
        moderationStatus: moderationStatus,
        isDev: widget.isDev,
      );
    }

    return AuthFlowScreen(
      authRepository: widget.authRepository,
      initialStep: _initialStep(requirement),
      onOnboardingCompleted: () =>
          _setSession(widget.authRepository.currentSession),
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
