import 'package:flutter/material.dart';

import 'fieldrush_account.dart';
import 'fieldrush_auth_theme.dart';

/// The level step from Fieldrush App(5).html. Skip records the existing
/// `not_sure` answer; the server still owns initialization and the seed.
class FieldrushSkillAssessmentStep extends StatelessWidget {
  const FieldrushSkillAssessmentStep({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.onBack,
    required this.onSkip,
    required this.onContinue,
    required this.stepNumber,
    required this.stepCount,
    this.busy = false,
    this.error,
    this.notice,
    this.controller,
  });

  final SkillAssessment? selected;
  final ValueChanged<SkillAssessment> onSelected;
  final VoidCallback onBack, onSkip, onContinue;
  final int stepNumber, stepCount;
  final bool busy;
  final String? error, notice;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: LayoutBuilder(
      builder: (context, constraints) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            controller: controller,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 26),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Semantics(
                            button: true,
                            label: 'Back',
                            child: InkWell(
                              key: const Key('fieldrush-back'),
                              onTap: busy ? null : onBack,
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: Border.all(
                                    color: FieldrushAuthTheme.border,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  '‹',
                                  style: TextStyle(
                                    fontFamily: 'PlusJakartaSans',
                                    fontSize: 15,
                                    height: 1,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF3C4A38),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Semantics(
                              label:
                                  'Account setup, step $stepNumber of $stepCount',
                              child: Row(
                                children: [
                                  for (var i = 0; i < stepCount; i++) ...[
                                    if (i > 0) const SizedBox(width: 4),
                                    Expanded(
                                      child: Container(
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: i < stepNumber
                                              ? FieldrushAuthTheme.forest
                                              : FieldrushAuthTheme.border,
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          TextButton(
                            key: const Key('fieldrush-skill-skip'),
                            onPressed: busy ? null : onSkip,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 36),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              textStyle: const TextStyle(
                                fontFamily: 'PlusJakartaSans',
                                fontSize: 12.5,
                                height: 1,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            child: const Text('Skip'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 40),
                      const Text(
                        'What’s your\nlevel?',
                        key: Key('fieldrush-skill-title'),
                        style: TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 44,
                          height: .98,
                          letterSpacing: -1.76,
                          fontWeight: FontWeight.w800,
                          color: FieldrushAuthTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'So your first games are fair.',
                        style: TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 13,
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                          color: FieldrushAuthTheme.muted,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Container(height: 2.5, color: FieldrushAuthTheme.ink),
                      for (final assessment in SkillAssessment.values.where(
                        (value) => value != SkillAssessment.notSure,
                      ))
                        _LevelRow(
                          assessment: assessment,
                          selected: selected == assessment,
                          divider: assessment != SkillAssessment.beginner,
                          onTap: busy ? null : () => onSelected(assessment),
                        ),
                      if (error != null || notice != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              error ?? notice!,
                              style: TextStyle(
                                fontFamily: 'PlusJakartaSans',
                                fontSize: 12,
                                height: 1.45,
                                color: error != null
                                    ? FieldrushAuthTheme.danger
                                    : FieldrushAuthTheme.muted,
                              ),
                            ),
                          ),
                        ),
                      const Spacer(),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const Key('fieldrush-continue'),
                        onPressed: busy || selected == null ? null : onContinue,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 52),
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          disabledBackgroundColor: const Color(0xFFE6DFCB),
                          disabledForegroundColor: const Color(0xFF8E897A),
                          textStyle: const TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: 14,
                            height: 1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        child: Text(busy ? 'Please wait…' : 'Continue'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _LevelRow extends StatelessWidget {
  const _LevelRow({
    required this.assessment,
    required this.selected,
    required this.divider,
    required this.onTap,
  });
  final SkillAssessment assessment;
  final bool selected, divider;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    inMutuallyExclusiveGroup: true,
    button: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: divider
            ? const Border(top: BorderSide(color: FieldrushAuthTheme.border))
            : null,
      ),
      child: InkWell(
        key: Key('fieldrush-skill-${assessment.value}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      assessment.label,
                      style: TextStyle(
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        height: 1.15,
                        letterSpacing: -.17,
                        color: selected
                            ? FieldrushAuthTheme.forest
                            : FieldrushAuthTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      assessment.description,
                      style: const TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontWeight: FontWeight.w600,
                        fontSize: 11.5,
                        height: 1.4,
                        color: FieldrushAuthTheme.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? FieldrushAuthTheme.forest : null,
                  border: selected
                      ? null
                      : Border.all(color: const Color(0xFFCFC8B4), width: 2),
                ),
                child: selected
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CustomPaint(painter: _LevelCheckPainter()),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _LevelCheckPainter extends CustomPainter {
  const _LevelCheckPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(2, 6)
        ..lineTo(5, 9)
        ..lineTo(10, 3),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _LevelCheckPainter oldDelegate) => false;
}
