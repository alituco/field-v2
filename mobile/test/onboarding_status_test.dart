import 'package:field/src/auth/onboarding_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final today = DateTime(2026, 7, 15);

  group('onboardingRequirementForMetadata', () {
    test('requires a display name when metadata or name is missing', () {
      expect(
        onboardingRequirementForMetadata(null, today: today),
        OnboardingRequirement.displayName,
      );
      expect(
        onboardingRequirementForMetadata(const {}, today: today),
        OnboardingRequirement.displayName,
      );
    });

    test('requires a display name when every available name is too short', () {
      expect(
        onboardingRequirementForMetadata(const {
          'display_name': ' A ',
          'name': ' ',
          'date_of_birth': '2000-01-01',
        }, today: today),
        OnboardingRequirement.displayName,
      );
    });

    test('accepts the name metadata fallback', () {
      expect(
        onboardingRequirementForMetadata(const {
          'display_name': '',
          'name': 'Ali',
          'date_of_birth': '2000-01-01',
        }, today: today),
        OnboardingRequirement.complete,
      );
    });

    test('requires date of birth when it is absent or malformed', () {
      expect(
        onboardingRequirementForMetadata(const {
          'display_name': 'Ali',
        }, today: today),
        OnboardingRequirement.dateOfBirth,
      );
      expect(
        onboardingRequirementForMetadata(const {
          'display_name': 'Ali',
          'date_of_birth': 'not-a-date',
        }, today: today),
        OnboardingRequirement.dateOfBirth,
      );
    });

    test('requires date of birth when the player is under 18', () {
      expect(
        onboardingRequirementForMetadata(const {
          'display_name': 'Ali',
          'date_of_birth': '2008-07-16',
        }, today: today),
        OnboardingRequirement.dateOfBirth,
      );
    });

    test('is complete on the exact eighteenth birthday', () {
      expect(
        onboardingRequirementForMetadata(const {
          'display_name': 'Ali',
          'date_of_birth': '2008-07-15',
        }, today: today),
        OnboardingRequirement.complete,
      );
    });

    test('is complete with a valid name and eligible date of birth', () {
      expect(
        onboardingRequirementForMetadata(const {
          'display_name': 'Ali Altaraif',
          'date_of_birth': '2000-01-01',
        }, today: today),
        OnboardingRequirement.complete,
      );
    });
  });

  group('onboardingRequirementForUser', () {
    test('requires a display name for a missing user', () {
      expect(
        onboardingRequirementForUser(null, today: today),
        OnboardingRequirement.displayName,
      );
    });

    test('uses the authenticated user metadata', () {
      const user = User(
        id: 'ali-id',
        appMetadata: {},
        userMetadata: {
          'display_name': 'Ali Altaraif',
          'date_of_birth': '2000-01-01',
        },
        aud: 'authenticated',
        createdAt: '2026-06-07T00:00:00Z',
      );

      expect(
        onboardingRequirementForUser(user, today: today),
        OnboardingRequirement.complete,
      );
    });
  });
}
