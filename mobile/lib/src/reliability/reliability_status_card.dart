import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import 'reliability.dart';
import 'reliability_repository.dart';

class ReliabilityStatusCard extends StatefulWidget {
  const ReliabilityStatusCard({super.key, required this.repository});

  final ReliabilityRepository repository;

  @override
  State<ReliabilityStatusCard> createState() => _ReliabilityStatusCardState();
}

class _ReliabilityStatusCardState extends State<ReliabilityStatusCard> {
  late Future<ReliabilityStatus> _future = widget.repository.getMyStatus();

  Future<void> _reload() async {
    final next = widget.repository.getMyStatus();
    setState(() => _future = next);
    try {
      await next;
    } catch (_) {
      // FutureBuilder renders the same error in the card. Consume it here so
      // retry/appeal callbacks do not also surface an unhandled app error.
    }
  }

  Future<void> _appeal(ReliabilityIncident incident) async {
    final submitted = await showReliabilityAppealSheet(
      context: context,
      repository: widget.repository,
      incident: incident,
    );
    if (!mounted || !submitted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Appeal submitted. Field operations will review it.'),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReliabilityStatus>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _ReliabilityLoadingCard();
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return _ReliabilityErrorCard(
            message: userFacingError(
              snapshot.error,
              fallback: 'Reliability status is unavailable right now.',
            ),
            onRetry: _reload,
          );
        }
        return _ReliabilityCard(status: snapshot.data!, onAppeal: _appeal);
      },
    );
  }
}

class _ReliabilityCard extends StatelessWidget {
  const _ReliabilityCard({required this.status, required this.onAppeal});

  final ReliabilityStatus status;
  final ValueChanged<ReliabilityIncident> onAppeal;

  @override
  Widget build(BuildContext context) {
    final isClear = status.isGoodStanding;
    final accent = isClear ? fieldEmerald600 : const Color(0xFFD97706);
    final surface = isClear ? fieldEmerald50 : const Color(0xFFFFFBEB);
    final border = isClear ? fieldEmerald100 : const Color(0xFFFDE68A);
    final incidents = status.incidents.take(2).toList();

    return Container(
      key: const ValueKey('profile-reliability-card'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D111827),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  isClear ? Icons.verified_user_rounded : Icons.policy_rounded,
                  color: accent,
                  size: 23,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'RELIABILITY',
                      style: TextStyle(
                        color: fieldGray500,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status.headline,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              if (status.activeStrikes > 0)
                Container(
                  key: const ValueKey('active-reliability-strikes'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${status.activeStrikes} ACTIVE',
                    style: TextStyle(
                      color: accent,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 13),
          Text(
            status.supportingText,
            style: const TextStyle(
              color: fieldGray600,
              fontSize: 12,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (status.visibleWalletBalances.isNotEmpty) ...[
            const SizedBox(height: 13),
            Container(
              key: const ValueKey('field-wallet-balance'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: fieldGray100),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final balance in status.visibleWalletBalances)
                    Padding(
                      key: ValueKey('field-wallet-balance-${balance.currency}'),
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.account_balance_wallet_outlined,
                            color: fieldGray500,
                            size: 18,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              'FIELD WALLET · ${balance.currency}',
                              style: const TextStyle(
                                color: fieldGray500,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .8,
                              ),
                            ),
                          ),
                          Text(
                            balance.label,
                            style: const TextStyle(
                              color: fieldGray900,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (status.visibleWalletBalances.length > 1) ...[
                    const SizedBox(height: 5),
                    const Text(
                      'Balances are separate. No currency conversion.',
                      style: TextStyle(color: fieldGray500, fontSize: 10),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (incidents.isNotEmpty) ...[
            const SizedBox(height: 15),
            const Divider(height: 1, color: fieldGray100),
            const SizedBox(height: 12),
            for (var index = 0; index < incidents.length; index++) ...[
              _IncidentRow(incident: incidents[index], onAppeal: onAppeal),
              if (index != incidents.length - 1)
                const Divider(height: 15, color: fieldGray100),
            ],
          ],
        ],
      ),
    );
  }
}

class _IncidentRow extends StatelessWidget {
  const _IncidentRow({required this.incident, required this.onAppeal});

  final ReliabilityIncident incident;
  final ValueChanged<ReliabilityIncident> onAppeal;

  @override
  Widget build(BuildContext context) {
    final detail = <String>[
      if (incident.matchLabel case final label? when label.trim().isNotEmpty)
        label,
      if (incident.occurredAt case final date?) _formatDate(date),
      if (incident.strikeDelta > 0)
        '+${incident.strikeDelta} ${incident.strikeDelta == 1 ? 'strike' : 'strikes'}',
      if (incident.strikeExpiresAt case final expires?)
        'expires ${_formatDate(expires)}',
      if (incident.appealStatus case final status?
          when status.trim().isNotEmpty)
        status.replaceAll('_', ' ').toLowerCase(),
    ];
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                incident.outcomeLabel,
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail.join(' · '),
                style: const TextStyle(
                  color: fieldGray400,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (incident.canAppeal && incident.attendanceRecordId.isNotEmpty)
          TextButton(
            key: ValueKey('appeal-reliability-${incident.attendanceRecordId}'),
            onPressed: () => onAppeal(incident),
            child: const Text(
              'Appeal',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
      ],
    );
  }
}

class _ReliabilityLoadingCard extends StatelessWidget {
  const _ReliabilityLoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('profile-reliability-loading'),
      height: 112,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: fieldGray100),
      ),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.4),
      ),
    );
  }
}

class _ReliabilityErrorCard extends StatelessWidget {
  const _ReliabilityErrorCard({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fieldGray100),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: fieldGray400),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: fieldGray500,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

Future<bool> showReliabilityAppealSheet({
  required BuildContext context,
  required ReliabilityRepository repository,
  required ReliabilityIncident incident,
}) async {
  final allowedCategories = incident.allowedAppealCategories;
  if (allowedCategories.isEmpty) return false;
  final controller = TextEditingController();
  var category = allowedCategories.first;
  var submitting = false;
  String? error;
  final submitted =
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> submit() async {
              final message = controller.text.trim();
              if (message.length < 10) {
                setSheetState(
                  () => error =
                      'Add at least 10 characters explaining what happened.',
                );
                return;
              }
              setSheetState(() {
                submitting = true;
                error = null;
              });
              try {
                await repository.submitAppeal(
                  attendanceRecordId: incident.attendanceRecordId,
                  category: category,
                  message: message,
                );
                if (sheetContext.mounted) Navigator.of(sheetContext).pop(true);
              } catch (caught) {
                if (!sheetContext.mounted) return;
                setSheetState(() {
                  submitting = false;
                  error = userFacingError(
                    caught,
                    fallback: 'We could not submit this appeal. Try again.',
                  );
                });
              }
            }

            return Container(
              key: const ValueKey('reliability-appeal-sheet'),
              padding: EdgeInsets.fromLTRB(
                20,
                10,
                20,
                20 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: fieldGray200,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'APPEAL ATTENDANCE OUTCOME',
                      style: TextStyle(
                        color: fieldEmerald700,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      incident.outcomeLabel,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (incident.appealDeadlineAt case final deadline?) ...[
                      const SizedBox(height: 5),
                      Text(
                        'Submit by ${_formatDateTime(deadline)}',
                        style: const TextStyle(
                          color: fieldGray500,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if (incident.checkedInAt != null ||
                        incident.checkInDeadlineAt != null ||
                        incident.strikeDelta > 0) ...[
                      const SizedBox(height: 15),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF9FAFB),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: fieldGray100),
                        ),
                        child: Column(
                          children: [
                            if (incident.checkedInAt case final checkedIn?)
                              _appealFact(
                                'Checked in',
                                _formatDateTime(checkedIn),
                              ),
                            if (incident.checkInDeadlineAt case final deadline?)
                              _appealFact(
                                'Check-in deadline',
                                _formatDateTime(deadline),
                              ),
                            if (incident.strikeDelta > 0)
                              _appealFact(
                                'Strike added',
                                '+${incident.strikeDelta}',
                              ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    DropdownButtonFormField<ReliabilityAppealCategory>(
                      initialValue: category,
                      decoration: const InputDecoration(
                        labelText: 'Reason',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final option in allowedCategories)
                          DropdownMenuItem(
                            value: option,
                            child: Text(option.label),
                          ),
                      ],
                      onChanged: submitting
                          ? null
                          : (value) {
                              if (value != null) {
                                setSheetState(() => category = value);
                              }
                            },
                    ),
                    const SizedBox(height: 13),
                    TextField(
                      controller: controller,
                      enabled: !submitting,
                      minLines: 4,
                      maxLines: 6,
                      maxLength: 2000,
                      decoration: const InputDecoration(
                        labelText: 'What happened?',
                        hintText:
                            'Give the operations team the facts they need.',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const ValueKey('submit-reliability-appeal'),
                      onPressed: submitting ? null : submit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        backgroundColor: fieldEmerald600,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: submitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Submit appeal',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'The referee records attendance facts. Field operations reviews consequences privately.',
                      style: TextStyle(
                        color: fieldGray400,
                        fontSize: 10,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ) ??
      false;
  controller.dispose();
  return submitted;
}

String _formatDate(DateTime value) {
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
  final bahrain = value.toUtc().add(const Duration(hours: 3));
  return '${months[bahrain.month - 1]} ${bahrain.day}';
}

String _formatDateTime(DateTime value) {
  final bahrain = value.toUtc().add(const Duration(hours: 3));
  final hour = bahrain.hour % 12 == 0 ? 12 : bahrain.hour % 12;
  final minute = bahrain.minute.toString().padLeft(2, '0');
  final period = bahrain.hour >= 12 ? 'PM' : 'AM';
  return '${_formatDate(value)} · $hour:$minute $period';
}

Widget _appealFact(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: fieldGray900,
            fontSize: 11,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    ),
  );
}
