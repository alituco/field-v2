import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/fieldrush_auth_theme.dart';

/// Open the public document without tying an app flow to a policy request.
Future<void> openFieldrushPolicy(BuildContext context, String path) async {
  final uri = Uri.https('fieldrush.gg', path);
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    // Keep the current draft and give the player the destination to retry.
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Could not open $uri. Please try again.')),
  );
}

class FieldrushSignupPolicyNotice extends StatelessWidget {
  const FieldrushSignupPolicyNotice({
    super.key,
    this.light = false,
    this.creatingAccount = false,
    this.textKey,
  });

  final bool light;
  final bool creatingAccount;
  final Key? textKey;

  @override
  Widget build(BuildContext context) => _PolicyNotice(
    textKey: textKey,
    light: light,
    centered: true,
    prefix: creatingAccount
        ? 'By creating an account, you agree to our '
        : 'By tapping Create account or Log in, you agree to our ',
    firstLabel: 'Terms',
    firstPath: '/terms',
    secondLabel: 'Privacy Policy',
    secondPath: '/privacy',
    suffix: '.',
  );
}

class FieldrushBookingPolicyNotice extends StatelessWidget {
  const FieldrushBookingPolicyNotice({super.key, this.freeBooking = false});

  final bool freeBooking;

  @override
  Widget build(BuildContext context) => _PolicyNotice(
    textKey: const Key('fieldrush-booking-agreement'),
    prefix: freeBooking
        ? 'By booking, you accept the '
        : 'By paying, you accept the ',
    firstLabel: 'Participation terms',
    firstPath: '/participation',
    secondLabel: 'Recording policy',
    secondPath: '/recording',
    suffix: '. Games are filmed and streamed.',
  );
}

class _PolicyNotice extends StatefulWidget {
  const _PolicyNotice({
    this.textKey,
    this.light = false,
    this.centered = false,
    required this.prefix,
    required this.firstLabel,
    required this.firstPath,
    required this.secondLabel,
    required this.secondPath,
    required this.suffix,
  });

  final Key? textKey;
  final bool light;
  final bool centered;
  final String prefix;
  final String firstLabel;
  final String firstPath;
  final String secondLabel;
  final String secondPath;
  final String suffix;

  @override
  State<_PolicyNotice> createState() => _PolicyNoticeState();
}

class _PolicyNoticeState extends State<_PolicyNotice> {
  late final _firstLink = TapGestureRecognizer()
    ..onTap = () => openFieldrushPolicy(context, widget.firstPath);
  late final _secondLink = TapGestureRecognizer()
    ..onTap = () => openFieldrushPolicy(context, widget.secondPath);

  @override
  void dispose() {
    _firstLink.dispose();
    _secondLink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final linkStyle = TextStyle(
      color: widget.light ? Colors.white : FieldrushAuthTheme.forest,
      fontWeight: FontWeight.w800,
      decoration: widget.light ? TextDecoration.underline : TextDecoration.none,
      decorationColor: Colors.white,
    );
    return Text.rich(
      TextSpan(
        text: widget.prefix,
        children: [
          TextSpan(
            text: widget.firstLabel,
            style: linkStyle,
            recognizer: _firstLink,
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: widget.secondLabel,
            style: linkStyle,
            recognizer: _secondLink,
          ),
          TextSpan(text: widget.suffix),
        ],
      ),
      key: widget.textKey,
      textAlign: widget.centered ? TextAlign.center : TextAlign.start,
      style: TextStyle(
        fontFamily: 'PlusJakartaSans',
        color: widget.light
            ? Colors.white.withValues(alpha: 0.88)
            : FieldrushAuthTheme.muted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        height: 1.5,
      ),
    );
  }
}
