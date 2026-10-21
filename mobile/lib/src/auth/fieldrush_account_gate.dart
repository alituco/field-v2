import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/user_facing_error.dart';
import '../home/home_screen.dart';
import '../moderation/account_restriction_screen.dart';
import '../moderation/moderation.dart';
import '../moderation/moderation_repository.dart';
import '../support/support_repository.dart';
import '../ui/field_loading.dart';
import 'auth_repository.dart';
import 'fieldrush_account.dart';
import 'fieldrush_auth_screen.dart';
import 'fieldrush_auth_theme.dart';
import 'player_identity.dart';
import 'staff_identity_screen.dart';

/// Client-editable user metadata never controls onboarding.
class FieldrushAccountGate extends StatefulWidget {
  const FieldrushAccountGate({
    super.key,
    required this.authRepository,
    required this.accountRepository,
    this.moderationRepository,
    this.supportRepository,
    this.authenticatedAppBuilder,
    this.isDev = false,
    this.profileSwitcherEnabled = false,
  });

  final AuthRepository authRepository;
  final FieldrushAccountRepository accountRepository;
  final ModerationRepository? moderationRepository;
  final SupportRepository? supportRepository;
  final Widget Function(BuildContext, ModerationStatus)?
  authenticatedAppBuilder;
  final bool isDev;
  final bool profileSwitcherEnabled;

  @override
  State<FieldrushAccountGate> createState() => _FieldrushAccountGateState();
}

class _FieldrushAccountGateState extends State<FieldrushAccountGate>
    with WidgetsBindingObserver {
  StreamSubscription<AuthState>? _subscription;
  late final ModerationRepository _moderation;
  late final SupportRepository _support;
  String? _userId;
  FieldrushAccount? _account;
  ModerationStatus? _status;
  String? _error;
  bool _initialLoading = false;
  int _request = 0;
  int _screenGeneration = 0;
  bool _switchingPhoneAccount = false;
  bool _staffIdentityRejected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _moderation = widget.moderationRepository ?? SupabaseModerationRepository();
    _support = widget.supportRepository ?? SupabaseSupportRepository();
    _userId = widget.authRepository.currentUser?.id;
    if (isStaffIdentity(widget.authRepository.currentUser)) {
      _userId = null;
      _staffIdentityRejected = true;
      unawaited(_signOutStaffIdentity());
    } else {
      _initialLoading = _userId != null;
      if (_userId != null) unawaited(_refresh());
    }
    _subscription = widget.authRepository.authStateChanges.listen(
      (event) {
        if (isStaffIdentity(event.session?.user)) {
          _request++;
          setState(() {
            _staffIdentityRejected = true;
            _userId = null;
            _account = null;
            _status = null;
            _error = null;
            _initialLoading = false;
            _screenGeneration++;
          });
          unawaited(_signOutStaffIdentity());
          return;
        }
        final id = event.session?.user.id;
        if (id == null) {
          _request++;
          setState(() {
            _userId = null;
            _account = null;
            _status = null;
            _error = null;
            _initialLoading = false;
            // A deliberate unfinished-signup switch owns its current OTP
            // screen until sign-out and the new SMS request have both ended.
            if (!_switchingPhoneAccount) _screenGeneration++;
          });
          return;
        }
        final changed = id != _userId;
        if (changed) {
          setState(() {
            _staffIdentityRejected = false;
            // Ordinary SMS verification may finish on the signed-out screen.
            // A session arriving DURING an unfinished-signup switch is not
            // that flow: discard the previous user's still-mounted draft.
            if (_userId != null || _switchingPhoneAccount) _screenGeneration++;
            _userId = id;
            _account = null;
            _status = null;
          });
        }
        if (changed ||
            event.event == AuthChangeEvent.userUpdated ||
            event.event == AuthChangeEvent.signedIn) {
          unawaited(_refresh());
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = userFacingError(error));
      },
    );
  }

  Future<void> _signOutStaffIdentity() async {
    try {
      await widget.authRepository.signOut();
    } catch (_) {
      // Keep the staff-only screen mounted if device cleanup needs a retry.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _userId != null) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final id = _userId;
    if (id == null) return;
    final generation = ++_request;
    try {
      final account = await widget.accountRepository.loadAccount();
      final status =
          account.completed && account.phoneVerified && !account.deletionPending
          ? await _moderation.getMyModerationStatus()
          : null;
      if (!mounted || generation != _request || id != _userId) return;
      setState(() {
        _account = account;
        _status = status;
        _error = null;
        _initialLoading = false;
      });
    } catch (error) {
      if (!mounted || generation != _request || id != _userId) return;
      setState(() {
        _error = userFacingError(
          error,
          fallback:
              'We could not load your account. Check your connection and try again.',
        );
        _initialLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _request++;
    _subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_staffIdentityRejected) {
      return StaffIdentityScreen(
        onUsePlayerAccount: () async {
          await _signOutStaffIdentity();
          if (mounted && widget.authRepository.currentUser == null) {
            setState(() {
              _staffIdentityRejected = false;
              _screenGeneration++;
            });
          }
        },
      );
    }
    if (_initialLoading) {
      return const Scaffold(
        backgroundColor: FieldrushAuthTheme.cream,
        body: SafeArea(
          child: FieldLoadingContent(label: 'Loading your account'),
        ),
      );
    }
    if (_error != null || _account?.deletionPending == true) {
      final deleting = _account?.deletionPending == true;
      return Theme(
        data: FieldrushAuthTheme.theme(context),
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      deleting
                          ? 'Account deletion in progress'
                          : 'Could not load your account',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _error ??
                          'Your account is locked while deletion finishes. Completing deletion '
                              'permanently removes wallet access and forfeits any remaining balance. '
                              'Retry to complete it, or contact support.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () async {
                        if (!deleting) {
                          await _refresh();
                          return;
                        }
                        try {
                          await widget.accountRepository.deleteAccount();
                        } catch (error) {
                          if (mounted) {
                            setState(() => _error = userFacingError(error));
                          }
                        }
                      },
                      child: Text(deleting ? 'Retry deletion' : 'Retry'),
                    ),
                    TextButton(
                      onPressed: widget.authRepository.signOut,
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (_status?.blocksAccount == true) {
      return RestrictedAccountScreen(
        status: _status!,
        supportRepository: _support,
        onSignOut: widget.authRepository.signOut,
      );
    }
    final account = _account;
    if (_userId != null &&
        account != null &&
        account.completed &&
        account.phoneVerified &&
        _status != null) {
      // Keep the authenticated subtree tied to a non-null user identity. A
      // nullable ValueKey<String?> does not equal ValueKey<String>, and custom
      // app builders must also be remounted when the active account changes.
      return KeyedSubtree(
        key: ValueKey<String>(_userId!),
        child:
            widget.authenticatedAppBuilder?.call(context, _status!) ??
            HomeScreen(
              authRepository: widget.authRepository,
              accountRepository: widget.accountRepository,
              supportRepository: _support,
              moderationStatus: _status,
              isDev: widget.isDev,
              profileSwitcherEnabled: widget.profileSwitcherEnabled,
            ),
      );
    }
    return FieldrushAuthScreen(
      key: ValueKey(_screenGeneration),
      authRepository: widget.authRepository,
      accountRepository: widget.accountRepository,
      account: account,
      onPhoneAccountSwitching: (switching) {
        if (mounted) setState(() => _switchingPhoneAccount = switching);
      },
      onOnboardingCompleted: () => unawaited(_refresh()),
    );
  }
}
