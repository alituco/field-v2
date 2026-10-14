import 'package:flutter/material.dart';

import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import 'support.dart';
import 'support_repository.dart';

const contactSupportSheetKey = ValueKey('contact-support-sheet');

Future<SupportRequestReceipt?> showContactSupportSheet({
  required BuildContext context,
  required SupportRepository repository,
  SupportRequestCategory? initialCategory,
  Map<String, Object?> requestContext = const {},
  Key? surfaceKey,
}) {
  return showFieldrushModal<SupportRequestReceipt>(
    context: context,
    builder: (_) => ContactSupportSheet(
      key: surfaceKey,
      repository: repository,
      initialCategory: initialCategory,
      requestContext: requestContext,
    ),
  );
}

class ContactSupportSheet extends StatefulWidget {
  const ContactSupportSheet({
    super.key,
    required this.repository,
    this.initialCategory,
    this.requestContext = const {},
  });

  final SupportRepository repository;
  final SupportRequestCategory? initialCategory;
  final Map<String, Object?> requestContext;

  @override
  State<ContactSupportSheet> createState() => _ContactSupportSheetState();
}

class _ContactSupportSheetState extends State<ContactSupportSheet> {
  static const _minimumDetailsLength = 10;
  static const _maximumDetailsLength = 2000;

  final TextEditingController _detailsController = TextEditingController();
  late final String _clientRequestId;
  late SupportRequestCategory? _category;
  bool _isSubmitting = false;
  String? _errorText;

  bool get _canSubmit {
    final details = _detailsController.text.trim();
    return !_isSubmitting &&
        _category != null &&
        details.length >= _minimumDetailsLength &&
        details.length <= _maximumDetailsLength;
  }

  @override
  void initState() {
    super.initState();
    _clientRequestId = createSupportClientRequestId();
    _category = widget.initialCategory;
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
      final receipt = await widget.repository.submitRequest(
        SupportRequestDraft(
          category: _category!,
          details: _detailsController.text,
          clientRequestId: _clientRequestId,
          context: widget.requestContext,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(receipt);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = userFacingError(
          error,
          fallback: 'We could not send your request. Try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSafety = _category == SupportRequestCategory.safety;

    return FieldrushModal(
      key: contactSupportSheetKey,
      eyebrow: 'Field support',
      title: 'How can we help?',
      description:
          'Send the Field team a private request. Include what happened and what you expected to happen.',
      headerAction: IconButton(
        key: const ValueKey('contact-support-close'),
        onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
        tooltip: 'Close',
        icon: const Icon(Icons.close_rounded),
        color: FieldrushAuthTheme.muted,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'WHAT DO YOU NEED HELP WITH?',
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
              for (final category in SupportRequestCategory.values)
                ChoiceChip(
                  key: ValueKey(
                    'support-category-${category.wireValue.toLowerCase()}',
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
          if (isSafety) ...[
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
                      'Support requests are not monitored live. If anyone is in immediate danger, contact venue staff or local emergency services now.',
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
          const Text(
            'TELL US WHAT HAPPENED',
            style: TextStyle(
              color: FieldrushAuthTheme.muted,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.25,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('support-details'),
            controller: _detailsController,
            enabled: !_isSubmitting,
            minLines: 4,
            maxLines: 7,
            maxLength: _maximumDetailsLength,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() => _errorText = null),
            decoration: InputDecoration(
              hintText:
                  'Describe the issue and include useful dates, match details, or steps if you can.',
              hintStyle: const TextStyle(
                color: FieldrushAuthTheme.muted,
                fontSize: 13,
                height: 1.35,
              ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.all(16),
              helperText:
                  'At least $_minimumDetailsLength characters. Do not include passwords or payment card details.',
              helperMaxLines: 2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: FieldrushAuthTheme.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: FieldrushAuthTheme.border),
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
              key: const ValueKey('support-error'),
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
        ],
      ),
      actions: [
        FilledButton.icon(
          key: const ValueKey('support-submit'),
          onPressed: _canSubmit ? _submit : null,
          style: FieldrushModal.primaryButtonStyle(),
          icon: _isSubmitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: FieldLoadingIndicator(color: Colors.white),
                )
              : const Icon(Icons.send_rounded, size: 19),
          label: Text(
            _isSubmitting ? 'Sending…' : 'Send to Field support',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }
}
