import { NextRequest, NextResponse } from "next/server";
import { createSupabaseAdmin, createSupabasePublic } from "@/lib/supabase-admin";
import { isStaffAuthIdentity, normalizeStaffEmail } from "@/lib/staff-identities";

const PRIVATE_NO_STORE = { "Cache-Control": "private, no-store" };

/** Unknown, inactive, unmigrated and failed requests have the same public reply. */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const email = normalizeStaffEmail(body?.email);
    const db = createSupabaseAdmin();
    const { data: staff, error } = await db.from("referee_profiles")
      .select("auth_user_id,email,is_active").eq("email", email).eq("is_active", true).maybeSingle();
    if (error || !staff?.auth_user_id || staff.email !== email || staff.is_active !== true) {
      return NextResponse.json({ ok: true }, { headers: PRIVATE_NO_STORE });
    }
    const { data, error: identityError } = await db.auth.admin.getUserById(staff.auth_user_id);
    if (!identityError && data.user?.id === staff.auth_user_id && isStaffAuthIdentity(data.user) && normalizeStaffEmail(data.user?.email) === email) {
      await createSupabasePublic().auth.signInWithOtp({ email, options: { shouldCreateUser: false } });
    }
  } catch {
    // No account existence, provider diagnostic or invitation state is exposed.
  }
  return NextResponse.json({ ok: true }, { headers: PRIVATE_NO_STORE });
}
