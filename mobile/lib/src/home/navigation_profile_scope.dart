import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_repository.dart';
import '../profile/profile.dart';

/// Shares the signed-in player's existing profile snapshot across routes.
/// This belongs above the app Navigator so pushed screens use the same avatar.
class FieldNavigationProfileScope extends StatefulWidget {
  const FieldNavigationProfileScope({
    super.key,
    required this.child,
    this.authRepository,
  });

  final Widget child;
  final AuthRepository? authRepository;

  static String? avatarUrlOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_NavigationProfileProvider>()
      ?.notifier
      ?.avatarUrl;

  /// Capture before a profile request so an old response cannot undo a photo
  /// change or carry a previous account's avatar into the current session.
  static NavigationProfileRead? beginRead(BuildContext context) => context
      .getInheritedWidgetOfExactType<_NavigationProfileProvider>()
      ?.notifier
      ?.beginRead();

  static void profileChanged(BuildContext context, PlayerProfile profile) {
    context
        .getInheritedWidgetOfExactType<_NavigationProfileProvider>()
        ?.notifier
        ?.profileChanged(profile);
  }

  @override
  State<FieldNavigationProfileScope> createState() =>
      _FieldNavigationProfileScopeState();
}

class _FieldNavigationProfileScopeState
    extends State<FieldNavigationProfileScope> {
  late AuthRepository _auth;
  late final _NavigationProfile _profile;
  StreamSubscription<AuthState>? _subscription;

  @override
  void initState() {
    super.initState();
    _auth = widget.authRepository ?? SupabaseAuthRepository();
    _profile = _NavigationProfile(_auth.currentUser?.id);
    _listen();
  }

  void _listen() {
    _subscription = _auth.authStateChanges.listen((event) {
      _profile.useUser(event.session?.user.id);
    }, onError: (Object _, StackTrace __) {});
  }

  @override
  void didUpdateWidget(covariant FieldNavigationProfileScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authRepository != widget.authRepository) {
      _subscription?.cancel();
      _auth = widget.authRepository ?? SupabaseAuthRepository();
      _profile.useUser(_auth.currentUser?.id);
      _listen();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _profile.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _NavigationProfileProvider(notifier: _profile, child: widget.child);
}

class _NavigationProfileProvider extends InheritedNotifier<_NavigationProfile> {
  const _NavigationProfileProvider({
    required super.notifier,
    required super.child,
  });
}

class NavigationProfileRead {
  const NavigationProfileRead._(this._profile, this._userId, this._revision);

  final _NavigationProfile _profile;
  final String? _userId;
  final int _revision;

  void complete(PlayerProfile profile) {
    if (_profile._disposed ||
        _userId != _profile._userId ||
        _revision != _profile._revision) {
      return;
    }
    _profile.setProfile(profile);
  }
}

class _NavigationProfile extends ChangeNotifier {
  _NavigationProfile(this._userId);

  String? _userId;
  String? avatarUrl;
  int _revision = 0;
  bool _disposed = false;

  NavigationProfileRead beginRead() =>
      NavigationProfileRead._(this, _userId, _revision);

  void useUser(String? userId) {
    if (_disposed || _userId == userId) return;
    _userId = userId;
    _revision++;
    avatarUrl = null;
    notifyListeners();
  }

  void profileChanged(PlayerProfile profile) {
    if (_disposed || profile.id != _userId) return;
    _revision++;
    setProfile(profile);
  }

  void setProfile(PlayerProfile profile) {
    if (_disposed || profile.id != _userId) return;
    final normalized = profile.avatarUrl?.trim();
    final next = normalized?.isNotEmpty == true ? normalized : null;
    if (avatarUrl == next) return;
    avatarUrl = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
