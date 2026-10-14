import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../ui/fieldrush_modal.dart';

/// Existing callers share the Fieldrush sheet without changing their actions.
Future<bool> showFieldConfirmDialog({
  required BuildContext context,
  required IconData icon,
  required String eyebrow,
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Not now',
  String? detail,
  bool destructive = false,
  bool confirmEnabled = true,
  bool barrierDismissible = true,
}) async =>
    await showFieldrushModal<bool>(
      context: context,
      dismissible: barrierDismissible,
      builder: (context) => FieldrushModal(
        key: const ValueKey('field-confirmation-dialog'),
        eyebrow: eyebrow,
        title: title,
        description: message,
        content: detail == null || detail.trim().isEmpty
            ? null
            : Container(
                key: const ValueKey('field-confirmation-detail'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: FieldrushAuthTheme.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: destructive
                          ? FieldrushAuthTheme.danger
                          : FieldrushAuthTheme.forest,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(detail, style: FieldrushModal.bodyStyle),
                    ),
                  ],
                ),
              ),
        actions: [
          FilledButton(
            key: const ValueKey('field-confirmation-confirm'),
            onPressed: confirmEnabled
                ? () => Navigator.pop(context, true)
                : null,
            style: FieldrushModal.primaryButtonStyle(destructive: destructive),
            child: Text(confirmLabel),
          ),
          OutlinedButton(
            key: const ValueKey('field-confirmation-cancel'),
            onPressed: () => Navigator.pop(context, false),
            style: FieldrushModal.secondaryButtonStyle(),
            child: Text(cancelLabel),
          ),
        ],
      ),
    ) ??
    false;
