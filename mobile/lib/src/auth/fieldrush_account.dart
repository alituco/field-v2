import 'date_of_birth.dart';

const fieldrushTermsVersion = 'fieldrush-v1';
const fieldrushPrivacyVersion = 'fieldrush-v1';

class AccountDraft {
  const AccountDraft({
    this.firstName = '',
    this.lastName = '',
    this.username = '',
    this.dateOfBirth,
    this.email = '',
  });

  final String firstName;
  final String lastName;
  final String username;
  final DateTime? dateOfBirth;
  final String email;

  AccountDraft copyWith({
    String? firstName,
    String? lastName,
    String? username,
    DateTime? dateOfBirth,
    String? email,
  }) => AccountDraft(
    firstName: firstName ?? this.firstName,
    lastName: lastName ?? this.lastName,
    username: username ?? this.username,
    dateOfBirth: dateOfBirth ?? this.dateOfBirth,
    email: email ?? this.email,
  );

  Map<String, dynamic> toJson() => {
    'first_name': firstName.trim(),
    'last_name': lastName.trim(),
    'username': username.trim().toLowerCase(),
    'date_of_birth': dateOfBirth == null
        ? null
        : dateOfBirthToIso(dateOfBirth!),
    'email': email.trim(),
  };

  factory AccountDraft.fromJson(Map<String, dynamic> json) => AccountDraft(
    firstName: json['first_name'] as String? ?? '',
    lastName: json['last_name'] as String? ?? '',
    username: json['username'] as String? ?? '',
    dateOfBirth: parseDateOfBirth(json['date_of_birth']),
    email: json['email'] as String? ?? '',
  );
}

class FieldrushAccount {
  const FieldrushAccount({
    required this.draft,
    this.phone = '',
    this.phoneVerified = false,
    this.emailVerified = false,
    this.googleLinked = false,
    this.completed = false,
    this.tourCompleted = false,
    this.status = 'onboarding',
    this.homeCity,
    this.rankingRegion,
    this.homeCityLocked = true,
  });

  final AccountDraft draft;
  final String phone;
  final bool phoneVerified;
  final bool emailVerified;
  final bool googleLinked;
  final bool completed;
  final bool tourCompleted;
  final String status;

  /// Server-owned market. Null means the server has not supplied this contract.
  final String? homeCity;
  final String? rankingRegion;
  final bool homeCityLocked;

  bool get deletionPending =>
      status == 'deletion_pending' || status == 'deleted';

  factory FieldrushAccount.fromJson(Map<String, dynamic> json) =>
      FieldrushAccount(
        draft: AccountDraft.fromJson(json),
        phone: json['phone'] as String? ?? '',
        phoneVerified: json['phone_verified'] == true,
        emailVerified: json['email_verified'] == true,
        googleLinked: json['google_linked'] == true,
        completed: json['onboarding_completed'] == true,
        tourCompleted: json['tour_completed'] == true,
        status: json['status'] as String? ?? 'onboarding',
        homeCity: json['home_city'] as String?,
        rankingRegion: json['ranking_region'] as String?,
        homeCityLocked: json['home_city_locked'] != false,
      );
}

class UsernameAvailability {
  const UsernameAvailability({required this.available, this.message = ''});
  final bool available;
  final String message;
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
  Future<void> sendRecoveryCode(String phone);
  Future<void> verifyPhoneCode(String phone, String token);
  Future<void> sendReauthenticationCode();
  Future<void> verifyReauthenticationCode(String token);
  Future<void> requestEmailVerification(String email);
  Future<void> verifyEmailCode(String email, String token);
  Future<FieldrushAccount> updateAccount(AccountDraft draft);
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
