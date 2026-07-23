import { createClient } from "npm:@supabase/supabase-js@2.86.0";
import {
  isExactFieldStagingSupabaseUrl,
  isLocalSupabaseUrl,
} from "../_shared/staging_guard.ts";

type SupabaseAnyClient = ReturnType<typeof createClient<any, "public", any>>;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type JsonBody = {
  phone?: string;
  token?: string;
};

type DevUser = {
  phone: string;
  displayName: string;
};

type ConfiguredDevUsers = {
  users: DevUser[];
  error?: string;
};

const devDateOfBirth = "2000-01-01";

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const isLocal = isLocalSupabaseUrl(supabaseUrl);
  const isStaging = isExactFieldStagingSupabaseUrl(supabaseUrl);
  if (!isLocal && !isStaging) {
    return json({ error: "Dev login is unavailable." }, 404);
  }

  const enabled = isLocal || Deno.env.get("DEV_OTP_ENABLED") === "true";
  const configuredDevUsers = getConfiguredDevUsers();
  const allowedCode = Deno.env.get("DEV_OTP_CODE") ?? "000000";
  const devPassword = isLocal
    ? Deno.env.get("LOCAL_DEV_SEED_PASSWORD") ?? "LocalField_Only_42!"
    : Deno.env.get("DEV_OTP_PASSWORD");
  const validUntil = Deno.env.get("DEV_OTP_VALID_UNTIL");

  if (configuredDevUsers.error) {
    return json({ error: configuredDevUsers.error }, 500);
  }

  if (
    !enabled || (!isLocal && configuredDevUsers.users.length === 0) ||
    !devPassword
  ) {
    return json({ error: "Dev login is not configured." }, 404);
  }

  if (validUntil && Date.now() > Date.parse(validUntil)) {
    return json({ error: "Dev login has expired." }, 403);
  }

  let body: JsonBody;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }

  if (body.token !== allowedCode) {
    return json({ error: "Invalid verification code." }, 401);
  }

  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("FIELD_SUPABASE_SECRET_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!anonKey || !serviceRoleKey) {
    return json({ error: "Missing Supabase function secrets." }, 500);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  }) as SupabaseAnyClient;
  const authClient = createClient(supabaseUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  }) as SupabaseAnyClient;

  try {
    const requestedPhone = body.phone?.trim() ?? "";
    const localUser = isLocal
      ? await findUserByPhone(admin, requestedPhone)
      : null;
    const devUser = isLocal
      ? {
        phone: localUser?.phone ?? requestedPhone,
        displayName: normalizeDisplayName(
          String(
            localUser?.user_metadata?.display_name ??
              localUser?.user_metadata?.name ??
              "Local Player",
          ),
        ),
      }
      : findConfiguredDevUser(configuredDevUsers.users, requestedPhone);

    if (!devUser || (isLocal && !localUser)) {
      return json(
        {
          error: isLocal
            ? "That player is not in the local seed data."
            : "Invalid verification code.",
        },
        401,
      );
    }

    const userId = isLocal
      ? localUser!.id
      : await retryTransientAuthFailure(() =>
        ensureDevUser({
          admin,
          phone: devUser.phone,
          password: devPassword,
          displayName: devUser.displayName,
        })
      );

    const { error: profileError } = isLocal
      ? await admin.from("profiles").update({
        phone: devUser.phone,
      }).eq("id", userId)
      : await admin.from("profiles").upsert(
        {
          id: userId,
          phone: devUser.phone,
          display_name: devUser.displayName,
          date_of_birth: devDateOfBirth,
        },
        { onConflict: "id" },
      );

    if (profileError) {
      return json({ error: profileError.message }, 500);
    }

    const { data: signInData, error: signInError } =
      await signInDevUserWithPassword({
        authClient,
        phone: devUser.phone,
        password: devPassword,
      });

    if (signInError || !signInData.session) {
      return json(
        { error: signInError?.message ?? "Could not create dev session." },
        500,
      );
    }

    return json({
      access_token: signInData.session.access_token,
      refresh_token: signInData.session.refresh_token,
      expires_at: signInData.session.expires_at,
      user_id: signInData.user?.id ?? userId,
    });
  } catch (error) {
    return json({ error: toErrorMessage(error) }, 500);
  }
});

async function ensureDevUser({
  admin,
  phone,
  password,
  displayName,
}: {
  admin: SupabaseAnyClient;
  phone: string;
  password: string;
  displayName: string;
}) {
  const { data, error } = await admin.auth.admin.createUser({
    phone,
    password,
    phone_confirm: true,
    user_metadata: {
      display_name: displayName,
      name: displayName,
      date_of_birth: devDateOfBirth,
    },
  });

  if (!error && data.user) {
    return data.user.id;
  }

  if (!isAlreadyRegisteredError(error?.message)) {
    throw error ?? new Error("Could not create dev user.");
  }

  const existingUser = await findUserByPhone(admin, phone);
  if (!existingUser) {
    throw new Error("Dev user already exists, but could not be found.");
  }

  const { error: updateError } = await admin.auth.admin.updateUserById(
    existingUser.id,
    {
      password,
      phone_confirm: true,
      user_metadata: {
        ...existingUser.user_metadata,
        display_name: displayName,
        name: displayName,
        date_of_birth: devDateOfBirth,
      },
    },
  );

  if (updateError) {
    throw updateError;
  }

  return existingUser.id;
}

async function signInDevUserWithPassword({
  authClient,
  phone,
  password,
}: {
  authClient: SupabaseAnyClient;
  phone: string;
  password: string;
}) {
  const attempts = unique([phone, normalizePhoneDigits(phone)]);

  for (const attempt of attempts) {
    const result = await authClient.auth.signInWithPassword({
      phone: attempt,
      password,
    });

    if (!result.error && result.data.session) {
      return result;
    }
  }

  return await authClient.auth.signInWithPassword({ phone, password });
}

async function findUserByPhone(
  admin: SupabaseAnyClient,
  phone: string,
) {
  const phoneDigits = normalizePhoneDigits(phone);

  for (let page = 1; page <= 10; page += 1) {
    const { data, error } = await admin.auth.admin.listUsers({
      page,
      perPage: 1000,
    });

    if (error) throw error;

    const user = data.users.find((candidate) =>
      normalizePhoneDigits(candidate.phone ?? "") === phoneDigits
    );
    if (user) return user;
    if (data.users.length < 1000) return null;
  }

  return null;
}

function getConfiguredDevUsers(): ConfiguredDevUsers {
  const users: DevUser[] = [];
  const legacyPhone = Deno.env.get("DEV_OTP_PHONE");
  const legacyName = Deno.env.get("DEV_OTP_NAME") ?? "Dev Player";
  const usersJson = Deno.env.get("DEV_OTP_USERS_JSON");

  if (legacyPhone) {
    users.push({
      phone: legacyPhone,
      displayName: normalizeDisplayName(legacyName),
    });
  }

  if (usersJson) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(usersJson);
    } catch {
      return { users: [], error: "DEV_OTP_USERS_JSON is not valid JSON." };
    }

    if (!isRecord(parsed)) {
      return {
        users: [],
        error: "DEV_OTP_USERS_JSON must be an object of phone/name pairs.",
      };
    }

    for (const [phone, displayName] of Object.entries(parsed)) {
      if (typeof displayName !== "string") {
        return {
          users: [],
          error: "DEV_OTP_USERS_JSON values must be display-name strings.",
        };
      }

      users.push({
        phone,
        displayName: normalizeDisplayName(displayName),
      });
    }
  }

  return { users: uniqueDevUsers(users) };
}

function findConfiguredDevUser(users: DevUser[], phone?: string) {
  if (!phone) return null;
  const phoneDigits = normalizePhoneDigits(phone);
  return users.find((user) =>
    normalizePhoneDigits(user.phone) === phoneDigits
  ) ??
    null;
}

function uniqueDevUsers(users: DevUser[]) {
  const byPhoneDigits = new Map<string, DevUser>();
  for (const user of users) {
    const phoneDigits = normalizePhoneDigits(user.phone);
    if (!phoneDigits) continue;
    byPhoneDigits.set(phoneDigits, user);
  }
  return [...byPhoneDigits.values()];
}

function normalizeDisplayName(displayName: string) {
  const trimmed = displayName.trim();
  if (trimmed.length >= 2 && trimmed.length <= 24) return trimmed;
  return "Dev Player";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizePhoneDigits(phone: string) {
  return phone.replace(/\D/g, "");
}

function unique(values: string[]) {
  return [...new Set(values.filter(Boolean))];
}

function isAlreadyRegisteredError(message?: string) {
  if (!message) return false;
  const normalized = message.toLowerCase();
  return (
    normalized.includes("already registered") ||
    normalized.includes("already exists") ||
    normalized.includes("duplicate")
  );
}

async function retryTransientAuthFailure<T>(action: () => Promise<T>) {
  const delaysMs = [1000, 2000, 4000, 8000];

  for (let attempt = 0; attempt <= delaysMs.length; attempt += 1) {
    try {
      return await action();
    } catch (error) {
      if (!isSigningKeyCacheMiss(error) || attempt === delaysMs.length) {
        throw error;
      }

      console.warn(
        `Supabase Auth signing-key cache miss; retrying dev login (${
          attempt + 1
        }/${delaysMs.length}).`,
      );
      await new Promise((resolve) => setTimeout(resolve, delaysMs[attempt]));
    }
  }

  throw new Error("Could not create dev login.");
}

function isSigningKeyCacheMiss(error: unknown) {
  const message = toErrorMessage(error);
  return message.includes("unrecognized JWT kid") &&
    message.includes("token is unverifiable");
}

function toErrorMessage(error: unknown) {
  if (error instanceof Error) return error.message;
  if (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message;
  }
  return "Could not create dev login.";
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
