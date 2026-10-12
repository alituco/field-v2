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
import '../ui/field_loading.dart';

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
    this.bottomNavigationBar,
    this.bottomNavigationBuilder,
  }) : assert(bottomNavigationBar == null || bottomNavigationBuilder == null);

  final AuthRepository authRepository;
  final FieldrushAccountRepository accountRepository;
  final ProfileRepository? profileRepository;
  final ImagePicker? imagePicker;
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
  String? _pendingVerificationEmail;

  bool get _locked =>
      _deletionSubmitted || (_account?.deletionPending ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAccount();
    _loadProfile();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    if (state == AppLifecycleState.resumed && _waitingForGoogle) {
      _waitingForGoogle = false;
      _loadAccount(preserveDraft: true);
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
    try {
      final account = await widget.accountRepository.loadAccount();
      if (!mounted) return;
      setState(() {
        if (preserveDraft) {
          _account = account;
        } else {
          _applyAccount(account);
        }
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = fieldrushAccountError(error);
      });
    }
  }

  Future<void> _loadProfile() async {
    final repository = widget.profileRepository;
    if (repository == null) return;
    try {
      final profile = await repository.getCurrentProfile();
      if (mounted) setState(() => _profile = profile);
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
    await _run(() async {
      final updated = await widget.accountRepository.updateAccount(_draft);
      if (!mounted) return;
      setState(() {
        _applyAccount(updated);
        _editing = null;
        _notice = 'Account details saved.';
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
    if (!widget.accountRepository.emailDeliveryEnabled) return;
    if (!isFieldrushEmail(_email.text)) {
      setState(() => _error = 'Enter a valid email address first.');
      return;
    }
    final email = _email.text.trim();
    final snapshot = await showDialog<FieldrushAccount>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _EmailVerificationDialog(
        repository: widget.accountRepository,
        email: email,
      ),
    );
    if (snapshot != null && mounted) {
      _applyEmailVerification(snapshot, email);
    }
  }

  void _applyEmailVerification(FieldrushAccount snapshot, String email) {
    final verified = snapshot.emailVerified && snapshot.draft.email == email;
    setState(() {
      _account = snapshot;
      _error = null;
      _pendingVerificationEmail = verified ? null : email;
      _notice = verified
          ? 'Email verified.'
          : 'Email verification is not complete yet. If you are changing your '
                'email, also confirm the message sent to your previous email '
                'address, then check verification status.';
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
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _ReauthenticationDialog(
          repository: widget.accountRepository,
          purpose: purpose,
          phone: _account!.phone,
        ),
      ) ??
      false;

  Future<void> _changePhone() async {
    if (!await _reauthenticate('change your phone number') || !mounted) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'This removes your account and personal profile. Some transaction or '
          'safety records may need to be retained. Active bookings, payments or '
          'other unsettled activity may need to be resolved first. Deleting an '
          'account does not automatically cancel bookings or issue refunds.\n\n'
          'You will verify your current phone number before continuing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep account'),
          ),
          TextButton(
            key: const Key('fieldrush-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue to verification'),
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
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard your changes?'),
            content: const Text('Your unsaved account changes will be lost.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                key: const Key('fieldrush-discard-changes'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard changes'),
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
                                  ? 'For receipts and account recovery'
                                  : widget
                                        .accountRepository
                                        .emailDeliveryEnabled
                                  ? 'Verify it to get receipts and reminders'
                                  : 'Email verification is not available yet.',
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
                      _pill(
                        key: actionKey,
                        label: action,
                        filled: action == 'Verify',
                        onPressed: _busy || _locked
                            ? null
                            : onAction ?? onTap ?? () => _openEdit(field),
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
              ? 'You can save your email now. It cannot be used for account recovery until verified.'
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
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your date of birth'),
        content: const Text(
          'Your birthday is private and cannot be changed here. '
          'Contact support for a correction. You must be 18 or older to play.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
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
                    : 'Your skill rating counts on this ladder. City changes will be available later.',
                style: _text(11, color: FieldrushAuthTheme.muted, height: 1.45),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF2EFE3),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            account.homeCity == null ? 'PENDING' : 'LOCKED',
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
            OutlinedButton.icon(
              key: const Key('fieldrush-link-google'),
              onPressed: _busy || _locked ? null : _linkGoogle,
              icon: const Icon(Icons.link, size: 18),
              label: const Text('Link Google'),
            ),
          if (_waitingForGoogle)
            TextButton(
              onPressed: () => _loadAccount(preserveDraft: true),
              child: const Text('Refresh linked accounts'),
            ),
          const SizedBox(height: 8),
          Text(
            'Lost access to your phone? Sign in with a previously linked '
            'Google account. Do not create another account to recover this one.',
            style: _text(11, color: FieldrushAuthTheme.muted),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _signOut,
            child: const Text('Sign out'),
          ),
        ],
      ],
    ),
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Confirm it’s you'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Verify your current number ${widget.phone} to ${widget.purpose}.',
          ),
          if (_sent) ...[
            const SizedBox(height: 16),
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
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('fieldrush-reauth-submit'),
        onPressed: _busy ? null : _submit,
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Your new phone number'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Your current number stays active until the new number is verified.',
          ),
          const SizedBox(height: 16),
          FieldrushPhoneField(
            controller: _phone,
            enabled: !_busy && _sentPhone == null,
            onCountryChanged: (country) => _country = country,
          ),
          if (_sentPhone != null) ...[
            const SizedBox(height: 16),
            TextField(
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
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
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
    ],
  );
}

class _EmailVerificationDialog extends StatefulWidget {
  const _EmailVerificationDialog({
    required this.repository,
    required this.email,
  });
  final FieldrushAccountRepository repository;
  final String email;

  @override
  State<_EmailVerificationDialog> createState() =>
      _EmailVerificationDialogState();
}

class _EmailVerificationDialogState extends State<_EmailVerificationDialog> {
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
        await widget.repository.requestEmailVerification(widget.email);
        if (mounted) setState(() => _sent = true);
      } else {
        await widget.repository.verifyEmailCode(widget.email, _code.text);
        final snapshot = await widget.repository.loadAccount();
        if (mounted) Navigator.pop(context, snapshot);
      }
    } catch (error) {
      if (mounted) setState(() => _error = fieldrushAccountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Verify your email'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Send a verification code to ${widget.email}.'),
          if (_sent)
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(labelText: 'Verification code'),
            ),
          if (_error != null)
            Text(_error!, style: TextStyle(color: FieldrushAuthTheme.danger)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: Text(
          _busy
              ? 'Please wait…'
              : _sent
              ? 'Verify email'
              : 'Send code',
        ),
      ),
    ],
  );
}

String fieldrushAccountError(Object error) {
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
