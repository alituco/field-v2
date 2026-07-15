import 'package:supabase_flutter/supabase_flutter.dart';

import 'date_of_birth.dart';

enum OnboardingRequirement { displayName, dateOfBirth, complete }

OnboardingRequirement onboardingRequirementForMetadata(
  Map<String, dynamic>? metadata, {
  DateTime? today,
}) {
  if (!_hasValidDisplayName(metadata)) {
    return OnboardingRequirement.displayName;
  }

  final dateOfBirth = parseDateOfBirth(metadata?['date_of_birth']);
  if (dateOfBirth == null ||
      !isEligibleDateOfBirth(dateOfBirth, today: today)) {
    return OnboardingRequirement.dateOfBirth;
  }

  return OnboardingRequirement.complete;
}

OnboardingRequirement onboardingRequirementForUser(
  User? user, {
  DateTime? today,
}) => onboardingRequirementForMetadata(user?.userMetadata, today: today);

bool _hasValidDisplayName(Map<String, dynamic>? metadata) {
  final displayName = metadata?['display_name'];
  if (displayName is String && displayName.trim().length >= 2) {
    return true;
  }

  final fallbackName = metadata?['name'];
  return fallbackName is String && fallbackName.trim().length >= 2;
}
