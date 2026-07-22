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
    const body = (await request.json()) as {
      displayName?: string;
      phone?: string;
      role?: "admin" | "referee";
      password?: string;
      sendOtp?: boolean;
    };
    const displayName = requireText(body.displayName, "Enter a name.");
    const phone = normalizePhoneNumber(requireText(body.phone, "Enter a phone."));
    const role = body.role === "admin" ? "admin" : "referee";
    const password = body.password && body.password.length >= 6
      ? body.password
      : crypto.randomUUID();

    const userId = await upsertAuthUser(context.db, {
      phone,
      displayName,
      password,
    });

    await upsertProfile(context.db, { userId, phone, displayName, role });

    let loginWarning: string | null = null;
    if (body.sendOtp !== false) {
      const { error } = await createSupabasePublic().auth.signInWithOtp({
        phone,
      });
      if (error) loginWarning = `Account created, but the first login code could not be sent: ${error.message}`;
    }

    return NextResponse.json({
      ok: true,
      profileId: userId,
      staff: { profileId: userId, displayName, phone, role, isActive: true },
      warning: loginWarning,
    });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not create this staff account." },
      { status: 400 },
    );
  }
}

async function upsertAuthUser(
  db: ReturnType<typeof import("@/lib/supabase-admin").createSupabaseAdmin>,
  input: { phone: string; displayName: string; password: string },
) {
  const existingUser = await findUserByPhone(db, input.phone);

  if (existingUser) {
    const { error } = await db.auth.admin.updateUserById(existingUser.id, {
      phone: input.phone,
      password: input.password,
      phone_confirm: true,
      user_metadata: {
        ...(existingUser.user_metadata ?? {}),
        display_name: input.displayName,
        name: input.displayName,
      },
    });

    if (error) throw error;
    return existingUser.id;
  }

  const { data, error } = await db.auth.admin.createUser({
    phone: input.phone,
    password: input.password,
    phone_confirm: true,
    user_metadata: {
      display_name: input.displayName,
      name: input.displayName,
    },
  });

  if (error) throw error;
  if (!data.user) throw new Error("Could not create auth user.");
  return data.user.id;
}

async function upsertProfile(
  db: ReturnType<typeof import("@/lib/supabase-admin").createSupabaseAdmin>,
  input: {
    userId: string;
    phone: string;
    displayName: string;
    role: "admin" | "referee";
  },
) {
  const { error: profileError } = await db.from("profiles").upsert(
    {
      id: input.userId,
      phone: input.phone,
      display_name: input.displayName,
      username: null,
    },
    { onConflict: "id" },
  );

  if (profileError) throw profileError;

  const { error: refereeError } = await db.from("referee_profiles").upsert(
    {
      profile_id: input.userId,
      phone: input.phone,
      display_name: input.displayName,
      role: input.role,
      is_active: true,
    },
    { onConflict: "profile_id" },
  );

  if (refereeError) throw refereeError;
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

  return null;
}

function requireText(value: string | undefined, message: string) {
  const trimmed = value?.trim();
  if (!trimmed) throw new Error(message);
  return trimmed;
}
