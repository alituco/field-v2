import { createClient } from "npm:@supabase/supabase-js@2.86.0";
import { isExactFieldStagingSupabaseUrl } from "./staging_guard.ts";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers });
const encode = (value: unknown) =>
  btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(value))))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");

export async function signStagingSession(
  payload: Record<string, unknown>,
  secret: string,
) {
  const input = `${encode({ alg: "HS256", typ: "JWT" })}.${encode(payload)}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(input)),
  );
  return `${input}.${
    btoa(String.fromCharCode(...signature)).replaceAll("+", "-").replaceAll(
      "/",
      "_",
    ).replace(/=+$/, "")
  }`;
}

export async function handleStagingAdminSession(
  request: Request,
  dependencies: {
    env: (name: string) => string | undefined;
    client?: typeof createClient;
    now?: () => number;
  },
) {
  if (request.method === "OPTIONS") return reply({});
  const env = dependencies.env;
  const url = env("SUPABASE_URL");
  if (
    !isExactFieldStagingSupabaseUrl(url) ||
    env("STAGING_ADMIN_SWITCH_ENABLED") !== "true"
  ) {
    return reply({ error: "Staging account switching is unavailable." }, 404);
  }
  if (request.method !== "POST") {
    return reply({ error: "Method not allowed." }, 405);
  }
  const secret = env("STAGING_IMPERSONATION_JWT_SECRET");
  const serviceKey = env("FIELD_SUPABASE_SECRET_KEY") ??
    env("SUPABASE_SERVICE_ROLE_KEY");
  if (!secret || !serviceKey) {
    return reply(
      { error: "Staging account switching is not configured." },
      503,
    );
  }
  const token = request.headers.get("Authorization")?.match(/^Bearer (\S+)$/)
    ?.[1];
  if (!token) {
    return reply({ error: "Sign in as a staging administrator first." }, 401);
  }
  try {
    const admin = (dependencies.client ?? createClient)(url, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: caller, error } = await admin.auth.getUser(token);
    if (error || !caller.user) {
      return reply({ error: "Sign in as a staging administrator first." }, 401);
    }
    // Inspect claims only AFTER Auth has verified the signature. A test session
    // cannot become an administrator capability, even when its target is staff.
    const claims = JSON.parse(
      atob(token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/")),
    );
    if (
      claims.fieldrush_staging_actor || typeof claims.session_id !== "string"
    ) {
      return reply({
        error: "Use your original administrator session to switch accounts.",
      }, 403);
    }
    const { data: staff, error: staffError } = await admin.from(
      "referee_profiles",
    )
      .select("role,is_active").eq("profile_id", caller.user.id).maybeSingle();
    if (staffError || staff?.role !== "admin" || staff.is_active !== true) {
      return reply({
        error: "Only active staging administrators can switch accounts.",
      }, 403);
    }
    const body = await request.json();
    if (
      !body || Object.keys(body).some((key) => key !== "profile_id") ||
      typeof body.profile_id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
        .test(body.profile_id)
    ) {
      return reply({ error: "Choose a staging account." }, 400);
    }
    const { data: target, error: targetError } = await admin.auth.admin
      .getUserById(body.profile_id);
    const now = Math.floor((dependencies.now ?? Date.now)() / 1000);
    const user = target.user as
      | (NonNullable<typeof target.user> & { banned_until?: string })
      | null;
    if (
      targetError || !user || user.id !== body.profile_id || user.deleted_at ||
      (user.banned_until && Date.parse(user.banned_until) > now * 1000)
    ) {
      return reply({ error: "This account is unavailable." }, 403);
    }
    const { data: profile, error: profileError } = await admin.from("profiles")
      .select("account_deleted_at").eq("id", user.id).maybeSingle();
    if (profileError || !profile || profile.account_deleted_at) {
      return reply({ error: "This account is unavailable." }, 403);
    }
    const expiresAt = now + 15 * 60;
    // No password, email, identity, or Auth session-table writes. The temporary
    // token has no refresh token and cannot outlive this fifteen-minute window.
    const accessToken = await signStagingSession({
      iss: `${url}/auth/v1`,
      aud: "authenticated",
      role: "authenticated",
      sub: user.id,
      iat: now,
      exp: expiresAt,
      aal: "aal1",
      is_anonymous: false,
      email: user.email ?? "",
      phone: user.phone ?? "",
      app_metadata: user.app_metadata,
      user_metadata: user.user_metadata,
      fieldrush_staging_actor: caller.user.id,
    }, secret);
    const { error: auditError } = await admin.from("admin_audit_events").insert(
      {
        actor_referee_id: caller.user.id,
        action: "STAGING_ACCOUNT_SWITCH",
        entity_type: "PLAYER",
        entity_id: user.id,
        reason: "Administrator opened a temporary staging test session.",
        after_state: { expires_at: new Date(expiresAt * 1000).toISOString() },
      },
    );
    if (auditError) {
      return reply(
        { error: "Could not record the account switch. Try again." },
        503,
      );
    }
    return reply({
      access_token: accessToken,
      token_type: "bearer",
      expires_in: 900,
      expires_at: expiresAt,
      user,
      refresh_token: null,
    });
  } catch {
    return reply(
      { error: "Could not switch staging accounts. Try again." },
      503,
    );
  }
}
