import 'package:flutter/material.dart';

import '../ui/field_loading.dart';
import '../ui/fieldrush_toast.dart';
import '../clans/clan_widgets.dart';
import '../support/contact_support_sheet.dart';
import '../support/support.dart';
import '../support/support_repository.dart';
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
                  width: 220,
                  child: Column(
                    children: [
                      FieldSkeleton(height: 14, color: Colors.white24),
                      SizedBox(height: 10),
                      FieldSkeleton(
                        width: 140,
                        height: 14,
                        color: Colors.white24,
                      ),
                    ],
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
    this.supportRepository,
  });

  final ModerationStatus status;
  final Future<void> Function() onSignOut;
  final SupportRepository? supportRepository;

  @override
  State<RestrictedAccountScreen> createState() =>
      _RestrictedAccountScreenState();
}

class _RestrictedAccountScreenState extends State<RestrictedAccountScreen> {
  bool _isSigningOut = false;
  late final SupportRepository _supportRepository;

  bool get _isBanned => widget.status.state == ModerationState.banned;

  @override
  void initState() {
    super.initState();
    _supportRepository =
        widget.supportRepository ?? SupabaseSupportRepository();
  }

  Future<void> _signOut() async {
    if (_isSigningOut) return;
    setState(() => _isSigningOut = true);
    try {
      await widget.onSignOut();
    } catch (_) {
      if (mounted) {
        showFieldrushToast(
          context,
          'We could not sign you out. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSigningOut = false);
    }
  }

  Future<void> _openSupport() async {
    final receipt = await showContactSupportSheet(
      context: context,
      repository: _supportRepository,
      initialCategory: SupportRequestCategory.accountOrProfile,
      surfaceKey: const ValueKey('restricted-account-support-sheet'),
      requestContext: {
        'entry_point': 'restricted_account',
        'moderation_state': widget.status.state.name.toUpperCase(),
        'moderation_scope': widget.status.scope.name.toUpperCase(),
        'moderation_message': widget.status.message,
        'moderation_ends_at': widget.status.endsAt?.toUtc().toIso8601String(),
        'warning_count': widget.status.warningCount,
      },
    );
    if (!mounted || receipt == null) return;
    showFieldrushToast(
      context,
      'Request sent · reference ${receipt.shortReference}',
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
                            const Expanded(
                              child: Text(
                                'FIELD',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 2.4,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Container(
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
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    statusLabel,
                                    maxLines: 1,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
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
                              ? const Text('Signing out…')
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
