import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';
import 'phone_number.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.authRepository,
    required this.onOtpSent,
  });

  final AuthRepository authRepository;
  final ValueChanged<String> onOtpSent;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final phone = normalizePhoneNumber(_phoneController.text);
    if (!isValidE164PhoneNumber(phone)) {
      setState(() {
        _errorText = 'Enter a valid phone number with country code.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    try {
      await widget.authRepository.sendPhoneOtp(phone);
      if (!mounted) return;
      widget.onOtpSent(phone);
    } on AuthException catch (error) {
      setState(() => _errorText = error.message);
    } catch (_) {
      setState(() => _errorText = 'Could not send the code. Try again.');
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 68,
                      height: 68,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(
                        Icons.sports_soccer,
                        color: colorScheme.onPrimary,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'Field',
                      style: textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF101915),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in with your phone number to join clans and schedule matches.',
                      style: textTheme.bodyLarge?.copyWith(
                        color: const Color(0xFF52635B),
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.telephoneNumber],
                      decoration: const InputDecoration(
                        labelText: 'Phone number',
                        hintText: '+1 555 123 4567',
                        prefixIcon: Icon(Icons.phone_iphone),
                      ),
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'US numbers can be entered as 10 digits. Other countries should include + and country code.',
                      style: textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF6B7C73),
                      ),
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 16),
                      _InlineError(message: _errorText!),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _isSubmitting ? null : _submit,
                      icon: _isSubmitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sms_outlined),
                      label: Text(_isSubmitting ? 'Sending code' : 'Send code'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
