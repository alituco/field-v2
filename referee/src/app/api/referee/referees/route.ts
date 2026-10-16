import { NextRequest, NextResponse } from "next/server";

import { normalizePhoneNumber } from "@/lib/phone";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";
import { createSupabasePublic } from "@/lib/supabase-admin";

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const adminError = adminOnly(context.referee);
  if (adminError) return adminError;

  const { data, error } = await context.db
    .from("referee_profiles")
    .select("profile_id,display_name,phone,role,is_active,created_at,updated_at")
    .order("is_active", { ascending: false })
    .order("display_name");

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({
    staff: (data ?? []).map((row) => ({
      profileId: row.profile_id,
      displayName: row.display_name,
      phone: row.phone,
      role: row.role,
      isActive: row.is_active,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    })),
  });
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const adminError = adminOnly(context.referee);
  if (adminError) return adminError;

  try {
    const body = parseStaffInput(await request.json());
    const { displayName, phone, role } = body;
    const { userId, accountCreated } = await resolveAuthUser(context.db, phone, displayName);
    // The database rechecks the administrator, exact Auth identity/phone and
    // deletion state under locks. It never overwrites an existing player row.
    const { data, error } = await context.db.rpc("admin_grant_fieldrush_staff", {
      actor_admin_id: context.referee.profileId,
      target_profile_id: userId,
      expected_phone: phone,
      display_name_to_use: displayName,
      role_to_use: role,
    });
    if (error) throw error;
    const staff = serializeGrantedStaff(data, userId, phone, role);

    let loginWarning: string | null = null;
    if (body.sendOtp !== false) {
      try {
        const { error } = await createSupabasePublic().auth.signInWithOtp({
          phone,
          options: { shouldCreateUser: false },
        });
        if (error) throw error;
      } catch {
        loginWarning = "Staff access is ready, but the login code could not be sent. Ask them to sign in with their existing phone number.";
      }
    }

    return NextResponse.json({
      ok: true,
      profileId: userId,
      staff,
      accountCreated,
      alreadyActive: data.already_active === true,
      warning: loginWarning,
    });
  } catch (error) {
    return NextResponse.json(
      { error: staffProvisioningError(error) },
      { status: 400 },
    );
  }
}

async function resolveAuthUser(
  db: ReturnType<typeof import("@/lib/supabase-admin").createSupabaseAdmin>,
  phone: string,
  displayName: string,
) {
  const existingUser = await findUserByPhone(db, phone);
  if (existingUser) return { userId: existingUser.id, accountCreated: false };

  const { data, error } = await db.auth.admin.createUser({
    phone,
    phone_confirm: false,
    user_metadata: { display_name: displayName, name: displayName },
  });
  if (!error && data.user) return { userId: data.user.id, accountCreated: true };
  // Another request may have created the phone identity after our lookup, or
  // Auth may have committed before a response failed. Re-read; never reset,
  // delete, merge, or update that account as a recovery strategy.
  const concurrentUser = await findUserByPhone(db, phone);
  if (concurrentUser) return { userId: concurrentUser.id, accountCreated: false };
  throw new StaffProvisioningError("Could not create the phone sign-in. No staff access was granted. Try again.");
}

async function findUserByPhone(
  db: ReturnType<typeof import("@/lib/supabase-admin").createSupabaseAdmin>,
  phone: string,
) {
  const targetDigits = phone.replace(/\D/g, "");

  for (let page = 1; page <= 10; page += 1) {
    const { data, error } = await db.auth.admin.listUsers({
      page,
      perPage: 1000,
    });

    if (error) throw error;

    const user = data.users.find(
      (candidate) =>
        (candidate.phone ?? "").replace(/\D/g, "") === targetDigits,
    );
    if (user) return user;
    if (data.users.length < 1000) return null;
  }

  throw new StaffProvisioningError("The account directory could not be searched completely. No account was changed. Contact support.");
}

function requireText(value: unknown, message: string) {
  const trimmed = typeof value === "string" ? value.trim() : "";
  if (!trimmed) throw new StaffProvisioningError(message);
  return trimmed;
}

function parseStaffInput(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new StaffProvisioningError("Provide valid staff details.");
  const body = value as Record<string, unknown>;
  if ("password" in body || "resetPassword" in body) throw new StaffProvisioningError("Adding staff never changes a password. Password resets require a separate recovery flow.");
  if (Object.keys(body).some((key) => !["displayName", "phone", "role", "sendOtp"].includes(key))) throw new StaffProvisioningError("Unknown staff field.");
  const displayName = requireText(body.displayName, "Enter a name.");
  if (displayName.length < 2 || displayName.length > 50 || /[\u0000-\u001f\u007f]/.test(displayName)) throw new StaffProvisioningError("Use a staff name of 2 to 50 characters.");
  const phone = normalizePhoneNumber(requireText(body.phone, "Enter a phone."));
  if (!/^\+[1-9]\d{7,14}$/.test(phone)) throw new StaffProvisioningError("Enter a valid international phone number.");
  if (body.role !== undefined && body.role !== "admin" && body.role !== "referee") throw new StaffProvisioningError("Choose admin or referee access.");
  if (body.sendOtp !== undefined && typeof body.sendOtp !== "boolean") throw new StaffProvisioningError("Choose whether to send a login code.");
  return { displayName, phone, role: body.role === "admin" ? "admin" as const : "referee" as const, sendOtp: body.sendOtp };
}

function serializeGrantedStaff(value: unknown, userId: string, phone: string, role: string) {
  const result = value as { staff?: Record<string, unknown> } | null;
  const staff = result?.staff;
  if (!staff || staff.profile_id !== userId || staff.phone !== phone || staff.role !== role || staff.is_active !== true || typeof staff.display_name !== "string") {
    throw new StaffProvisioningError("Staff access could not be confirmed. Refresh the staff directory before trying again.");
  }
  return { profileId: userId, displayName: staff.display_name, phone, role, isActive: true };
}

function staffProvisioningError(error: unknown) {
  if (error instanceof StaffProvisioningError) return error.message;
  const code = (error as { code?: unknown } | null)?.code;
  if (code === "42501") return "Active administrator access is required. Refresh and sign in again.";
  if (code === "22023") return "Staff access was not changed. Check the phone number, account status and any existing staff role.";
  if (code === "PGRST202" || code === "42883") return "Staff provisioning is unavailable until the latest database migration is deployed.";
  return "Staff access could not be confirmed. Refresh the staff directory before trying again. Existing sign-in and player details were not changed.";
}

class StaffProvisioningError extends Error {}
