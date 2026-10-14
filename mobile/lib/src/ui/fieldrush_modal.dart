import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';

/// Opens app-owned sheets with the Fieldrush scrim, theme and motion.
Future<T?> showFieldrushModal<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool dismissible = true,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  isDismissible: dismissible,
  enableDrag: dismissible,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0x85172415),
  builder: (context) => Theme(
    data: FieldrushModal.theme(context),
    child: Builder(builder: builder),
  ),
);

/// Shared cream surface, heading and stacked actions from the reference HTML.
/// The body scrolls so keyboards, small phones and large text never hide the
/// verification field or final action. Native OS/payment sheets stay native.
class FieldrushModal extends StatelessWidget {
  const FieldrushModal({
    super.key,
    required this.title,
    this.description,
    this.eyebrow,
    this.headerAction,
    this.content,
    this.actions = const [],
  });

  final String title;
  final String? description;
  final String? eyebrow;
  final Widget? headerAction;
  final Widget? content;
  final List<Widget> actions;

  static const titleStyle = TextStyle(
    fontFamily: 'Outfit',
    color: FieldrushAuthTheme.ink,
    fontSize: 19,
    fontWeight: FontWeight.w800,
    height: 1.15,
    letterSpacing: -.38,
  );
  static const bodyStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    color: FieldrushAuthTheme.muted,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.5,
  );

  static ThemeData theme(BuildContext context) {
    final base = FieldrushAuthTheme.theme(context);
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: FieldrushAuthTheme.border),
    );
    return base.copyWith(
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(
          borderSide: const BorderSide(
            color: FieldrushAuthTheme.forest,
            width: 2,
          ),
        ),
        errorBorder: outline.copyWith(
          borderSide: const BorderSide(color: FieldrushAuthTheme.danger),
        ),
        focusedErrorBorder: outline.copyWith(
          borderSide: const BorderSide(
            color: FieldrushAuthTheme.danger,
            width: 2,
          ),
        ),
        labelStyle: bodyStyle,
        hintStyle: bodyStyle,
        errorStyle: bodyStyle.copyWith(color: FieldrushAuthTheme.danger),
        errorMaxLines: 3,
      ),
      filledButtonTheme: FilledButtonThemeData(style: primaryButtonStyle()),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: secondaryButtonStyle(),
      ),
    );
  }

  static ButtonStyle primaryButtonStyle({bool destructive = false}) =>
      FilledButton.styleFrom(
        backgroundColor: destructive
            ? FieldrushAuthTheme.danger
            : FieldrushAuthTheme.forest,
        foregroundColor: Colors.white,
        disabledBackgroundColor: FieldrushAuthTheme.border,
        disabledForegroundColor: FieldrushAuthTheme.muted,
        minimumSize: const Size.fromHeight(50),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        textStyle: bodyStyle.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w800,
        ),
      );

  static ButtonStyle secondaryButtonStyle({bool destructive = false}) =>
      OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: destructive
            ? FieldrushAuthTheme.danger
            : FieldrushAuthTheme.ink,
        minimumSize: const Size.fromHeight(46),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        side: const BorderSide(color: FieldrushAuthTheme.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: bodyStyle.copyWith(
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    return Theme(
      data: theme(context),
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: keyboard),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (media.size.height - media.padding.top - keyboard - 16)
                .clamp(0.0, media.size.height),
          ),
          child: Material(
            color: FieldrushAuthTheme.cream,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 26),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: DefaultTextStyle(
                  style: bodyStyle,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          key: const ValueKey('fieldrush-modal-handle'),
                          width: 38,
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0xFFDED8C6),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (eyebrow case final label?) ...[
                              Text(
                                label.toUpperCase(),
                                style: bodyStyle.copyWith(
                                  fontSize: 10,
                                  letterSpacing: 1.2,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 7),
                            ],
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: Text(title, style: titleStyle)),
                                if (headerAction case final action?) action,
                              ],
                            ),
                            if (description case final text?) ...[
                              const SizedBox(height: 9),
                              Text(text, style: bodyStyle),
                            ],
                          ],
                        ),
                      ),
                      if (content case final body?) ...[
                        const SizedBox(height: 16),
                        body,
                      ],
                      if (actions.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        for (
                          var index = 0;
                          index < actions.length;
                          index++
                        ) ...[
                          if (index > 0) const SizedBox(height: 9),
                          actions[index],
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
