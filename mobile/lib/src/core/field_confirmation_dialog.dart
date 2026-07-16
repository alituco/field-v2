import 'package:flutter/material.dart';

import '../clans/clan_widgets.dart';

/// Shows the app's standard confirmation surface.
///
/// Keep destructive actions explicit by setting [destructive] rather than
/// styling individual buttons at each call site.
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
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: barrierDismissible,
        barrierColor: fieldGray900.withValues(alpha: 0.56),
        builder: (dialogContext) => _FieldConfirmationDialog(
          icon: icon,
          eyebrow: eyebrow,
          title: title,
          message: message,
          detail: detail,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
          destructive: destructive,
          confirmEnabled: confirmEnabled,
        ),
      ) ??
      false;
}

class _FieldConfirmationDialog extends StatelessWidget {
  const _FieldConfirmationDialog({
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.message,
    required this.detail,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
    required this.confirmEnabled,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final String message;
  final String? detail;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final bool confirmEnabled;

  @override
  Widget build(BuildContext context) {
    final accent = destructive ? const Color(0xFFDC2626) : fieldEmerald600;
    final accentSurface = destructive
        ? const Color(0xFFFEF2F2)
        : fieldEmerald50;
    final accentBorder = destructive
        ? const Color(0xFFFECACA)
        : fieldEmerald200;

    return Dialog(
      key: const ValueKey('field-confirmation-dialog'),
      elevation: 0,
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.8)),
            boxShadow: [
              BoxShadow(
                color: fieldGray900.withValues(alpha: 0.22),
                blurRadius: 36,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: accentSurface,
                        borderRadius: BorderRadius.circular(17),
                        border: Border.all(color: accentBorder),
                      ),
                      child: Icon(icon, color: accent, size: 27),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              eyebrow.toUpperCase(),
                              style: TextStyle(
                                color: accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.45,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              title,
                              style: const TextStyle(
                                color: fieldGray900,
                                fontSize: 21,
                                height: 1.12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  message,
                  style: const TextStyle(
                    color: fieldGray600,
                    fontSize: 14,
                    height: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detail case final detail?
                    when detail.trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    key: const ValueKey('field-confirmation-detail'),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: accentSurface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: accentBorder),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          destructive
                              ? Icons.info_outline_rounded
                              : Icons.check_circle_outline_rounded,
                          color: accent,
                          size: 19,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            detail,
                            style: TextStyle(
                              color: destructive
                                  ? const Color(0xFF991B1B)
                                  : fieldEmerald800,
                              fontSize: 12,
                              height: 1.35,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('field-confirmation-cancel'),
                        onPressed: () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: fieldGray700,
                          side: const BorderSide(color: fieldGray200),
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        child: Text(cancelLabel),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('field-confirmation-confirm'),
                        onPressed: confirmEnabled
                            ? () => Navigator.of(context).pop(true)
                            : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          disabledBackgroundColor: fieldGray200,
                          disabledForegroundColor: fieldGray400,
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        child: Text(confirmLabel),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
