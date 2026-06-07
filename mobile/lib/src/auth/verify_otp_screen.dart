import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';

class VerifyOtpScreen extends StatefulWidget {
  const VerifyOtpScreen({
    super.key,
    required this.authRepository,
    required this.phone,
    required this.onBack,
  });

  final AuthRepository authRepository;
  final String phone;
  final VoidCallback onBack;

  @override
  State<VerifyOtpScreen> createState() => _VerifyOtpScreenState();
}

class _VerifyOtpScreenState extends State<VerifyOtpScreen> {
  final _codeController = TextEditingController();
  bool _isVerifying = false;
  bool _isResending = false;
  String? _errorText;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    FocusScope.of(context).unfocus();
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _errorText = 'Enter the 6-digit code.');
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorText = null;
    });

    try {
      await widget.authRepository.verifyPhoneOtp(
        phone: widget.phone,
        token: code,
      );
    } on AuthException catch (error) {
      setState(() => _errorText = error.message);
    } catch (_) {
      setState(() => _errorText = 'Could not verify the code. Try again.');
    } finally {
      if (mounted) {
        setState(() => _isVerifying = false);
      }
    }
  }

  Future<void> _resend() async {
    setState(() {
      _isResending = true;
      _errorText = null;
    });

    try {
      await widget.authRepository.sendPhoneOtp(widget.phone);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Code sent again.')));
    } on AuthException catch (error) {
      setState(() => _errorText = error.message);
    } catch (_) {
      setState(() => _errorText = 'Could not resend the code. Try again.');
    } finally {
      if (mounted) {
        setState(() => _isResending = false);
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton.filledTonal(
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back',
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Enter your code',
                    style: textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF101915),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'We sent a 6-digit code to ${widget.phone}.',
                    style: textTheme.bodyLarge?.copyWith(
                      color: const Color(0xFF52635B),
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Verification code',
                      hintText: '123456',
                      counterText: '',
                      prefixIcon: Icon(Icons.pin_outlined),
                    ),
                    onSubmitted: (_) => _verify(),
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _errorText!,
                        style: TextStyle(color: colorScheme.onErrorContainer),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _isVerifying ? null : _verify,
                    icon: _isVerifying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_outlined),
                    label: Text(_isVerifying ? 'Verifying' : 'Verify'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _isResending ? null : _resend,
                    child: Text(_isResending ? 'Sending again' : 'Resend code'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
