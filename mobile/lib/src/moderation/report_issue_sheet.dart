import 'package:flutter/material.dart';

import '../ui/field_loading.dart';
import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import 'moderation.dart';
import 'moderation_repository.dart';

const moderationReportSheetKey = ValueKey('moderation-report-sheet');

Future<ModerationReportReceipt?> showReportIssueSheet({
  required BuildContext context,
  required ModerationRepository repository,
  required ModerationSubjectType subjectType,
  required String subjectId,
  required String subjectName,
  String? fixtureId,
  String? openQueueGameId,
}) {
  return showModalBottomSheet<ModerationReportReceipt>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: FieldrushAuthTheme.ink.withValues(alpha: 0.56),
    builder: (_) => ReportIssueSheet(
      repository: repository,
      subjectType: subjectType,
      subjectId: subjectId,
      subjectName: subjectName,
      fixtureId: fixtureId,
      openQueueGameId: openQueueGameId,
    ),
  );
}

class ReportIssueSheet extends StatefulWidget {
  const ReportIssueSheet({
    super.key,
    required this.repository,
    required this.subjectType,
    required this.subjectId,
    required this.subjectName,
    this.fixtureId,
    this.openQueueGameId,
  });

  final ModerationRepository repository;
  final ModerationSubjectType subjectType;
  final String subjectId;
  final String subjectName;
  final String? fixtureId;
  final String? openQueueGameId;

  @override
  State<ReportIssueSheet> createState() => _ReportIssueSheetState();
}

class _ReportIssueSheetState extends State<ReportIssueSheet> {
  static const _minimumDetailsLength = 10;
  static const _maximumDetailsLength = 2000;

  final TextEditingController _detailsController = TextEditingController();
  ModerationReportCategory? _category;
  bool _isSubmitting = false;
  String? _errorText;

  bool get _canSubmit {
    final details = _detailsController.text.trim();
    final needsDetails = _category == ModerationReportCategory.other;
    return !_isSubmitting &&
        _category != null &&
        (!needsDetails || details.length >= _minimumDetailsLength) &&
        details.length <= _maximumDetailsLength;
  }

  bool get _isUrgentCategory {
    return _category == ModerationReportCategory.threatsOrViolence ||
        _category == ModerationReportCategory.safetyOrVenue;
  }

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    try {
      final receipt = await widget.repository.submitReport(
        ModerationReportDraft(
          subjectType: widget.subjectType,
          subjectId: widget.subjectId,
          category: _category!,
          details: _detailsController.text,
          fixtureId: widget.fixtureId,
          openQueueGameId: widget.openQueueGameId,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(receipt);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = userFacingError(
          error,
          fallback: 'We could not send this report. Try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ModerationReportCategory.forSubject(widget.subjectType);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: Material(
        key: moderationReportSheetKey,
        color: Colors.transparent,
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.90,
          ),
          decoration: const BoxDecoration(
            color: FieldrushAuthTheme.cream,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + bottomInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: FieldrushAuthTheme.border,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8E8E4),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: FieldrushAuthTheme.danger.withValues(
                            alpha: 0.2,
                          ),
                        ),
                      ),
                      child: const Icon(
                        Icons.outlined_flag_rounded,
                        color: FieldrushAuthTheme.danger,
                        size: 25,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'PRIVATE REPORT',
                            style: TextStyle(
                              color: FieldrushAuthTheme.danger,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.35,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            'Report ${widget.subjectName}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Outfit',
                              color: FieldrushAuthTheme.ink,
                              fontSize: 21,
                              height: 1.12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('moderation-report-close'),
                      onPressed: _isSubmitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded),
                      color: FieldrushAuthTheme.muted,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Tell us what happened. Your identity stays private from ${widget.subjectName}; only the moderation team can review it.',
                  style: const TextStyle(
                    color: FieldrushAuthTheme.muted,
                    fontSize: 13,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'WHAT HAPPENED?',
                  style: TextStyle(
                    color: FieldrushAuthTheme.muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.25,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final category in categories)
                      ChoiceChip(
                        key: ValueKey(
                          'moderation-category-${category.wireValue.toLowerCase()}',
                        ),
                        selected: _category == category,
                        onSelected: _isSubmitting
                            ? null
                            : (_) => setState(() {
                                _category = category;
                                _errorText = null;
                              }),
                        showCheckmark: false,
                        label: Text(category.label),
                        labelStyle: TextStyle(
                          color: _category == category
                              ? Colors.white
                              : FieldrushAuthTheme.ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                        selectedColor: FieldrushAuthTheme.forest,
                        backgroundColor: Colors.white,
                        side: BorderSide(
                          color: _category == category
                              ? FieldrushAuthTheme.forest
                              : FieldrushAuthTheme.border,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                  ],
                ),
                if (_category case final category?) ...[
                  const SizedBox(height: 10),
                  Text(
                    category.description,
                    style: const TextStyle(
                      color: FieldrushAuthTheme.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (_isUrgentCategory) ...[
                  const SizedBox(height: 13),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFFBEB),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFFDE68A)),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.health_and_safety_outlined,
                          color: Color(0xFFD97706),
                          size: 19,
                        ),
                        SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            'If anyone is in immediate danger, contact venue staff or local emergency services now. Reports are not monitored live.',
                            style: TextStyle(
                              color: Color(0xFF92400E),
                              fontSize: 11,
                              height: 1.4,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  _category == ModerationReportCategory.other
                      ? 'DETAILS'
                      : 'DETAILS (OPTIONAL)',
                  style: const TextStyle(
                    color: FieldrushAuthTheme.muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.25,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('moderation-report-details'),
                  controller: _detailsController,
                  enabled: !_isSubmitting,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: _maximumDetailsLength,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() => _errorText = null),
                  decoration: InputDecoration(
                    hintText:
                        'Describe what happened and when. Do not include private contact information.',
                    hintStyle: const TextStyle(
                      color: FieldrushAuthTheme.muted,
                      fontSize: 13,
                      height: 1.35,
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.all(16),
                    helperText: _category == ModerationReportCategory.other
                        ? 'At least $_minimumDetailsLength characters · reports must be honest and specific.'
                        : 'Add useful context if you can. Reports must be honest and specific.',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: FieldrushAuthTheme.border,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: FieldrushAuthTheme.border,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: FieldrushAuthTheme.forest,
                        width: 2,
                      ),
                    ),
                  ),
                ),
                if (_errorText case final error?) ...[
                  const SizedBox(height: 10),
                  Container(
                    key: const ValueKey('moderation-report-error'),
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8E8E4),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: FieldrushAuthTheme.danger.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(
                      error,
                      style: const TextStyle(
                        color: FieldrushAuthTheme.danger,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton.icon(
                  key: const ValueKey('moderation-report-submit'),
                  onPressed: _canSubmit ? _submit : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    backgroundColor: FieldrushAuthTheme.forest,
                    disabledBackgroundColor: FieldrushAuthTheme.watermark,
                    disabledForegroundColor: FieldrushAuthTheme.muted,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: _isSubmitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: FieldLoadingIndicator(color: Colors.white),
                        )
                      : const Icon(Icons.outlined_flag_rounded, size: 20),
                  label: Text(
                    _isSubmitting ? 'Sending report…' : 'Send private report',
                    style: const TextStyle(fontWeight: FontWeight.w900),
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
