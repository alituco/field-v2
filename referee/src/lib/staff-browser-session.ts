import type { Session } from "@supabase/supabase-js";

export const STAFF_SIGN_IN_REQUIRED = "Use your dedicated staff email to sign in. Player phone and Google accounts cannot access staff tools. Ask an administrator to set up your staff email if needed.";

export function isStaffBrowserSession(session: Session | null): session is Session {
  return session?.user.app_metadata?.fieldrush_account_type === "staff";
}

export function staffStorageKey(supabaseUrl: string): string {
  return `fieldrush-staff-${new URL(supabaseUrl).hostname}-auth-v1`;
}
