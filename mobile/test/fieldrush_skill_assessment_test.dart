import 'package:field/src/auth/fieldrush_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'all six allowed assessment choices round-trip without numeric authority',
    () {
      expect(SkillAssessment.values.map((choice) => choice.value), [
        'beginner',
        'casual',
        'intermediate',
        'advanced',
        'highly_competitive',
        'not_sure',
      ]);
      for (final choice in SkillAssessment.values) {
        final draft = AccountDraft(skillAssessment: choice);
        final json = draft.toJson();
        expect(json['skill_assessment'], choice.value);
        expect(AccountDraft.fromJson(json).skillAssessment, choice);
        expect(
          draft.copyWith(email: 'new@example.com').skillAssessment,
          choice,
        );
        expect(json.values.whereType<num>(), isEmpty);
      }
    },
  );

  test('unknown or numeric assessment values are rejected', () {
    for (final value in ['expert', 'BEGINNER', '', 1200, true, <String>[]]) {
      expect(
        () => AccountDraft.fromJson({'skill_assessment': value}),
        throwsFormatException,
      );
    }
  });

  test(
    'legacy account JSON preserves completed state without requiring reseeding',
    () {
      final account = FieldrushAccount.fromJson({
        'onboarding_completed': true,
        'phone_verified': true,
      });
      expect(account.completed, isTrue);
      expect(account.draft.skillAssessment, isNull);
      expect(account.skillAssessmentRequired, isFalse);
      expect(account.draft.toJson(), isNot(contains('skill_assessment')));
    },
  );

  test(
    'server-owned assessment requirement and initialized state are retained',
    () {
      final account = FieldrushAccount.fromJson({
        'skill_assessment': 'not_sure',
        'skill_assessment_required': true,
        'rating_initialized': false,
      });
      expect(account.draft.skillAssessment, SkillAssessment.notSure);
      expect(account.skillAssessmentRequired, isTrue);
      expect(account.ratingInitialized, isFalse);
    },
  );
}
