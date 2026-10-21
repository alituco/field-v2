import type { SupabaseClient } from "@supabase/supabase-js";

export const STAFF_ACCOUNT_TYPE = "staff";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
type StaffAuthIdentity = { id: string; email?: string | null; email_confirmed_at?: string | null;
  phone?: string | null; app_metadata?: Record<string, unknown>; deleted_at?: string | null; banned_until?: string | null };
export class StaffIdentityError extends Error {}

export function normalizeStaffEmail(value: unknown): string {
  const email = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || /[\u0000-\u001f\u007f]/.test(email)) {
    throw new StaffIdentityError("Enter a valid dedicated staff email.");
  }
  return email;
}

/** Only service-owned app metadata establishes the staff authentication realm. */
export function isStaffAuthIdentity(user: StaffAuthIdentity | null | undefined, requireVerifiedEmail = false): boolean {
  if (!user || user.app_metadata?.fieldrush_account_type !== STAFF_ACCOUNT_TYPE || user.phone || user.deleted_at) return false;
  if (user.banned_until && Date.parse(user.banned_until) > Date.now()) return false;
  try { normalizeStaffEmail(user.email); } catch { return false; }
  return !requireVerifiedEmail || typeof user.email_confirmed_at === "string" && Number.isFinite(Date.parse(user.email_confirmed_at));
}

export function parseStaffInput(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new StaffIdentityError("Provide valid staff details.");
  const body = value as Record<string, unknown>;
  if ("password" in body || "resetPassword" in body) throw new StaffIdentityError("Staff sign-in uses an email code. Adding staff never resets a password.");
  if (Object.keys(body).some(key => !["displayName", "email", "role", "sendOtp", "existingStaffProfileId"].includes(key))) {
    throw new StaffIdentityError("Unknown staff field. Use a dedicated staff email instead of a player phone number.");
  }
  const displayName = typeof body.displayName === "string" ? body.displayName.trim() : "";
  if (displayName.length < 2 || displayName.length > 50 || /[\u0000-\u001f\u007f]/.test(displayName)) throw new StaffIdentityError("Use a staff name of 2 to 50 characters.");
  const email = normalizeStaffEmail(body.email);
  if (body.role !== undefined && body.role !== "admin" && body.role !== "referee") throw new StaffIdentityError("Choose admin or referee access.");
  if (body.sendOtp !== undefined && typeof body.sendOtp !== "boolean") throw new StaffIdentityError("Choose whether to send a login code.");
  const existingStaffProfileId = body.existingStaffProfileId ?? null;
  if (existingStaffProfileId !== null && (typeof existingStaffProfileId !== "string" || !UUID.test(existingStaffProfileId))) {
    throw new StaffIdentityError("Choose the exact existing staff record to migrate.");
  }
  return { displayName, email, role: body.role === "admin" ? "admin" as const : "referee" as const,
    sendOtp: body.sendOtp !== false, existingStaffProfileId };
}

/** An email collision never promotes, edits, resets, or deletes a player. */
export async function resolveStaffAuthIdentity(db: SupabaseClient, email: string, displayName: string) {
  const existing = await findAuthUserByEmail(db, email);
  if (existing) return { userId: requireDedicatedIdentity(existing, email), accountCreated: false };
  const { data, error } = await db.auth.admin.createUser({ email, email_confirm: false,
    app_metadata: { fieldrush_account_type: STAFF_ACCOUNT_TYPE }, user_metadata: { display_name: displayName } });
  if (!error && data.user) return { userId: requireDedicatedIdentity(data.user, email), accountCreated: true };
  // Auth may commit before a response fails, or another invitation may win.
  // Only the independently marked staff identity may be reused on retry.
  const winner = await findAuthUserByEmail(db, email);
  if (winner) return { userId: requireDedicatedIdentity(winner, email), accountCreated: false };
  throw new StaffIdentityError("Could not create the independent staff sign-in. No staff access was granted. Try again.");
}

async function findAuthUserByEmail(db: SupabaseClient, email: string) {
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    const match = data.users.find(user => user.email?.trim().toLowerCase() === email);
    if (match) return match;
    if (data.users.length < 1000) return null;
  }
  throw new StaffIdentityError("The account directory could not be searched completely. No account was changed. Contact support.");
}

function requireDedicatedIdentity(user: StaffAuthIdentity, email: string) {
  if (!isStaffAuthIdentity(user) || normalizeStaffEmail(user.email) !== email) {
    throw new StaffIdentityError("That email is already used by another account. Choose a dedicated staff email or alias; player accounts cannot become staff accounts.");
  }
  return user.id;
}

export function serializeGrantedStaff(value: unknown, userId: string, email: string, role: string, existingStaffProfileId: string | null) {
  const result = value as { staff?: Record<string, unknown> } | null;
  const staff = result?.staff;
  if (!staff || typeof staff.profile_id !== "string" || !UUID.test(staff.profile_id) || staff.auth_user_id !== userId ||
    staff.email !== email || staff.role !== role || staff.is_active !== true || typeof staff.display_name !== "string" ||
    (existingStaffProfileId !== null && staff.profile_id !== existingStaffProfileId)) {
    throw new StaffIdentityError("Staff access could not be confirmed. Refresh the staff directory before trying again.");
  }
  return { profileId: staff.profile_id, displayName: staff.display_name, email, role, isActive: true,
    phone: typeof staff.phone === "string" ? staff.phone : "", hasIndependentLogin: true, setupRequired: false };
}

export function staffProvisioningError(error: unknown) {
  if (error instanceof StaffIdentityError) return error.message;
  const code = (error as { code?: unknown } | null)?.code;
  if (code === "42501") return "Active administrator access is required. Refresh and sign in again.";
  if (code === "22023" || code === "23505") return "Staff access was not changed. Check the dedicated email, account status and existing staff record.";
  if (["PGRST202", "PGRST204", "42883", "42703"].includes(String(code))) return "Independent staff sign-in is unavailable until the latest database migration is deployed.";
  return "Staff access could not be confirmed. Refresh the staff directory before trying again. Player accounts were not changed.";
}
