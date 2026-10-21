import 'package:supabase_flutter/supabase_flutter.dart';

const staffAccountOnlyMessage =
    'This is a staff-only account. Use your player account in the app and your staff email on the referee website.';

bool isStaffIdentity(User? user) =>
    user?.appMetadata['fieldrush_account_type'] == 'staff';

/// The account realm is server-owned app metadata, never editable user metadata.
/// Server authorization remains authoritative for every player operation.
Future<void> requirePlayerIdentity(
  SupabaseClient client, {
  User? authenticatedUser,
}) async {
  final user = isStaffIdentity(authenticatedUser)
      ? authenticatedUser
      : client.auth.currentUser;
  if (!isStaffIdentity(user)) return;
  if (client.auth.currentUser?.id == user!.id &&
      isStaffIdentity(client.auth.currentUser)) {
    try {
      await client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      // Refuse player operations even if session cleanup needs another attempt.
    }
  }
  throw const AuthException(
    staffAccountOnlyMessage,
    code: 'staff_account_only',
  );
}
