import 'date_of_birth.dart';

const fieldrushTermsVersion = 'fieldrush-v1';
const fieldrushPrivacyVersion = 'fieldrush-v1';

/// An onboarding answer, not a client-selected rating. The server owns the
/// one-time seed for both rating pools and preserves established ratings.
enum SkillAssessment {
  beginner(
    'beginner',
    'Beginner',
    'I’m still learning the basics of passing, controlling the ball, and positioning.',
  ),
  casual(
    'casual',
    'Casual',
    'I know the game and can make simple passes and control the ball with space, but I’m less consistent under pressure.',
  ),
  intermediate(
    'intermediate',
    'Intermediate',
    'I’m comfortable receiving and passing under pressure, understand my position, and contribute consistently.',
  ),
  advanced(
    'advanced',
    'Advanced',
    'I can play at a quick pace, make good decisions under pressure, and hold my own in competitive games.',
  ),
  highlyCompetitive(
    'highly_competitive',
    'Highly competitive',
    'I consistently perform well in strong competitive games, with reliable technique, positioning, and decision-making at speed.',
  ),
  notSure('not_sure', 'Not sure', 'I’d like my games to help find my level.');

  const SkillAssessment(this.value, this.label, this.description);

  final String value;
  final String label;
  final String description;

  static SkillAssessment? fromJson(Object? value) {
    // Accounts created before self-assessment have no answer. In particular,
    // this must not force established players through onboarding again.
    if (value == null) return null;
    for (final assessment in values) {
      if (assessment.value == value) return assessment;
    }
    throw const FormatException('Unknown skill assessment.');
  }
}

class AccountDraft {
  const AccountDraft({
    this.firstName = '',
    this.lastName = '',
    this.username = '',
    this.dateOfBirth,
    this.email = '',
    this.skillAssessment,
  });

  final String firstName;
  final String lastName;
  final String username;
  final DateTime? dateOfBirth;
  final String email;
  final SkillAssessment? skillAssessment;

  AccountDraft copyWith({
    String? firstName,
    String? lastName,
    String? username,
    DateTime? dateOfBirth,
    String? email,
    SkillAssessment? skillAssessment,
  }) => AccountDraft(
    firstName: firstName ?? this.firstName,
    lastName: lastName ?? this.lastName,
    username: username ?? this.username,
    dateOfBirth: dateOfBirth ?? this.dateOfBirth,
    email: email ?? this.email,
    skillAssessment: skillAssessment ?? this.skillAssessment,
  );

  Map<String, dynamic> toJson() => {
    'first_name': firstName.trim(),
    'last_name': lastName.trim(),
    'username': username.trim().toLowerCase(),
    'date_of_birth': dateOfBirth == null
        ? null
        : dateOfBirthToIso(dateOfBirth!),
    'email': email.trim(),
    if (skillAssessment != null) 'skill_assessment': skillAssessment!.value,
  };

  factory AccountDraft.fromJson(Map<String, dynamic> json) => AccountDraft(
    firstName: json['first_name'] as String? ?? '',
    lastName: json['last_name'] as String? ?? '',
    username: json['username'] as String? ?? '',
    dateOfBirth: parseDateOfBirth(json['date_of_birth']),
    email: json['email'] as String? ?? '',
    skillAssessment: SkillAssessment.fromJson(json['skill_assessment']),
  );
}

class FieldrushAccount {
  const FieldrushAccount({
    required this.draft,
    this.phone = '',
    this.phoneVerified = false,
    this.emailVerified = false,
    this.googleLinked = false,
    this.googleEmail,
    this.completed = false,
    this.tourCompleted = false,
    this.status = 'onboarding',
    this.homeCity,
    this.rankingRegion,
    this.homeCityLocked = true,
    this.preferredCityId,
    this.marketTimezone,
    this.skillAssessmentRequired = false,
    this.ratingInitialized = false,
  });

  final AccountDraft draft;
  final String phone;
  final bool phoneVerified;
  final bool emailVerified;
  final bool googleLinked;

  /// Verified Google identity address, supplied by the server rather than
  /// client-editable profile metadata. Null when no trusted address is linked.
  final String? googleEmail;
  final bool completed;
  final bool tourCompleted;
  final String status;

  /// Server-owned market. Null means the server has not supplied this contract.
  final String? homeCity;
  final String? rankingRegion;
  final bool homeCityLocked;
  final String? preferredCityId;
  final String? marketTimezone;

  /// Server-owned gate. Legacy accounts must never be prompted to reseed.
  final bool skillAssessmentRequired;
  final bool ratingInitialized;

  bool get deletionPending =>
      status == 'deletion_pending' || status == 'deleted';

  factory FieldrushAccount.fromJson(Map<String, dynamic> json) =>
      FieldrushAccount(
        draft: AccountDraft.fromJson(json),
        phone: json['phone'] as String? ?? '',
        phoneVerified: json['phone_verified'] == true,
        emailVerified: json['email_verified'] == true,
        googleLinked: json['google_linked'] == true,
        googleEmail: json['google_email'] as String?,
        completed: json['onboarding_completed'] == true,
        tourCompleted: json['tour_completed'] == true,
        status: json['status'] as String? ?? 'onboarding',
        homeCity: json['home_city'] as String?,
        rankingRegion: json['ranking_region'] as String?,
        homeCityLocked: json['home_city_locked'] != false,
        preferredCityId: json['preferred_city_id'] as String?,
        marketTimezone: json['market_timezone'] as String?,
        skillAssessmentRequired: json['skill_assessment_required'] == true,
        ratingInitialized: json['rating_initialized'] == true,
      );
}

class UsernameAvailability {
  const UsernameAvailability({required this.available, this.message = ''});
  final bool available;
  final String message;
}

/// Auth accepted the one-time email code, but its follow-up status read could
/// not complete. Retry a status read, never the already-consumed code. This is
/// not proof of verification, including for requests created under an older
/// two-inbox policy. New requests require only the code in the new inbox.
class EmailVerificationStatusUnavailableException implements Exception {
  const EmailVerificationStatusUnavailableException();
}

/// A freshly read Google identity makes this an explicit sign-in-method change,
/// even if the caller's account screen was loaded before Google was linked.
class GoogleEmailChangeConfirmationRequiredException implements Exception {
  const GoogleEmailChangeConfirmationRequiredException();
}

/// Google may only be disconnected while a confirmed phone identity remains.
class GoogleEmailChangeRequiresPhoneException implements Exception {
  const GoogleEmailChangeRequiresPhoneException();
}

/// Auth confirmed the unlink request, but the subsequent account update could
/// not be confirmed. Reload the account before offering another action; never
/// report that both operations rolled back or that the new email was saved.
class GoogleDisconnectedEmailUpdateException implements Exception {
  const GoogleDisconnectedEmailUpdateException();
}

/// The unlink response was lost or unavailable. Refresh canonical Auth/account
/// state before another attempt; neither "still linked" nor "disconnected" is
/// established by a transport failure alone.
class GoogleEmailChangeStatusUnavailableException implements Exception {
  const GoogleEmailChangeStatusUnavailableException();
}

abstract class FieldrushAccountRepository {
  bool get emailDeliveryEnabled;
  Future<FieldrushAccount> loadAccount();
  Future<void> saveDraft(AccountDraft draft);
  Future<FieldrushAccount> completeOnboarding(AccountDraft draft);
  Future<UsernameAvailability> checkUsername(String username);
  Future<void> signInWithGoogle();
  Future<void> linkGoogle();
  Future<void> sendPhoneCode(String phone);

  /// Explicitly leaves an unfinished, phone-only signup before requesting an
  /// SMS login for another number. Never changes or deletes the old account.
  Future<void> switchIncompletePhoneAccount(String phone);
  Future<void> sendRecoveryCode(String phone);
  Future<void> verifyPhoneCode(String phone, String token);
  Future<void> sendReauthenticationCode();
  Future<void> verifyReauthenticationCode(String token);
  Future<void> requestEmailVerification(String email);
  Future<void> verifyEmailCode(String email, String token);
  Future<FieldrushAccount> updateAccount(
    AccountDraft draft, {
    bool disconnectGoogle = false,
  });
  Future<void> markTourCompleted();
  Future<void> deleteAccount();
}

String? validateFieldrushName(String value) {
  final name = value.trim();
  if (name.isEmpty) return 'Enter your name.';
  if (name.runes.length > 50) return 'Use 50 characters or fewer.';
  if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(name)) return 'Enter a valid name.';
  return null;
}

String? validateFieldrushUsername(String value) {
  if (!RegExp(r'^[a-z0-9._]{3,20}$').hasMatch(value)) {
    return 'Use 3–20 letters, numbers, dots or underscores.';
  }
  if (RegExp(r'^[._]|[._]$|[._]{2}').hasMatch(value)) {
    return 'No leading, trailing or consecutive dots or underscores.';
  }
  return null;
}

bool isFieldrushEmail(String value) =>
    value.trim().length <= 254 &&
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim());
