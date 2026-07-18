import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";
import { isExactFieldStagingSupabaseUrl } from "../_shared/staging_guard.ts";

type SupabaseAnyClient = ReturnType<typeof createClient<any, "public", any>>;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type JsonBody = {
  profile_id?: unknown;
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!isExactFieldStagingSupabaseUrl(supabaseUrl)) {
    return json({ error: "Dev user switching is unavailable." }, 404);
  }

  if (Deno.env.get("DEV")?.toLowerCase() !== "true") {
    return json({ error: "Dev user switching is disabled." }, 404);
  }

  const validUntil = Deno.env.get("DEV_SWITCH_VALID_UNTIL");
  if (validUntil && Date.now() > Date.parse(validUntil)) {
    return json({ error: "Dev user switching has expired." }, 403);
  }

  const allowUnauthenticatedRecovery = Deno.env.get(
    "DEV_SWITCH_ALLOW_UNAUTHENTICATED",
  )?.toLowerCase() === "true";

  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!anonKey || !serviceRoleKey) {
    return json({ error: "Missing Supabase function secrets." }, 500);
  }

  const bearerToken = readBearerToken(request.headers.get("Authorization"));
  if (!bearerToken && !allowUnauthenticatedRecovery) {
    return json({ error: "Sign in before switching users." }, 401);
  }

  let body: JsonBody;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }

  if (typeof body.profile_id !== "string" || !isUuid(body.profile_id)) {
    return json({ error: "Choose a valid user." }, 400);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  }) as SupabaseAnyClient;
  const authClient = createClient(supabaseUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  }) as SupabaseAnyClient;

  try {
    const { data: callerData, error: callerError } = bearerToken
      ? await admin.auth.getUser(bearerToken)
      : { data: { user: null }, error: null };
    if (
      (callerError || !callerData.user) &&
      !allowUnauthenticatedRecovery
    ) {
      return json({ error: "Your session has expired. Sign in again." }, 401);
    }

    const { data: profile, error: profileError } = await admin
      .from("profiles")
      .select("id, display_name, username, date_of_birth")
      .eq("id", body.profile_id)
      .maybeSingle();
    if (profileError) throw profileError;
    if (!profile) {
      return json({ error: "That app user could not be found." }, 404);
    }

    const { data: targetData, error: targetError } = await admin.auth.admin
      .getUserById(body.profile_id);
    if (targetError || !targetData.user) {
      return json({ error: "That user does not have an auth account." }, 404);
    }

    const target = targetData.user;
    const userMetadata = {
      ...target.user_metadata,
      display_name: profile.display_name,
      name: profile.display_name,
      date_of_birth: profile.date_of_birth ??
        target.user_metadata?.date_of_birth ?? null,
    };
    const session = target.email
      ? await createEmailSession({
        admin,
        authClient,
        userId: target.id,
        email: target.email,
        userMetadata,
      })
      : await createPhoneSession({
        admin,
        authClient,
        userId: target.id,
        phone: target.phone,
        userMetadata,
      });

    if (!session) {
      throw new Error("Could not create the selected dev session.");
    }

    console.info(
      `Dev user switch: ${callerData.user?.id ?? "recovery"} -> ${target.id}`,
    );

    return json({
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      expires_at: session.expires_at,
      user_id: target.id,
      display_name: profile.display_name,
      username: profile.username,
    });
  } catch (error) {
    return json({ error: toErrorMessage(error) }, 500);
  }
});

async function createEmailSession({
  admin,
  authClient,
  userId,
  email,
  userMetadata,
}: {
  admin: SupabaseAnyClient;
  authClient: SupabaseAnyClient;
  userId: string;
  email: string;
  userMetadata: Record<string, unknown>;
}) {
  const { error: updateError } = await admin.auth.admin.updateUserById(userId, {
    user_metadata: userMetadata,
  });
  if (updateError) throw updateError;

  const { data: linkData, error: linkError } = await admin.auth.admin
    .generateLink({ type: "magiclink", email });
  if (linkError || !linkData.properties?.hashed_token) {
    throw linkError ?? new Error("Could not create a dev sign-in link.");
  }

  const { data, error } = await authClient.auth.verifyOtp({
    token_hash: linkData.properties.hashed_token,
    type: "magiclink",
  });
  if (error || !data.session) {
    throw error ?? new Error("Could not open the selected dev session.");
  }
  return data.session;
}

async function createPhoneSession({
  admin,
  authClient,
  userId,
  phone,
  userMetadata,
}: {
  admin: SupabaseAnyClient;
  authClient: SupabaseAnyClient;
  userId: string;
  phone?: string;
  userMetadata: Record<string, unknown>;
}) {
  const password = Deno.env.get("DEV_SWITCH_PASSWORD") ??
    Deno.env.get("DEV_OTP_PASSWORD");
  if (!phone || !password) {
    throw new Error("Phone dev switching is not configured.");
  }

  const { error: updateError } = await admin.auth.admin.updateUserById(userId, {
    password,
    phone_confirm: true,
    user_metadata: userMetadata,
  });
  if (updateError) throw updateError;

  const attempts = unique([phone, normalizePhoneDigits(phone)]);
  for (const attempt of attempts) {
    const { data, error } = await authClient.auth.signInWithPassword({
      phone: attempt,
      password,
    });
    if (!error && data.session) return data.session;
  }

  throw new Error("Could not open the selected dev session.");
}

function readBearerToken(header: string | null) {
  if (!header?.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length).trim();
  return token || null;
}

function isUuid(value: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function normalizePhoneDigits(phone: string) {
  return phone.replace(/\D/g, "");
}

function unique(values: string[]) {
  return [...new Set(values.filter(Boolean))];
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
  return "Could not switch dev users.";
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Cache-Control": "no-store",
      "Content-Type": "application/json",
    },
  });
}
