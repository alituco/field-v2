import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../clans/clan_widgets.dart';
import 'moderation.dart';

class ModerationStatusLoadingScreen extends StatelessWidget {
  const ModerationStatusLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('moderation-status-loading'),
      backgroundColor: fieldGray900,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF111827), Color(0xFF062C26)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                  ),
                  child: const Icon(
                    Icons.sports_soccer_rounded,
                    color: fieldEmerald500,
                    size: 34,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'FIELD',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 22),
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    color: fieldEmerald500,
                    strokeWidth: 2.5,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Checking your account…',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RestrictedAccountScreen extends StatefulWidget {
  const RestrictedAccountScreen({
    super.key,
    required this.status,
    required this.onSignOut,
  });

  final ModerationStatus status;
  final Future<void> Function() onSignOut;

  @override
  State<RestrictedAccountScreen> createState() =>
      _RestrictedAccountScreenState();
}

class _RestrictedAccountScreenState extends State<RestrictedAccountScreen> {
  bool _isSigningOut = false;

  bool get _isBanned => widget.status.state == ModerationState.banned;

  Future<void> _signOut() async {
    if (_isSigningOut) return;
    setState(() => _isSigningOut = true);
    try {
      await widget.onSignOut();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('We could not sign you out. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSigningOut = false);
    }
  }

  void _openSupport() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _RestrictionSupportSheet(status: widget.status),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusLabel = _isBanned ? 'ACCOUNT BANNED' : 'ACCOUNT SUSPENDED';
    final title = _isBanned
        ? 'Your account is unavailable'
        : 'Your account is temporarily suspended';
    final fallbackMessage = _isBanned
        ? 'This account can no longer access Field.'
        : 'Access to Field has been paused by the moderation team.';

    return Scaffold(
      key: const Key('restricted-account-screen'),
      backgroundColor: fieldGray900,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF111827), Color(0xFF0C1824), Color(0xFF063B32)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 28),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 50,
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.sports_soccer_rounded,
                              color: fieldEmerald500,
                              size: 25,
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'FIELD',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 2.4,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.09),
                                borderRadius: BorderRadius.circular(99),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              child: Text(
                                statusLabel,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              color: _isBanned
                                  ? const Color(0xFFFEF2F2)
                                  : const Color(0xFFFFFBEB),
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      (_isBanned
                                              ? const Color(0xFFEF4444)
                                              : const Color(0xFFF59E0B))
                                          .withValues(alpha: 0.20),
                                  blurRadius: 30,
                                ),
                              ],
                            ),
                            child: Icon(
                              _isBanned
                                  ? Icons.lock_rounded
                                  : Icons.shield_outlined,
                              color: _isBanned
                                  ? const Color(0xFFDC2626)
                                  : const Color(0xFFD97706),
                              size: 38,
                            ),
                          ),
                        ),
                        const SizedBox(height: 26),
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 31,
                            height: 1.08,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.7,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          widget.status.message.isEmpty
                              ? fallbackMessage
                              : widget.status.message,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.72),
                            fontSize: 16,
                            height: 1.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (widget.status.endsAt != null) ...[
                          const SizedBox(height: 24),
                          Container(
                            key: const Key('restricted-account-end-date'),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.11),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: fieldEmerald500.withValues(
                                      alpha: 0.16,
                                    ),
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                  child: const Icon(
                                    Icons.schedule_rounded,
                                    color: fieldEmerald500,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 13),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'ACCESS RETURNS',
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.52,
                                          ),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 1.2,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        formatModerationDateTime(
                                          widget.status.endsAt!,
                                        ),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const Spacer(),
                        const SizedBox(height: 30),
                        FilledButton.icon(
                          key: const Key('restricted-account-contact-support'),
                          onPressed: _openSupport,
                          icon: const Icon(Icons.support_agent_rounded),
                          label: const Text('Contact support'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: fieldGray900,
                            minimumSize: const Size.fromHeight(54),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextButton(
                          key: const Key('restricted-account-sign-out'),
                          onPressed: _isSigningOut ? null : _signOut,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white.withValues(
                              alpha: 0.78,
                            ),
                            minimumSize: const Size.fromHeight(48),
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          child: _isSigningOut
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Sign out'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RestrictionSupportSheet extends StatelessWidget {
  const _RestrictionSupportSheet({required this.status});

  final ModerationStatus status;

  @override
  Widget build(BuildContext context) {
    final details = [
      'Account status: ${status.state.name.toUpperCase()}',
      if (status.message.isNotEmpty) 'Message: ${status.message}',
      if (status.endsAt != null)
        'Ends: ${status.endsAt!.toUtc().toIso8601String()}',
    ].join('\n');

    return Container(
      key: const Key('restricted-account-support-sheet'),
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        22 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: fieldGray200,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          const SizedBox(height: 22),
          const Row(
            children: [
              Icon(Icons.support_agent_rounded, color: fieldEmerald600),
              SizedBox(width: 10),
              Text(
                'Contact support',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'If you believe this is a mistake, contact your Field or league administrator and include your account details below.',
            style: TextStyle(
              color: fieldGray600,
              fontSize: 15,
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            key: const Key('restricted-account-copy-details'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: details));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Account details copied.')),
              );
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy account details'),
            style: OutlinedButton.styleFrom(
              foregroundColor: fieldGray900,
              side: const BorderSide(color: fieldGray200),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

String formatModerationDateTime(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${months[local.month - 1]} ${local.day}, ${local.year} at '
      '$hour:$minute $period';
}
