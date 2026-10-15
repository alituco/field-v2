import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';
import 'date_of_birth.dart';
import 'fieldrush_account.dart';
import 'fieldrush_auth_theme.dart';
import 'fieldrush_phone_field.dart';
import '../profile/profile.dart';
import '../profile/profile_repository.dart';
import '../home/navigation_profile_scope.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import '../markets/fieldrush_city.dart';
import '../markets/fieldrush_city_repository.dart';
import '../profile/fieldrush_city_picker.dart';

class _AccountLoadingView extends StatelessWidget {
  const _AccountLoadingView();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading account details',
    liveRegion: true,
    child: ExcludeSemantics(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
        children: [
          const Row(
            children: [
              FieldSkeleton(width: 36, height: 36, radius: 12),
              SizedBox(width: 12),
              FieldSkeleton(width: 154, height: 20),
            ],
          ),
          const SizedBox(height: 26),
          const Center(child: FieldSkeleton(width: 88, height: 88, radius: 28)),
          const SizedBox(height: 24),
          for (var index = 0; index < 6; index++) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: FieldSkeleton(width: 88, height: 10),
            ),
            const SizedBox(height: 10),
            const FieldSkeleton(height: 32, radius: 10),
            const SizedBox(height: 22),
          ],
        ],
      ),
    ),
  );
}

class FieldrushAccountScreen extends StatefulWidget {
  const FieldrushAccountScreen({
    super.key,
    required this.authRepository,
    required this.accountRepository,
    this.profileRepository,
    this.imagePicker,
    this.cityRepository,
    this.bottomNavigationBar,
    this.bottomNavigationBuilder,
  }) : assert(bottomNavigationBar == null || bottomNavigationBuilder == null);

  final AuthRepository authRepository;
  final FieldrushAccountRepository accountRepository;
  final ProfileRepository? profileRepository;
  final ImagePicker? imagePicker;
  final FieldrushCityRepository? cityRepository;
  final Widget? bottomNavigationBar;
  final Widget Function(Future<bool> Function() confirmLeave)?
  bottomNavigationBuilder;

  @override
  State<FieldrushAccountScreen> createState() => _FieldrushAccountScreenState();
}

class _FieldrushAccountScreenState extends State<FieldrushAccountScreen>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _username = TextEditingController();
  final _birthday = TextEditingController();
  final _email = TextEditingController();
  FieldrushAccount? _account;
  PlayerProfile? _profile;
  String? _editing;
  String? _photoError;
  bool _photoBusy = false;
  bool _securityExpanded = false;
  String? _error;
  String? _notice;
  bool _loading = true;
  bool _busy = false;
  bool _waitingForGoogle = false;
  bool _deletionSubmitted = false;
  bool _emailVerificationOpen = false;
  String? _pendingVerificationEmail;
  StreamSubscription<AuthState>? _authSubscription;
  int _accountLoadGeneration = 0;

  bool get _locked =>
      _deletionSubmitted || (_account?.deletionPending ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authSubscription = widget.authRepository.authStateChanges.listen((state) {
      if (_waitingForGoogle &&
          (state.event == AuthChangeEvent.userUpdated ||
              state.event == AuthChangeEvent.signedIn)) {
        _loadAccount(preserveDraft: true);
      }
    });
    _loadAccount();
    _loadProfile();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    for (final controller in [
      _firstName,
      _lastName,
      _username,
      _birthday,
      _email,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_waitingForGoogle) {
        _loadAccount(preserveDraft: true);
      } else if (_pendingVerificationEmail != null &&
          !_busy &&
          !_emailVerificationOpen) {
        _refreshEmailVerification();
      }
    }
  }

  void _applyAccount(FieldrushAccount account) {
    _account = account;
    _firstName.text = account.draft.firstName;
    _lastName.text = account.draft.lastName;
    _username.text = account.draft.username;
    _birthday.text = account.draft.dateOfBirth == null
        ? ''
        : dateOfBirthToIso(account.draft.dateOfBirth!);
    _email.text = account.draft.email;
  }

  Future<void> _loadAccount({bool preserveDraft = false}) async {
    final generation = ++_accountLoadGeneration;
    try {
      final account = await widget.accountRepository.loadAccount();
      if (!mounted || generation != _accountLoadGeneration) return;
      setState(() {
        if (preserveDraft) {
          _account = account;
          // OAuth may replace the contact email. Keep an in-progress email
          // edit, but do not leave Verify pointing at a stale controller value.
          if (_editing != 'email') _email.text = account.draft.email;
        } else {
          _applyAccount(account);
        }
        _loading = false;
        _error = null;
        if (_waitingForGoogle && account.googleLinked) {
          _waitingForGoogle = false;
          _pendingVerificationEmail = null;
          _notice = account.googleEmail != null
              ? 'Google linked. Your Google email is now your contact email.'
              : 'Google linked.';
        }
      });
    } catch (error) {
      if (!mounted || generation != _accountLoadGeneration) return;
      setState(() {
        _loading = false;
        _error = fieldrushAccountError(error);
      });
    }
  }

  Future<void> _loadProfile() async {
    final repository = widget.profileRepository;
    if (repository == null) return;
    final navigationProfile = FieldNavigationProfileScope.beginRead(context);
    try {
      final profile = await repository.getCurrentProfile();
      if (mounted) {
        navigationProfile?.complete(profile);
        setState(() => _profile = profile);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _photoError = 'Could not load your photo. Try again.');
      }
    }
  }

  Future<void> _updatePhoto({bool reset = false}) async {
    final repository = widget.profileRepository;
    if (repository == null || _photoBusy || _locked) return;
    setState(() {
      _photoBusy = true;
      _photoError = null;
    });
    try {
      var avatarUrl = '';
      if (!reset) {
        final photo = await (widget.imagePicker ?? ImagePicker()).pickImage(
          source: ImageSource.gallery,
          maxWidth: 1200,
          maxHeight: 1200,
          imageQuality: 88,
        );
        if (photo == null) return;
        final extension = photo.name.split('.').last.toLowerCase();
        final contentType =
            photo.mimeType ??
            switch (extension) {
              'png' => 'image/png',
              'webp' => 'image/webp',
              'heic' => 'image/heic',
              'heif' => 'image/heif',
              _ => 'image/jpeg',
            };
        avatarUrl = await repository.uploadCurrentUserAvatar(
          bytes: await photo.readAsBytes(),
          fileExtension: extension,
          contentType: contentType,
        );
      }
      // Avatar updates must not overwrite a bio changed on another screen.
      final latest = await repository.getCurrentProfile();
      await repository.updateCurrentProfile(
        ProfileUpdate(
          displayName: latest.displayName,
          username: latest.username,
          bio: latest.bio,
          avatarUrl: avatarUrl,
        ),
      );
      final updated = await repository.getCurrentProfile();
      if (mounted) {
        FieldNavigationProfileScope.profileChanged(context, updated);
        setState(() {
          _profile = updated;
          _notice = reset ? 'Photo reset.' : 'Photo updated.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _photoError = fieldrushAccountError(error));
      }
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  AccountDraft get _draft => AccountDraft(
    firstName: _firstName.text.trim(),
    lastName: _lastName.text.trim(),
    username: _username.text.trim().toLowerCase(),
    dateOfBirth: parseDateOfBirth(_birthday.text),
    email: _email.text.trim(),
  );

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

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final draft = _draft;
    await _run(() async {
      final emailChanged =
          draft.email.trim().toLowerCase() !=
          _account!.draft.email.trim().toLowerCase();
      final disconnectGoogle = emailChanged && _account!.googleLinked;
      if (disconnectGoogle) {
        if (!_account!.phoneVerified || _account!.phone.isEmpty) {
          throw const GoogleEmailChangeRequiresPhoneException();
        }
        final confirmed = await showFieldrushModal<bool>(
          context: context,
          builder: (context) => FieldrushModal(
            title: 'Disconnect Google?',
            description:
                'Changing your email to ${draft.email} will disconnect your '
                'linked Google account. You can still sign in with your '
                'verified phone number. Verify your new email after saving. '
                'You can link Google again in Sign-in & security.',
            actions: [
              FilledButton(
                key: const Key('fieldrush-confirm-google-email-change'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Change email & disconnect'),
              ),
              OutlinedButton(
                key: const Key('fieldrush-cancel-google-email-change'),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep Google linked'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      final FieldrushAccount updated;
      try {
        updated = await widget.accountRepository.updateAccount(
          draft,
          disconnectGoogle: disconnectGoogle,
        );
      } on GoogleEmailChangeConfirmationRequiredException {
        // Linking can finish on another device while this page is open.
        // Refresh the linked state before asking the player to save again.
        await _loadAccount(preserveDraft: true);
        rethrow;
      } on GoogleDisconnectedEmailUpdateException {
        _pendingVerificationEmail = null;
        await _loadAccount(preserveDraft: true);
        rethrow;
      } on GoogleEmailChangeStatusUnavailableException {
        _pendingVerificationEmail = null;
        await _loadAccount(preserveDraft: true);
        rethrow;
      }
      if (!mounted) return;
      setState(() {
        _applyAccount(updated);
        _editing = null;
        if (emailChanged) _pendingVerificationEmail = null;
        _notice = disconnectGoogle && !updated.googleLinked
            ? widget.accountRepository.emailDeliveryEnabled
                  ? 'Email updated and Google disconnected. Verify your new email.'
                  : 'Email updated and Google disconnected. You can sign in with your phone.'
            : 'Account details saved.';
      });
    });
  }

  Future<void> _linkGoogle() => _run(() async {
    _waitingForGoogle = true;
    try {
      await widget.accountRepository.linkGoogle();
      if (!mounted) return;
      setState(() => _notice = 'Finish linking in Google, then return here.');
    } catch (_) {
      _waitingForGoogle = false;
      rethrow;
    }
  });

  Future<void> _verifyEmail() async {
    if (!widget.accountRepository.emailDeliveryEnabled ||
        _emailVerificationOpen) {
      return;
    }
    if (!isFieldrushEmail(_email.text)) {
      setState(() => _error = 'Enter a valid email address first.');
      return;
    }
    final email = _email.text.trim();
    final FieldrushAccount? snapshot;
    _emailVerificationOpen = true;
    try {
      snapshot = await showFieldrushModal<FieldrushAccount>(
        context: context,
        dismissible: false,
        builder: (context) => _EmailVerificationDialog(
          repository: widget.accountRepository,
          email: email,
          onRequested: () {
            if (mounted) setState(() => _pendingVerificationEmail = email);
          },
        ),
      );
    } finally {
      _emailVerificationOpen = false;
    }
    if (snapshot != null && mounted) {
      _applyEmailVerification(snapshot, email);
    } else if (mounted) {
      // Sending a code can save a changed contact address even if the player
      // closes the sheet before confirming it. Re-read instead of retaining a
      // stale VERIFIED badge for the old address.
      await _loadAccount(preserveDraft: true);
    }
  }

  void _applyEmailVerification(FieldrushAccount snapshot, String email) {
    final verified =
        snapshot.emailVerified &&
        snapshot.draft.email.trim().toLowerCase() == email.toLowerCase();
    setState(() {
      _account = snapshot;
      if (_editing != 'email') _email.text = snapshot.draft.email;
      _error = null;
      _pendingVerificationEmail = verified ? null : email;
      _notice = verified
          ? 'Email verified.'
          : 'Email verification is not complete yet. Use the code sent to your '
                'new email, or request a new code and try again.';
    });
  }

  Future<void> _refreshEmailVerification() => _run(() async {
    final email = _pendingVerificationEmail;
    if (email == null) return;
    final snapshot = await widget.accountRepository.loadAccount();
    if (mounted) _applyEmailVerification(snapshot, email);
  });

  Future<void> _signOut() => _run(() async {
    await widget.authRepository.signOut();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  });

  Future<bool> _reauthenticate(String purpose) async =>
      await showFieldrushModal<bool>(
        context: context,
        dismissible: false,
        builder: (context) => _ReauthenticationDialog(
          repository: widget.accountRepository,
          purpose: purpose,
          phone: _account!.phone,
        ),
      ) ??
      false;

  Future<void> _changePhone() async {
    if (!await _reauthenticate('change your phone number') || !mounted) return;
    final changed = await showFieldrushModal<bool>(
      context: context,
      dismissible: false,
      builder: (context) => _ChangePhoneDialog(
        repository: widget.accountRepository,
        previousPhone: _account!.phone,
      ),
    );
    if (changed == true && mounted) {
      await _loadAccount(preserveDraft: true);
      if (mounted) {
        setState(() => _notice = 'Phone number verified and updated.');
      }
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showFieldrushModal<bool>(
      context: context,
      builder: (context) => FieldrushModal(
        title: 'Delete your account?',
        description:
            'This removes your account and personal profile. Some transaction or '
            'safety records may need to be retained. Active bookings, payments or '
            'other unsettled activity may need to be resolved first. Deleting an '
            'account does not automatically cancel bookings or issue refunds.\n\n'
            'You will permanently lose wallet access and forfeit any remaining '
            'wallet balance. It will not be refunded or carried to a new account.\n\n'
            'You will verify your current phone number before continuing.',
        actions: [
          FilledButton(
            key: const Key('fieldrush-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            style: FieldrushModal.primaryButtonStyle(destructive: true),
            child: const Text('Continue to verification'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!await _reauthenticate('delete your account') || !mounted) return;
    await _run(() async {
      await widget.accountRepository.deleteAccount();
      if (!mounted) return;
      setState(() {
        _deletionSubmitted = true;
        _notice = 'Your account has been deleted.';
      });
      // The repository has confirmed deletion. Clear any remaining local auth
      // wrapper state, then remove settings from above the signed-out gate.
      try {
        await widget.authRepository.signOut();
      } catch (_) {
        if (mounted) {
          setState(
            () => _notice = 'Your account has been deleted. Please sign out.',
          );
        }
      }
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Builder(builder: _buildContent),
  );

  bool get _dirty {
    final account = _account;
    if (_editing == null || account == null) return false;
    final saved = account.draft.toJson();
    final current = _draft.toJson();
    return saved.keys.any((key) => saved[key] != current[key]);
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showFieldrushModal<bool>(
          context: context,
          builder: (context) => FieldrushModal(
            title: 'Discard your changes?',
            description: 'Your unsaved account changes will be lost.',
            actions: [
              FilledButton(
                key: const Key('fieldrush-discard-changes'),
                onPressed: () => Navigator.pop(context, true),
                style: FieldrushModal.primaryButtonStyle(destructive: true),
                child: const Text('Discard changes'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _cancelEdit() {
    setState(() {
      _applyAccount(_account!);
      _editing = null;
      _error = null;
    });
  }

  Future<void> _openEdit(String field) async {
    if (_busy || _locked || _editing == field) return;
    if (!await _confirmDiscard() || !mounted) return;
    setState(() {
      _applyAccount(_account!);
      _editing = field;
      _error = null;
      _notice = null;
    });
  }

  Future<bool> _confirmLeave() async {
    if (_busy || _photoBusy || !await _confirmDiscard() || !mounted) {
      return false;
    }
    if (_dirty) {
      _cancelEdit();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
    }
    return true;
  }

  Future<void> _goBack() async {
    if (await _confirmLeave() && mounted) Navigator.of(context).maybePop();
  }

  Widget _buildContent(BuildContext context) {
    final account = _account;
    final navigation =
        widget.bottomNavigationBuilder?.call(_confirmLeave) ??
        widget.bottomNavigationBar;
    return PopScope(
      canPop: !_dirty && !_busy && !_photoBusy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        backgroundColor: FieldrushAuthTheme.cream,
        extendBody: navigation != null,
        bottomNavigationBar: navigation,
        body: SafeArea(
          child: _loading
              ? const _AccountLoadingView()
              : account == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error ?? 'Could not load your account.'),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _loadAccount,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                )
              : Form(
                  key: _formKey,
                  child: ListView(
                    key: const Key('fieldrush-account-scroll'),
                    padding: EdgeInsets.only(
                      bottom: navigation == null ? 36 : 132,
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 36,
                              height: 36,
                              child: OutlinedButton(
                                onPressed: _goBack,
                                style: OutlinedButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  backgroundColor: Colors.white,
                                  side: const BorderSide(
                                    color: FieldrushAuthTheme.border,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Icon(
                                  Icons.chevron_left_rounded,
                                  size: 23,
                                  semanticLabel: 'Back',
                                  color: Color(0xFF3C4A38),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Account details',
                                style: TextStyle(
                                  fontFamily: 'Outfit',
                                  fontSize: 18,
                                  height: 1,
                                  letterSpacing: -.18,
                                  fontWeight: FontWeight.w800,
                                  color: FieldrushAuthTheme.ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _photoCard(),
                      if (_error != null || _notice != null || _locked)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_error != null)
                                _message(_error!, error: true),
                              if (_notice != null) _message(_notice!),
                              if (_locked && !_deletionSubmitted)
                                _message(
                                  'Deletion is pending. Account changes are disabled.',
                                ),
                            ],
                          ),
                        ),
                      _card(
                        child: Column(
                          children: [
                            _accountRow(
                              field: 'name',
                              label: 'FULL NAME',
                              value:
                                  '${account.draft.firstName} ${account.draft.lastName}'
                                      .trim(),
                              help:
                                  'Shown on ladders as ${_publicName(account.draft)}',
                              first: true,
                            ),
                            _accountRow(
                              field: 'username',
                              label: 'USERNAME',
                              value: '@${account.draft.username}',
                              help: 'Players search for you with this',
                            ),
                            _accountRow(
                              field: 'birthday',
                              label: 'DATE OF BIRTH',
                              value: _birthdayLabel(account.draft.dateOfBirth),
                              help: account.completed
                                  ? 'Only you can see this. Contact support for a correction.'
                                  : 'Only you can see this. You must be 18 or older.',
                              action: account.completed ? 'Info' : 'Edit',
                              onTap: account.completed
                                  ? _showBirthdayHelp
                                  : null,
                            ),
                            _accountRow(
                              field: 'email',
                              label: 'EMAIL',
                              value: account.draft.email,
                              help: account.emailVerified
                                  ? 'Your contact email is verified'
                                  : widget
                                        .accountRepository
                                        .emailDeliveryEnabled
                                  ? 'Confirm this email belongs to you'
                                  : 'Contact email. Sign in with your phone or linked Google account.',
                              verified: account.emailVerified,
                              action:
                                  !account.emailVerified &&
                                      widget
                                          .accountRepository
                                          .emailDeliveryEnabled
                                  ? 'Verify'
                                  : 'Edit',
                              actionKey:
                                  !account.emailVerified &&
                                      widget
                                          .accountRepository
                                          .emailDeliveryEnabled
                                  ? const Key('fieldrush-verify-email')
                                  : null,
                              onAction:
                                  !account.emailVerified &&
                                      widget
                                          .accountRepository
                                          .emailDeliveryEnabled
                                  ? _verifyEmail
                                  : null,
                              secondaryAction:
                                  !account.emailVerified &&
                                      widget
                                          .accountRepository
                                          .emailDeliveryEnabled
                                  ? 'Edit'
                                  : null,
                              secondaryActionKey: const Key(
                                'fieldrush-edit-email-button',
                              ),
                            ),
                            if (_pendingVerificationEmail != null)
                              TextButton(
                                key: const Key(
                                  'fieldrush-refresh-email-verification',
                                ),
                                onPressed: _busy || _locked
                                    ? null
                                    : _refreshEmailVerification,
                                child: const Text('Check verification status'),
                              ),
                            _accountRow(
                              field: 'phone',
                              label: 'PHONE',
                              value: account.phone,
                              help: 'For game-day texts',
                              verified: account.phoneVerified,
                              actionKey: const Key('fieldrush-change-phone'),
                              onTap: _changePhone,
                              onAction: _changePhone,
                            ),
                          ],
                        ),
                      ),
                      _homeCityCard(account),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
                        child: SizedBox(
                          height: 48,
                          child: TextButton(
                            key: const Key('fieldrush-delete-account'),
                            onPressed: _busy || _locked ? null : _deleteAccount,
                            style: TextButton.styleFrom(
                              foregroundColor: FieldrushAuthTheme.danger,
                              backgroundColor: Colors.white,
                              textStyle: _text(12.5, weight: FontWeight.w800),
                              side: const BorderSide(
                                color: FieldrushAuthTheme.border,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text('Delete account'),
                          ),
                        ),
                      ),
                      _securityOptions(account),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  TextStyle _text(
    double size, {
    Color color = FieldrushAuthTheme.ink,
    FontWeight weight = FontWeight.w600,
    double height = 1.3,
    double? spacing,
  }) => TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: size,
    color: color,
    fontWeight: weight,
    height: height,
    letterSpacing: spacing,
  );

  Widget _card({required Widget child, EdgeInsetsGeometry? padding}) =>
      Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: padding,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: FieldrushAuthTheme.border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: child,
      );

  Widget _photoCard() {
    final avatar = _profile?.avatarUrl;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      padding: const EdgeInsets.fromLTRB(15, 15, 16, 15),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: FieldrushAuthTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  key: const Key('fieldrush-profile-photo'),
                  width: 64,
                  height: 64,
                  color: const Color(0xFFF2EFE3),
                  child: avatar?.isNotEmpty == true
                      ? Image.network(
                          avatar!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _photoPlaceholder(),
                        )
                      : _photoPlaceholder(),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Profile photo',
                      style: TextStyle(
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        height: 1.2,
                        color: FieldrushAuthTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Everyone can see it',
                      style: _text(11, color: FieldrushAuthTheme.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _pill(
                    key: const Key('fieldrush-change-photo'),
                    label: _photoBusy ? 'Saving…' : 'Change',
                    onPressed:
                        _photoBusy ||
                            _locked ||
                            widget.profileRepository == null
                        ? null
                        : _updatePhoto,
                  ),
                  if (avatar?.isNotEmpty == true)
                    TextButton(
                      key: const Key('fieldrush-reset-photo'),
                      onPressed: _photoBusy || _locked
                          ? null
                          : () => _updatePhoto(reset: true),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        foregroundColor: FieldrushAuthTheme.danger,
                        textStyle: _text(10.5, weight: FontWeight.w800),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Reset'),
                    ),
                ],
              ),
            ],
          ),
          if (_photoError != null) ...[
            const SizedBox(height: 10),
            Text(
              _photoError!,
              style: _text(10.5, color: FieldrushAuthTheme.danger),
            ),
          ],
        ],
      ),
    );
  }

  Widget _photoPlaceholder() => const Center(
    child: Icon(
      Icons.person_outline_rounded,
      size: 28,
      color: FieldrushAuthTheme.muted,
    ),
  );

  Widget _accountRow({
    required String field,
    required String label,
    required String value,
    required String help,
    String action = 'Edit',
    Key? actionKey,
    String? secondaryAction,
    Key? secondaryActionKey,
    bool? verified,
    bool first = false,
    VoidCallback? onTap,
    VoidCallback? onAction,
  }) {
    final editing = _editing == field;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: first
            ? null
            : const Border(top: BorderSide(color: Color(0xFFF0ECE0))),
      ),
      child: editing
          ? _inlineEditor(field, label, help)
          : Material(
              color: Colors.transparent,
              child: InkWell(
                key: Key('fieldrush-edit-$field'),
                onTap: _busy || _locked
                    ? null
                    : onTap ?? () => _openEdit(field),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 16, 15),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 7,
                              runSpacing: 5,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(label, style: _labelStyle),
                                if (verified != null)
                                  _verificationBadge(verified),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              value,
                              style: _text(14, weight: FontWeight.w700),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              help,
                              style: _text(
                                10.5,
                                color: FieldrushAuthTheme.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _pill(
                            key: actionKey,
                            label: action,
                            filled: action == 'Verify',
                            onPressed: _busy || _locked
                                ? null
                                : onAction ?? onTap ?? () => _openEdit(field),
                          ),
                          if (secondaryAction != null) ...[
                            const SizedBox(height: 8),
                            _pill(
                              key: secondaryActionKey,
                              label: secondaryAction,
                              onPressed: _busy || _locked
                                  ? null
                                  : () => _openEdit(field),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  TextStyle get _labelStyle => _text(
    9.5,
    color: FieldrushAuthTheme.muted,
    weight: FontWeight.w800,
    height: 1,
    spacing: 1.14,
  );

  Widget _verificationBadge(bool verified) => Semantics(
    label: verified ? 'Verified email or phone' : 'Not verified yet',
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: verified ? const Color(0xFFEFF6E4) : const Color(0xFFF7EED6),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        verified ? 'VERIFIED' : 'UNVERIFIED',
        style: _text(
          8,
          weight: FontWeight.w800,
          height: 1,
          spacing: .8,
          color: verified ? const Color(0xFF24472C) : const Color(0xFF8A6516),
        ),
      ),
    ),
  );

  Widget _pill({
    Key? key,
    required String label,
    required VoidCallback? onPressed,
    bool filled = false,
  }) => OutlinedButton(
    key: key,
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      backgroundColor: filled ? FieldrushAuthTheme.forest : Colors.white,
      foregroundColor: filled ? Colors.white : FieldrushAuthTheme.ink,
      textStyle: _text(11, weight: FontWeight.w800, height: 1),
      side: BorderSide(
        color: filled ? FieldrushAuthTheme.forest : FieldrushAuthTheme.border,
      ),
      shape: const StadiumBorder(),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    child: Text(label),
  );

  Widget _inlineEditor(String field, String label, String help) => Container(
    color: const Color(0xFFFBFAF4),
    padding: const EdgeInsets.fromLTRB(18, 14, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: _labelStyle.copyWith(color: const Color(0xFF24472C)),
        ),
        const SizedBox(height: 9),
        if (field == 'name') ...[
          _field(
            _firstName,
            'First name',
            'fieldrush-first-name',
            validateFieldrushName,
          ),
          const SizedBox(height: 8),
          _field(
            _lastName,
            'Last name',
            'fieldrush-last-name',
            validateFieldrushName,
          ),
        ],
        if (field == 'username')
          _field(
            _username,
            'Username',
            'fieldrush-username',
            (value) => validateFieldrushUsername(value.trim().toLowerCase()),
            prefix: '@',
          ),
        if (field == 'birthday')
          _field(
            _birthday,
            'YYYY-MM-DD',
            'fieldrush-birthday',
            _validateBirthday,
            keyboard: TextInputType.datetime,
          ),
        if (field == 'email')
          _field(
            _email,
            'Email address',
            'fieldrush-email',
            (value) =>
                isFieldrushEmail(value) ? null : 'Enter a valid email address.',
            keyboard: TextInputType.emailAddress,
          ),
        const SizedBox(height: 8),
        Text(
          field == 'email' && !widget.accountRepository.emailDeliveryEnabled
              ? 'You can save your contact email. Sign in with your verified phone or linked Google account.'
              : help,
          style: _text(10.5, color: FieldrushAuthTheme.muted, height: 1.35),
        ),
        const SizedBox(height: 13),
        Row(
          children: [
            OutlinedButton(
              key: const Key('fieldrush-cancel-edit'),
              onPressed: _busy ? null : _cancelEdit,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: Colors.white,
                foregroundColor: FieldrushAuthTheme.ink,
                side: const BorderSide(color: FieldrushAuthTheme.border),
                textStyle: _text(12, weight: FontWeight.w800),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                key: const Key('fieldrush-save-account'),
                onPressed: _busy || _locked || !_dirty ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  backgroundColor: FieldrushAuthTheme.forest,
                  textStyle: _text(12, weight: FontWeight.w800),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                child: Text(_busy ? 'Saving…' : 'Save'),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label,
    String key,
    String? Function(String) validator, {
    TextInputType? keyboard,
    String? prefix,
  }) => TextFormField(
    key: Key(key),
    controller: controller,
    enabled: !_busy && !_locked,
    keyboardType: keyboard,
    autocorrect: false,
    style: _text(15, weight: FontWeight.w700),
    onChanged: (_) => setState(() {}),
    decoration: InputDecoration(
      hintText: label,
      prefixText: prefix,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      isDense: true,
      errorMaxLines: 3,
      border: _inputBorder(const Color(0xFFC7DD9B)),
      enabledBorder: _inputBorder(const Color(0xFFC7DD9B)),
      focusedBorder: _inputBorder(FieldrushAuthTheme.forest),
      errorBorder: _inputBorder(const Color(0xFFE3B7B3)),
      focusedErrorBorder: _inputBorder(FieldrushAuthTheme.danger),
    ),
    validator: (value) => validator(value ?? ''),
  );

  OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: color, width: 1.5),
  );

  String _birthdayLabel(DateTime? date) {
    if (date == null) return 'Not set';
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  void _showBirthdayHelp() {
    showFieldrushModal<void>(
      context: context,
      builder: (context) => FieldrushModal(
        title: 'Your date of birth',
        description:
            'Your birthday is private and cannot be changed here. '
            'Contact support for a correction. You must be 18 or older to play.',
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _changeCity() async {
    final city = await showFieldrushModal<FieldrushCity>(
      context: context,
      builder: (_) => FieldrushCityPicker(
        repository: widget.cityRepository ?? SupabaseFieldrushCityRepository(),
        currentCityId: _account?.preferredCityId,
      ),
    );
    if (city != null && mounted) await _loadAccount(preserveDraft: true);
  }

  Widget _homeCityCard(FieldrushAccount account) => _card(
    padding: const EdgeInsets.fromLTRB(18, 15, 18, 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('HOME CITY', style: _labelStyle),
              const SizedBox(height: 8),
              Text(
                account.homeCity ?? 'Not available yet',
                style: _text(14, weight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                account.homeCity == null
                    ? 'Your home city will appear when the account service is updated.'
                    : 'Find games in this city. Your ranking city is based on where you play most this season, across both positions.',
                style: _text(11, color: FieldrushAuthTheme.muted, height: 1.45),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        TextButton(
          key: const ValueKey('account-change-city'),
          onPressed: _busy || _locked ? null : _changeCity,
          child: Text(
            'CHANGE',
            style: _text(
              9,
              color: const Color(0xFF3C4A38),
              weight: FontWeight.w800,
              height: 1,
              spacing: .9,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _securityOptions(FieldrushAccount account) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton(
          key: const Key('fieldrush-security-options'),
          onPressed: () =>
              setState(() => _securityExpanded = !_securityExpanded),
          style: TextButton.styleFrom(
            foregroundColor: FieldrushAuthTheme.muted,
            textStyle: _text(11, weight: FontWeight.w800),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Sign-in & security'),
              const SizedBox(width: 4),
              Icon(
                _securityExpanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
            ],
          ),
        ),
        if (_securityExpanded) ...[
          const SizedBox(height: 8),
          Text(
            account.googleLinked
                ? 'Google is linked'
                : 'Link Google as another way to sign in.',
            style: _text(12, color: FieldrushAuthTheme.muted),
          ),
          if (!account.googleLinked)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: OutlinedButton.icon(
                key: const Key('fieldrush-link-google'),
                onPressed: _busy || _locked ? null : _linkGoogle,
                style: _securityButtonStyle,
                icon: const SizedBox(
                  width: 18,
                  height: 18,
                  child: FieldrushGoogleMark(),
                ),
                label: const Text('Link Google'),
              ),
            ),
          if (_waitingForGoogle)
            TextButton(
              onPressed: () => _loadAccount(preserveDraft: true),
              child: const Text('Refresh linked accounts'),
            ),
          const SizedBox(height: 18),
          Text(
            'Lost access to your phone? Sign in with a previously linked '
            'Google account. Do not create another account to recover this one.',
            style: _text(11.5, color: FieldrushAuthTheme.muted, height: 1.5),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _signOut,
            style: _securityButtonStyle.copyWith(
              foregroundColor: const WidgetStatePropertyAll(
                FieldrushAuthTheme.danger,
              ),
            ),
            child: const Text('Sign out'),
          ),
        ],
      ],
    ),
  );

  ButtonStyle get _securityButtonStyle => OutlinedButton.styleFrom(
    backgroundColor: Colors.white,
    foregroundColor: FieldrushAuthTheme.ink,
    minimumSize: const Size(double.infinity, 46),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    side: const BorderSide(color: FieldrushAuthTheme.border),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    textStyle: _text(12.5, weight: FontWeight.w800, height: 1),
  );

  Widget _message(String message, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Semantics(
      liveRegion: true,
      child: Text(
        message,
        style: TextStyle(
          color: error ? FieldrushAuthTheme.danger : FieldrushAuthTheme.forest,
        ),
      ),
    ),
  );

  String _publicName(AccountDraft draft) {
    final last = draft.lastName.trim();
    return '${draft.firstName.trim()}${last.isEmpty ? '' : ' ${last.characters.first}.'}';
  }

  String? _validateBirthday(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return 'Enter your birthday as YYYY-MM-DD.';
    }
    final date = DateTime.tryParse(value);
    if (date == null || dateOfBirthToIso(date) != value || date.year < 1900) {
      return 'Enter a valid birthday.';
    }
    final today = DateTime.now();
    final age =
        today.year -
        date.year -
        (today.month < date.month ||
                (today.month == date.month && today.day < date.day)
            ? 1
            : 0);
    if (age < 18) return 'You must be 18 or older.';
    return null;
  }
}

class _ReauthenticationDialog extends StatefulWidget {
  const _ReauthenticationDialog({
    required this.repository,
    required this.purpose,
    required this.phone,
  });
  final FieldrushAccountRepository repository;
  final String purpose;
  final String phone;

  @override
  State<_ReauthenticationDialog> createState() =>
      _ReauthenticationDialogState();
}

class _ReauthenticationDialogState extends State<_ReauthenticationDialog> {
  final _code = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sent && !RegExp(r'^\d{6}$').hasMatch(_code.text)) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_sent) {
        await widget.repository.sendReauthenticationCode();
        if (mounted) setState(() => _sent = true);
      } else {
        await widget.repository.verifyReauthenticationCode(_code.text);
        if (mounted) Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = fieldrushAccountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FieldrushModal(
    key: const Key('fieldrush-reauth-modal'),
    title: 'Confirm it’s you',
    description:
        'Verify your current number ${widget.phone} to ${widget.purpose}.',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_sent) ...[
          TextField(
            key: const Key('fieldrush-reauth-code'),
            controller: _code,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: const InputDecoration(labelText: 'Verification code'),
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: FieldrushAuthTheme.danger),
            ),
          ),
      ],
    ),
    actions: [
      FilledButton(
        key: const Key('fieldrush-reauth-submit'),
        onPressed: _busy ? null : _submit,
        style: FieldrushModal.primaryButtonStyle(
          destructive: widget.purpose == 'delete your account',
        ),
        child: Text(
          _busy
              ? 'Please wait…'
              : _sent
              ? widget.purpose == 'delete your account'
                    ? 'Verify & delete account'
                    : 'Verify & continue'
              : 'Send code',
        ),
      ),
      OutlinedButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
    ],
  );
}

class _ChangePhoneDialog extends StatefulWidget {
  const _ChangePhoneDialog({
    required this.repository,
    required this.previousPhone,
  });
  final FieldrushAccountRepository repository;
  final String previousPhone;

  @override
  State<_ChangePhoneDialog> createState() => _ChangePhoneDialogState();
}

class _ChangePhoneDialogState extends State<_ChangePhoneDialog> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  IsoCode _country = IsoCode.US;
  String? _sentPhone;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phone =
        _sentPhone ?? normalizeFieldrushPhone(_phone.text, country: _country);
    if (phone == null || phone == widget.previousPhone) {
      setState(() => _error = 'Enter a valid, different phone number.');
      return;
    }
    if (_sentPhone != null && !RegExp(r'^\d{6}$').hasMatch(_code.text)) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_sentPhone == null) {
        await widget.repository.sendPhoneCode(phone);
        if (mounted) setState(() => _sentPhone = phone);
      } else {
        await widget.repository.verifyPhoneCode(phone, _code.text);
        if (mounted) Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = fieldrushAccountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FieldrushModal(
    key: const Key('fieldrush-change-phone-modal'),
    title: 'Your new phone number',
    description:
        'Your current number stays active until the new number is verified.',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldrushPhoneField(
          controller: _phone,
          enabled: !_busy && _sentPhone == null,
          onCountryChanged: (country) => _country = country,
        ),
        if (_sentPhone != null) ...[
          const SizedBox(height: 16),
          TextField(
            key: const Key('fieldrush-new-phone-code'),
            controller: _code,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: const InputDecoration(labelText: 'Verification code'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _sentPhone = null;
                    _code.clear();
                  }),
            child: const Text('Use a different number'),
          ),
        ],
        if (_error != null)
          Text(_error!, style: TextStyle(color: FieldrushAuthTheme.danger)),
      ],
    ),
    actions: [
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: Text(
          _busy
              ? 'Please wait…'
              : _sentPhone == null
              ? 'Send code'
              : 'Verify new number',
        ),
      ),
      OutlinedButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
    ],
  );
}

class _EmailVerificationDialog extends StatefulWidget {
  const _EmailVerificationDialog({
    required this.repository,
    required this.email,
    required this.onRequested,
  });
  final FieldrushAccountRepository repository;
  final String email;
  final VoidCallback onRequested;

  @override
  State<_EmailVerificationDialog> createState() =>
      _EmailVerificationDialogState();
}

class _EmailVerificationDialogState extends State<_EmailVerificationDialog>
    with WidgetsBindingObserver {
  final _code = TextEditingController();
  Timer? _resendTimer;
  int _resendSeconds = 0;
  bool _sent = false;
  bool _busy = false;
  bool _codeAccepted = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resendTimer?.cancel();
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _sent && !_busy) {
      _checkStatus();
    }
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    _resendSeconds = 60;
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      // tick counts elapsed periods, including callbacks delayed while the
      // app is in the background reading the verification email.
      setState(() => _resendSeconds = (60 - timer.tick).clamp(0, 60).toInt());
      if (_resendSeconds == 0) timer.cancel();
    });
  }

  String _emailError(Object error) {
    if (error is EmailVerificationStatusUnavailableException) {
      return 'Your code was accepted, but we could not check the final status. Check your connection and try again.';
    }
    if (error is AuthException) {
      switch (error.code) {
        case 'over_email_send_rate_limit':
        case 'over_request_rate_limit':
          return 'Too many requests. Wait a minute before trying again.';
        case 'otp_expired':
          return 'That code is invalid or has expired. Request a new code and try again.';
      }
    }
    return fieldrushAccountError(error);
  }

  Future<void> _checkStatus() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final snapshot = await widget.repository.loadAccount().timeout(
        const Duration(seconds: 30),
      );
      if (!mounted) return;
      if (snapshot.emailVerified &&
          snapshot.draft.email.trim().toLowerCase() ==
              widget.email.toLowerCase()) {
        Navigator.pop(context, snapshot);
      }
    } catch (_) {
      // Returning from an inbox is a background refresh, not a new submission.
      // Keep the code entry available if the status service is unreachable.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() async {
    if (_busy || (_sent && _resendSeconds > 0)) return;
    final resending = _sent;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.repository
          .requestEmailVerification(widget.email)
          .timeout(const Duration(seconds: 45));
      if (!mounted) return;
      widget.onRequested();
      setState(() {
        _sent = true;
        _codeAccepted = false;
        _code.clear();
        _notice = resending
            ? 'New code sent. Use the most recent email.'
            : null;
        _startResendCooldown();
      });
    } catch (error) {
      if (mounted) setState(() => _error = _emailError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_sent) return _sendCode();
    if (!_codeAccepted && !RegExp(r'^\d{6}$').hasMatch(_code.text)) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      if (!_codeAccepted) {
        await widget.repository.verifyEmailCode(widget.email, _code.text);
        if (!mounted) return;
        // A code may be consumed before a later account-status read fails.
        // Retrying must check server state, not submit that one-time code again.
        setState(() => _codeAccepted = true);
      }
      final snapshot = await widget.repository.loadAccount().timeout(
        const Duration(seconds: 30),
      );
      if (mounted) Navigator.pop(context, snapshot);
    } catch (error) {
      if (mounted) {
        setState(() {
          if (error is EmailVerificationStatusUnavailableException) {
            _codeAccepted = true;
          }
          _error = _emailError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: FieldrushModal(
      key: const Key('fieldrush-email-verification-modal'),
      title: 'Verify your email',
      description: _sent
          ? 'Enter the 6-digit code sent to ${widget.email}. It expires in 10 minutes.'
          : 'Send a verification code to ${widget.email}. Your phone and Google sign-in stay the same.',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_sent)
            TextField(
              key: const Key('fieldrush-email-verification-code'),
              controller: _code,
              enabled: !_busy && !_codeAccepted,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.oneTimeCode],
              onSubmitted: (_) => _submit(),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(
                labelText: '6-digit verification code',
                hintText: '000000',
              ),
            ),
          if (_sent && !_codeAccepted) ...[
            const SizedBox(height: 10),
            const Text(
              'Check Spam or Junk if it is missing. Only your new email needs to be verified.',
            ),
            TextButton(
              key: const Key('fieldrush-resend-email-code'),
              onPressed: _busy || _resendSeconds > 0 ? null : _sendCode,
              style: TextButton.styleFrom(
                foregroundColor: FieldrushAuthTheme.forest,
                minimumSize: const Size(44, 44),
                textStyle: FieldrushModal.bodyStyle.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              child: Text(
                _resendSeconds > 0
                    ? 'Resend code in ${_resendSeconds}s'
                    : 'Resend code',
              ),
            ),
          ],
          if (_codeAccepted)
            const Text(
              'Code accepted. Check verification status to finish confirming your email.',
            ),
          if (_notice != null)
            Semantics(liveRegion: true, child: Text(_notice!)),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: const TextStyle(color: FieldrushAuthTheme.danger),
              ),
            ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(
            _busy
                ? (_sent ? 'Checking…' : 'Sending code…')
                : !_sent
                ? 'Send code'
                : _codeAccepted
                ? 'Check verification status'
                : 'Verify email',
          ),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

String fieldrushAccountError(Object error) {
  if (error is GoogleEmailChangeStatusUnavailableException) {
    return 'We could not confirm whether Google was disconnected. Your new email was not saved. Check your connection and refresh your account before trying again.';
  }
  if (error is GoogleEmailChangeConfirmationRequiredException) {
    return 'Google is now linked to this account. Review the email change and save again to confirm disconnecting it.';
  }
  if (error is GoogleEmailChangeRequiresPhoneException) {
    return 'Verify your phone number before changing an email linked to Google, so you can still sign in.';
  }
  if (error is GoogleDisconnectedEmailUpdateException) {
    return 'Google was disconnected, but we could not confirm your email update. You can still sign in with your phone. Review your email before trying again.';
  }
  if (error is AuthException) return error.message;
  if (error is PostgrestException) return error.message;
  if (error is FunctionException) {
    final details = error.details;
    if (details is Map && details['error'] is String) {
      return details['error'] as String;
    }
  }
  return 'We couldn’t complete that request. Please try again.';
}
