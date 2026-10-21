import { NextRequest, NextResponse } from "next/server";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";
import { createSupabasePublic } from "@/lib/supabase-admin";
import { parseStaffInput, resolveStaffAuthIdentity, serializeGrantedStaff, StaffIdentityError, staffProvisioningError } from "@/lib/staff-identities";

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const { data, error } = await context.db.from("referee_profiles")
    .select("profile_id,auth_user_id,email,display_name,phone,role,is_active,created_at,updated_at")
    .order("is_active", { ascending: false }).order("display_name");
  if (error) return NextResponse.json({ error: staffProvisioningError(error) }, { status: 400 });
  return NextResponse.json({ staff: (data ?? []).map(row => ({
    profileId: row.profile_id, displayName: row.display_name, email: row.email ?? null,
    phone: row.phone ?? "", role: row.role, isActive: row.is_active,
    hasIndependentLogin: Boolean(row.auth_user_id && row.email), setupRequired: !row.auth_user_id || !row.email,
    createdAt: row.created_at, updatedAt: row.updated_at,
  })) });
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  try {
    const { displayName, email, role, sendOtp, existingStaffProfileId } = parseStaffInput(await request.json());
    if (existingStaffProfileId) {
      const { data: retained, error: retainedError } = await context.db.from("referee_profiles")
        .select("profile_id,display_name,role,is_active").eq("profile_id", existingStaffProfileId).maybeSingle();
      if (retainedError) throw retainedError;
      if (!retained || retained.is_active !== true) {
        throw new StaffIdentityError("Only active retained staff can set up an email sign-in. Inactive staff require a separate audited reactivation.");
      }
      if (retained.role !== role || retained.display_name !== displayName) {
        throw new StaffIdentityError("The retained staff identity changed. Refresh the staff directory before setup.");
      }
    }
    const { userId, accountCreated } = await resolveStaffAuthIdentity(context.db, email, displayName);
    const { data, error } = await context.db.rpc("admin_grant_independent_staff", {
      actor_admin_id: context.referee.profileId, target_auth_user_id: userId, expected_email: email,
      display_name_to_use: displayName, role_to_use: role, existing_staff_profile_id: existingStaffProfileId,
    });
    if (error) throw error;
    const staff = serializeGrantedStaff(data, userId, email, role, existingStaffProfileId);
    let warning: string | null = null;
    if (sendOtp) {
      try {
        const { error: otpError } = await createSupabasePublic().auth.signInWithOtp({ email, options: { shouldCreateUser: false } });
        if (otpError) throw otpError;
      } catch {
        warning = "Staff access is ready, but the email code could not be sent. Ask them to request a new code using their dedicated staff email.";
      }
    }
    return NextResponse.json({ ok: true, profileId: staff.profileId, staff, accountCreated,
      alreadyActive: data.already_active === true, warning });
  } catch (error) {
    return NextResponse.json({ error: staffProvisioningError(error) }, { status: 400 });
  }
}
