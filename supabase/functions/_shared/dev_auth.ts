import { isExactFieldStagingSupabaseUrl } from "./staging_guard.ts";

export type DevAuthEnvironment = (name: string) => string | undefined;
export type DevAuthUser = {
  id: string;
  phone?: string;
  email?: string;
  email_confirmed_at?: string | null;
  deleted_at?: string | null;
  banned_until?: string | null;
  app_metadata?: Record<string, unknown>;
};
export const E2E_STAFF_EMAIL = "field_e2e_staff@fieldrush-e2e.example";
export type DevAuthWindow = {
  runId: string;
  password: string;
  secret: string;
  expiresAt: number;
};

export function stagingDevAuthWindow(
  env: DevAuthEnvironment,
  now: number,
): DevAuthWindow | null {
  if (!isExactFieldStagingSupabaseUrl(env("SUPABASE_URL"))) return null;
  if (env("DEV") !== "true" || env("DEV_OTP_ENABLED") !== "true") return null;
  const runId = env("DEV_AUTH_RUN_ID") ?? "";
  const secret = env("DEV_AUTH_SECRET") ?? "";
  const password = env("DEV_OTP_PASSWORD") ?? "";
  const expiry = env("DEV_AUTH_VALID_UNTIL") ?? "";
  const expiresAt = Date.parse(expiry);
  if (
    !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(runId) ||
    !/^[\x21-\x7e]{32,256}$/.test(secret) ||
    !/^[\x21-\x7e]{32,256}$/.test(password) ||
    !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{3})?Z$/.test(expiry) ||
    !Number.isFinite(expiresAt) ||
    new Date(expiresAt).toISOString() !== expiry ||
    expiresAt <= now || expiresAt - now > 2 * 60 * 60 * 1000
  ) return null;
  return { runId, secret, password, expiresAt };
}

export async function matchesDevAuthSecret(
  supplied: string | null,
  expected: string,
): Promise<boolean> {
  if (!supplied || supplied.length > 256) return false;
  const digest = async (value: string) =>
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    );
  const [left, right] = await Promise.all([digest(supplied), digest(expected)]);
  let difference = 0;
  for (let i = 0; i < left.length; i++) difference |= left[i] ^ right[i];
  return difference === 0;
}

export function isCurrentRunFixture(
  user: DevAuthUser | null | undefined,
  runId: string,
  now: number,
): user is DevAuthUser {
  if (
    !user || user.deleted_at ||
    (user.banned_until && Date.parse(user.banned_until) > now)
  ) return false;
  const metadata = user.app_metadata;
  const role = metadata?.fieldrush_e2e_role;
  const phone = user.phone?.replace(/\D/g, "");
  if (role === "admin") {
    return metadata?.fieldrush_e2e === true &&
      metadata.fieldrush_e2e_run_id === runId &&
      metadata.fieldrush_account_type === "staff" && !user.phone &&
      user.email === E2E_STAFF_EMAIL && Boolean(user.email_confirmed_at);
  }
  if (metadata?.fieldrush_account_type === "staff") return false;
  const expectedPhone = role === "bootstrap"
    ? phone === "97339009098"
    : role === "onboarding"
    ? phone === "97339009100"
    : role === "player"
    ? /^973390090(?:0[1-9]|1[0-4])$/.test(phone ?? "")
    : false;
  return metadata?.fieldrush_e2e === true &&
    metadata.fieldrush_e2e_run_id === runId && expectedPhone;
}
