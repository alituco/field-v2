import { createClient } from "npm:@supabase/supabase-js@2.86.0";
import {
  type DevAuthEnvironment,
  isCurrentRunFixture,
  matchesDevAuthSecret,
  stagingDevAuthWindow,
} from "./dev_auth.ts";
import { isLocalSupabaseUrl } from "./staging_guard.ts";

type Client = ReturnType<typeof createClient<any, "public", any>>;
type Dependencies = {
  env: DevAuthEnvironment;
  now?: () => number;
  client?: (url: string, key: string) => Client;
};
const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-fieldrush-e2e-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const response = (error: string, status: number) =>
  new Response(JSON.stringify({ error }), { status, headers });

/** Staging impersonation is a run capability, never an ordinary player feature. */
export async function handleDevAuth(
  request: Request,
  kind: "phone" | "switch",
  dependencies: Dependencies,
): Promise<Response> {
  if (request.method === "OPTIONS") return new Response("ok", { headers });
  if (request.method !== "POST") return response("Method not allowed.", 405);
  const env = dependencies.env;
  const now = dependencies.now ?? Date.now;
  const url = env("SUPABASE_URL") ?? "";
  const local = kind === "phone" && isLocalSupabaseUrl(url);
  const window = local ? null : stagingDevAuthWindow(env, now());
  if (!local && !window) {
    return response("Dev authentication is unavailable.", 404);
  }
  if (
    !local &&
    !await matchesDevAuthSecret(
      request.headers.get("x-fieldrush-e2e-secret"),
      window!.secret,
    )
  ) {
    return response("Dev authentication is unavailable.", 401);
  }
  const key = env("FIELD_SUPABASE_SECRET_KEY") ??
    env("SUPABASE_SERVICE_ROLE_KEY");
  const publicKey = env("SUPABASE_ANON_KEY");
  if (!key || !publicKey) {
    return response("Dev authentication is unavailable.", 404);
  }
  let body: Record<string, unknown>;
  try {
    body = await request.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      throw new Error();
    }
  } catch {
    return response("Invalid request body.", 400);
  }
  const makeClient = dependencies.client ??
    ((url, key) =>
      createClient(url, key, {
        auth: { autoRefreshToken: false, persistSession: false },
      }) as Client);
  const admin = makeClient(url, key);
  const auth = makeClient(url, publicKey);
  try {
    let target;
    if (kind === "phone") {
      const code = local
        ? env("DEV_OTP_CODE") ?? "000000"
        : env("DEV_OTP_CODE");
      if (
        !code || !/^\d{6}$/.test(code) || body.token !== code ||
        typeof body.phone !== "string"
      ) return response("Invalid verification code.", 401);
      const phone = body.phone.replace(/\D/g, "");
      if (!local && phone !== "97339009098") {
        return response("Invalid verification code.", 401);
      }
      for (let page = 1; page <= 10; page++) {
        const { data, error } = await admin.auth.admin.listUsers({
          page,
          perPage: 1000,
        });
        if (error) throw error;
        target = data.users.find((user) =>
          user.phone?.replace(/\D/g, "") === phone
        );
        if (target || data.users.length < 1000) break;
      }
      if (
        !target ||
        (!local && !isCurrentRunFixture(target, window!.runId, now()))
      ) return response("Invalid verification code.", 401);
    } else {
      const bearer = request.headers.get("Authorization")?.match(
        /^Bearer (\S+)$/,
      )?.[1];
      if (!bearer) return response("A current E2E session is required.", 401);
      const { data: caller, error } = await admin.auth.getUser(bearer);
      if (error || !isCurrentRunFixture(caller.user, window!.runId, now())) {
        return response("A current E2E session is required.", 403);
      }
      if (
        Object.keys(body).some((name) => name !== "profile_id") ||
        typeof body.profile_id !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
          .test(body.profile_id)
      ) return response("Choose a current E2E fixture.", 400);
      const { data, error: targetError } = await admin.auth.admin.getUserById(
        body.profile_id,
      );
      if (
        targetError || data.user?.id !== body.profile_id ||
        !isCurrentRunFixture(data.user, window!.runId, now())
      ) return response("Choose a current E2E fixture.", 403);
      target = data.user;
    }
    // No creation, metadata edits, magic links or password resets: service setup
    // alone owns provisioning of the strictly marked synthetic fixture pool.
    const password = local
      ? env("LOCAL_DEV_SEED_PASSWORD") ?? "LocalField_Only_42!"
      : window!.password;
    const { data, error } = await auth.auth.signInWithPassword({
      phone: target.phone!,
      password,
    });
    if (
      error || !data.session || data.user?.id !== target.id ||
      (!local &&
        (!isCurrentRunFixture(data.user, window!.runId, now()) ||
          now() >= window!.expiresAt))
    ) return response("Dev authentication is unavailable.", 401);
    return new Response(
      JSON.stringify({
        access_token: data.session.access_token,
        refresh_token: data.session.refresh_token,
        expires_at: data.session.expires_at,
        user_id: data.user.id,
      }),
      { headers },
    );
  } catch {
    return response("Dev authentication is unavailable.", 503);
  }
}
