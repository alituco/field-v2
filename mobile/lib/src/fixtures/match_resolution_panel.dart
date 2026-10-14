import 'package:flutter/material.dart';

import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import 'match_resolution.dart';

class MatchResolutionPanel extends StatefulWidget {
  const MatchResolutionPanel({
    super.key,
    required this.resolutionCase,
    required this.repository,
    required this.matchKind,
    required this.matchId,
    this.onChanged,
  });

  final MatchResolutionCase resolutionCase;
  final MatchResolutionRepository repository;
  final MatchResolutionKind matchKind;
  final String matchId;
  final ValueChanged<MatchResolutionCase>? onChanged;

  @override
  State<MatchResolutionPanel> createState() => _MatchResolutionPanelState();
}

class _MatchResolutionPanelState extends State<MatchResolutionPanel> {
  late MatchResolutionCase _resolutionCase = widget.resolutionCase;
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void didUpdateWidget(covariant MatchResolutionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolutionCase != widget.resolutionCase) {
      _resolutionCase = widget.resolutionCase;
    }
  }

  Future<void> _openDispute() async {
    if (!_resolutionCase.canDispute || _isSubmitting) return;
    final reason = await showMatchResolutionDisputeSheet(context);
    if (reason == null || !mounted) return;

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    try {
      await widget.repository.submitMatchResolutionDispute(
        caseId: _resolutionCase.id,
        reason: reason,
      );
      final refreshed = await widget.repository.getMatchResolutionCase(
        matchKind: widget.matchKind,
        matchId: widget.matchId,
      );
      if (!mounted) return;
      if (refreshed != null) {
        setState(() => _resolutionCase = refreshed);
        widget.onChanged?.call(refreshed);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your dispute was sent. Refund processing will continue.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = userFacingError(
          error,
          fallback: 'We could not submit your dispute. Try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final resolution = _resolutionCase.resolution;
    final dispute = _resolutionCase.latestDispute;
    final isWaiting = resolution == null;
    final detailText = resolution == null
        ? _resolutionCase.reviewReasonLabel
        : resolution.reason;
    final accent = isWaiting
        ? const Color(0xFFD97706)
        : dispute?.isOpen == true
        ? fieldBlue600
        : fieldEmerald600;
    final surface = isWaiting
        ? const Color(0xFFFFFBEB)
        : dispute?.isOpen == true
        ? const Color(0xFFEFF6FF)
        : const Color(0xFFECFDF5);

    return Container(
      key: const ValueKey('match-resolution-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A111827),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  isWaiting
                      ? Icons.pending_actions_rounded
                      : Icons.verified_rounded,
                  color: accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'FIELD MATCH REVIEW',
                      style: TextStyle(
                        color: fieldGray500,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _resolutionCase.outcomeLabel,
                      key: const ValueKey('match-resolution-outcome'),
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 16,
                        height: 1.15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              if (resolution?.scoreLabel case final score?)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: fieldGray900,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    score,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
            ],
          ),
          if (detailText.isNotEmpty) ...[
            const SizedBox(height: 13),
            Text(
              detailText,
              style: const TextStyle(
                color: fieldGray600,
                fontSize: 12,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (_resolutionCase.refunds.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(height: 1, color: fieldGray100),
            const SizedBox(height: 14),
            const Text(
              'YOUR REFUND',
              style: TextStyle(
                color: fieldGray500,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 9),
            for (final refund in _resolutionCase.refunds) ...[
              _RefundRow(refund: refund),
              if (refund != _resolutionCase.refunds.last)
                const SizedBox(height: 8),
            ],
          ],
          if (dispute != null) ...[
            const SizedBox(height: 14),
            _DisputeStatus(dispute: dispute),
          ],
          if (_errorText != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                _errorText!,
                style: const TextStyle(
                  color: Color(0xFFB91C1C),
                  fontSize: 11,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          if (_resolutionCase.canDispute) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('open-match-resolution-dispute'),
                onPressed: _isSubmitting ? null : _openDispute,
                style: OutlinedButton.styleFrom(
                  foregroundColor: fieldGray900,
                  side: const BorderSide(color: fieldGray300),
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                icon: _isSubmitting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: FieldLoadingIndicator(),
                      )
                    : const Icon(Icons.flag_outlined, size: 18),
                label: Text(
                  _isSubmitting ? 'Sending…' : 'Question this decision',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            if (_resolutionCase.refundsContinueDuringDispute) ...[
              const SizedBox(height: 8),
              const Text(
                'Submitting a dispute does not pause an approved refund.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: fieldGray500,
                  fontSize: 10,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _RefundRow extends StatelessWidget {
  const _RefundRow({required this.refund});

  final MatchResolutionRefund refund;

  @override
  Widget build(BuildContext context) {
    final failed = refund.status == 'FAILED';
    final noRefund = refund.displayAmountFils <= 0;
    final failureReason = refund.failureReason;
    final color = failed
        ? const Color(0xFFB91C1C)
        : noRefund
        ? fieldGray500
        : fieldEmerald700;
    return Container(
      key: ValueKey('match-resolution-refund-${refund.id}'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: failed
            ? const Color(0xFFFEF2F2)
            : noRefund
            ? const Color(0xFFF9FAFB)
            : const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Icon(
            failed
                ? Icons.error_outline_rounded
                : noRefund
                ? Icons.info_outline_rounded
                : Icons.account_balance_wallet_outlined,
            size: 20,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  refund.statusLabel,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  noRefund
                      ? 'No refund is due for your booking.'
                      : '${refund.amountLabel} · ${refund.destinationLabel}',
                  style: const TextStyle(
                    color: fieldGray600,
                    fontSize: 11,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (failed &&
                    failureReason != null &&
                    failureReason.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    failureReason,
                    style: const TextStyle(
                      color: Color(0xFF991B1B),
                      fontSize: 10,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DisputeStatus extends StatelessWidget {
  const _DisputeStatus({required this.dispute});

  final MatchResolutionDispute dispute;

  @override
  Widget build(BuildContext context) {
    final open = dispute.isOpen;
    return Container(
      key: const ValueKey('match-resolution-dispute-status'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: open ? const Color(0xFFEFF6FF) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            open ? Icons.hourglass_top_rounded : Icons.fact_check_outlined,
            color: open ? fieldBlue600 : fieldGray500,
            size: 19,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YOUR DISPUTE · ${dispute.statusLabel.toUpperCase()}',
                  style: TextStyle(
                    color: open ? const Color(0xFF1D4ED8) : fieldGray700,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.45,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  dispute.resolutionNote?.isNotEmpty == true
                      ? dispute.resolutionNote!
                      : open
                      ? 'Field will review the details you submitted.'
                      : dispute.reason,
                  style: const TextStyle(
                    color: fieldGray600,
                    fontSize: 11,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<String?> showMatchResolutionDisputeSheet(BuildContext context) {
  return showFieldrushModal<String>(
    context: context,
    builder: (_) => const _MatchResolutionDisputeSheet(),
  );
}

class _MatchResolutionDisputeSheet extends StatefulWidget {
  const _MatchResolutionDisputeSheet();

  @override
  State<_MatchResolutionDisputeSheet> createState() =>
      _MatchResolutionDisputeSheetState();
}

class _MatchResolutionDisputeSheetState
    extends State<_MatchResolutionDisputeSheet> {
  final _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _controller.text.trim();
    if (reason.length < 10) {
      setState(
        () => _errorText =
            'Add at least 10 characters so Fieldrush can understand the issue.',
      );
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return FieldrushModal(
      key: const ValueKey('match-resolution-dispute-sheet'),
      eyebrow: 'Question this decision',
      title: 'Tell us what needs another look.',
      description:
          'Be specific about the result, attendance, or refund. Your approved refund will keep processing while Fieldrush reviews this.',
      content: TextField(
        key: const ValueKey('match-resolution-dispute-reason'),
        controller: _controller,
        autofocus: true,
        minLines: 3,
        maxLines: 5,
        maxLength: 1000,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          hintText:
              'Example: I checked in before kickoff, but I was marked as absent.',
          errorText: _errorText,
        ),
        onChanged: (_) {
          if (_errorText != null) setState(() => _errorText = null);
        },
      ),
      actions: [
        FilledButton(
          key: const ValueKey('submit-match-resolution-dispute'),
          onPressed: _submit,
          style: FieldrushModal.primaryButtonStyle(),
          child: const Text('Send to Fieldrush'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FieldrushModal.secondaryButtonStyle(),
          child: const Text('Not now'),
        ),
      ],
    );
  }
}
