import { NextRequest, NextResponse } from "next/server";

import { createSupabaseAdmin } from "./supabase-admin";

export type RefereeProfile = {
  profileId: string;
  displayName: string;
  phone: string;
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

  const { data: profile, error: profileError } = await db
    .from("referee_profiles")
    .select("profile_id,display_name,phone,role,is_active")
    .eq("profile_id", userData.user.id)
    .maybeSingle();

  if (profileError) {
    return NextResponse.json(
      { error: `Could not load referee profile: ${profileError.message}` },
      { status: 500 },
    );
  }

  if (!profile || profile.is_active !== true) {
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
      phone: String(profile.phone),
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
