import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';
import 'date_of_birth.dart';
import 'fieldrush_account.dart';
import 'fieldrush_auth_theme.dart';
import 'fieldrush_phone_field.dart';

class FieldrushAccountScreen extends StatefulWidget {
  const FieldrushAccountScreen({
    super.key,
    required this.authRepository,
    required this.accountRepository,
  });

  final AuthRepository authRepository;
  final FieldrushAccountRepository accountRepository;

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

  Widget _buildContent(BuildContext context) {
    final account = _account;
    final emailVerified =
        account?.emailVerified == true &&
        _email.text.trim() == account?.draft.email;
    return Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      appBar: AppBar(title: const Text('Your account')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
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
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
                  children: [
                    Text(
                      'Make it yours.',
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            fontFamily: 'Outfit',
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    const Text('Manage your profile and how you sign in.'),
                    const SizedBox(height: 24),
                    if (_error != null) _message(_error!, error: true),
                    if (_notice != null) _message(_notice!),
                    if (_locked && !_deletionSubmitted)
                      _message(
                        'Deletion is pending. Account changes are disabled.',
                      ),
                    _section('Profile', [
                      Text(
                        'Other players see ${_publicName(account.draft)}. '
                        'Your full last name, birthday and contact details stay private.',
                      ),
                      const SizedBox(height: 20),
                      _field(
                        _firstName,
                        'First name',
                        'fieldrush-first-name',
                        validateFieldrushName,
                      ),
                      _field(
                        _lastName,
                        'Last name',
                        'fieldrush-last-name',
                        validateFieldrushName,
                      ),
                      _field(
                        _username,
                        'Username',
                        'fieldrush-username',
                        (value) => validateFieldrushUsername(
                          value.trim().toLowerCase(),
                        ),
                        helper:
                            '3–20 characters. Reserved staff and system names are unavailable.',
                      ),
                      _field(
                        _birthday,
                        'Birthday',
                        'fieldrush-birthday',
                        _validateBirthday,
                        helper: account.completed
                            ? 'Your birthday is private and cannot be changed here. Contact support for a correction.'
                            : 'YYYY-MM-DD. You must be 18 or older.',
                        keyboard: TextInputType.datetime,
                        readOnly: account.completed,
                      ),
                    ]),
                    _section('Email', [
                      _field(
                        _email,
                        'Email address',
                        'fieldrush-email',
                        (value) => isFieldrushEmail(value)
                            ? null
                            : 'Enter a valid email address.',
                        keyboard: TextInputType.emailAddress,
                      ),
                      Text(
                        emailVerified ? 'Verified email' : 'Not verified yet',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      if (!widget.accountRepository.emailDeliveryEnabled)
                        const Text(
                          'Email verification is not available yet. You can save your '
                          'email now, but it cannot be used for account recovery until verified.',
                        )
                      else
                        OutlinedButton(
                          key: const Key('fieldrush-verify-email'),
                          onPressed: _busy || _locked ? null : _verifyEmail,
                          child: Text(
                            emailVerified
                                ? 'Verify a different email'
                                : 'Verify email',
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
                    ]),
                    FilledButton(
                      key: const Key('fieldrush-save-account'),
                      onPressed: _busy || _locked ? null : _save,
                      child: Text(_busy ? 'Please wait…' : 'Save changes'),
                    ),
                    const SizedBox(height: 24),
                    _section('Sign-in & security', [
                      const Text(
                        'Phone number',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(account.phone),
                      Text(
                        account.phoneVerified
                            ? 'Verified'
                            : 'Verification required',
                      ),
                      OutlinedButton(
                        key: const Key('fieldrush-change-phone'),
                        onPressed: _busy || _locked || !account.phoneVerified
                            ? null
                            : _changePhone,
                        child: const Text('Change phone number'),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        account.googleLinked
                            ? 'Google is linked'
                            : 'Link Google as another way to sign in.',
                      ),
                      if (!account.googleLinked)
                        OutlinedButton.icon(
                          key: const Key('fieldrush-link-google'),
                          onPressed: _busy || _locked ? null : _linkGoogle,
                          icon: const Icon(Icons.link),
                          label: const Text('Link Google'),
                        ),
                      if (_waitingForGoogle)
                        TextButton(
                          onPressed: () => _loadAccount(preserveDraft: true),
                          child: const Text('Refresh linked accounts'),
                        ),
                      const SizedBox(height: 12),
                      const Text(
                        'Lost access to your phone? Sign in with a previously linked '
                        'Google account. Do not create another account to recover this one.',
                      ),
                    ]),
                    OutlinedButton(
                      onPressed: _busy ? null : _signOut,
                      child: const Text('Sign out'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      key: const Key('fieldrush-delete-account'),
                      onPressed: _busy || _locked ? null : _deleteAccount,
                      style: TextButton.styleFrom(
                        foregroundColor: FieldrushAuthTheme.danger,
                      ),
                      child: const Text('Delete account'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String key,
    String? Function(String) validator, {
    String? helper,
    TextInputType? keyboard,
    bool readOnly = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: Key(key),
      controller: controller,
      enabled: !_busy && !_locked,
      readOnly: readOnly,
      keyboardType: keyboard,
      autocorrect: false,
      onChanged: controller == _email ? (_) => setState(() {}) : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
      ),
      validator: (value) => validator(value ?? ''),
    ),
  );

  Widget _section(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.65),
      border: Border.all(color: FieldrushAuthTheme.border),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: 'Outfit',
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        ...children,
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
