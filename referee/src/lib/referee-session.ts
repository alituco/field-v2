import { NextRequest, NextResponse } from "next/server";

import { createSupabaseAdmin } from "./supabase-admin";
import { isStaffAuthIdentity, normalizeStaffEmail } from "./staff-identities";

export type RefereeProfile = {
  profileId: string;
  displayName: string;
  phone: string;
  email: string;
  role: "admin" | "referee";
  isActive: boolean;
};

export type RefereeRequestContext = {
  db: ReturnType<typeof createSupabaseAdmin>;
  referee: RefereeProfile;
};

export async function requireReferee(
  request: NextRequest,
): Promise<RefereeRequestContext | NextResponse> {
  const token = request.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "")
    .trim();

  if (!token) {
    return NextResponse.json({ error: "Sign in required." }, { status: 401 });
  }

  const db = createSupabaseAdmin();
  const { data: userData, error: userError } = await db.auth.getUser(token);

  if (userError || !userData.user) {
    return NextResponse.json(
      { error: "Session expired. Sign in again." },
      { status: 401 },
    );
  }

  if (!isStaffAuthIdentity(userData.user, true)) {
    return NextResponse.json({ error: "Sign in using your independent staff email account." }, { status: 403 });
  }
  const email = normalizeStaffEmail(userData.user.email);

  const { data: profile, error: profileError } = await db
    .from("referee_profiles")
    .select("profile_id,auth_user_id,email,display_name,phone,role,is_active")
    .eq("auth_user_id", userData.user.id)
    .maybeSingle();

  if (profileError) {
    return NextResponse.json(
      { error: "Staff sign-in is temporarily unavailable. Try again shortly." },
      { status: 500 },
    );
  }

  if (!profile || profile.is_active !== true || profile.auth_user_id !== userData.user.id || profile.email !== email ||
    (profile.role !== "admin" && profile.role !== "referee")) {
    return NextResponse.json(
      { error: "This account is not an active referee." },
      { status: 403 },
    );
  }

  return {
    db,
    referee: {
      profileId: String(profile.profile_id),
      displayName: String(profile.display_name),
      phone: typeof profile.phone === "string" ? profile.phone : "",
      email,
      role: String(profile.role) === "admin" ? "admin" : "referee",
      isActive: true,
    },
  };
}

export function isRefereeContext(
  value: RefereeRequestContext | NextResponse,
): value is RefereeRequestContext {
  return !(value instanceof NextResponse);
}

export function adminOnly(referee: RefereeProfile) {
  if (referee.role !== "admin") {
    return NextResponse.json(
      { error: "Admin referee access required." },
      { status: 403 },
    );
  }

  return null;
}
