import { createClient } from "npm:@supabase/supabase-js@2.86.0";
import { isAccountDeletionEnabled } from "./environment.ts";
import {
  isStaffDeletionIdentity,
  readDeletionConfirmation,
} from "./request.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }
  const url = Deno.env.get("SUPABASE_URL");
  if (!isAccountDeletionEnabled((name) => Deno.env.get(name))) {
    return json(
      { error: "Account deletion is not enabled. Contact support." },
      503,
    );
  }
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const secret = Deno.env.get("FIELD_SUPABASE_SECRET_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!anonKey || !secret) {
    return json({ error: "Account deletion is temporarily unavailable." }, 503);
  }
  const authorization = request.headers.get("Authorization");
  const bearer = authorization?.match(/^Bearer\s+(\S+)$/i)?.[1];
  if (!bearer) {
    return json({ error: "Sign in again before deleting your account." }, 401);
  }
  try {
    if (!readDeletionConfirmation(await request.json())) {
      return json({
        error:
          "Confirm account deletion and permanent loss of your remaining wallet balance first.",
      }, 400);
    }
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }

  const options = { auth: { autoRefreshToken: false, persistSession: false } };
  const admin = createClient(url!, secret, options);
  // Always authenticate the JWT against Auth; decoding it alone is insufficient.
  const { data: identity, error: authError } = await admin.auth.getUser(bearer);
  if (authError || !identity.user) {
    return json({ error: "Your session has expired. Sign in again." }, 401);
  }
  if (isStaffDeletionIdentity(identity.user)) {
    return json({
      error:
        "This is a staff login, not a player account. Manage staff access from the staff website.",
    }, 403);
  }
  const user = createClient(url!, anonKey, {
    ...options,
    global: { headers: { Authorization: `Bearer ${bearer}` } },
  });
  const { error: preparationError } = await user.rpc(
    "prepare_fieldrush_account_deletion",
    { wallet_forfeiture_confirmed: true },
  );
  if (preparationError) {
    // These messages are deliberately actionable business/auth errors, never
    // provider tokens, SQL detail/hints, or a misleading successful deletion.
    if (["42501", "22023"].includes(preparationError.code)) {
      return json({ error: preparationError.message }, 409);
    }
    return json(
      { error: "Could not prepare deletion. Please try again." },
      500,
    );
  }

  try {
    // A pending account cannot create new participation or upload avatars.
    // Remove Storage objects through its API (not SQL) so the blob is removed.
    const bucket = admin.storage.from("profile-avatars");
    const pendingFolders = [identity.user.id];
    const paths: string[] = [];
    while (pendingFolders.length > 0) {
      const prefix = pendingFolders.pop()!;
      let offset = 0;
      while (true) {
        const { data, error } = await bucket.list(prefix, {
          limit: 100,
          offset,
          sortBy: { column: "name", order: "asc" },
        });
        if (error) throw new Error("avatar_listing_failed");
        for (const object of data ?? []) {
          const path = `${prefix}/${object.name}`;
          if (object.id) paths.push(path);
          else pendingFolders.push(path);
        }
        if (!data || data.length < 100) break;
        offset += data.length;
      }
    }
    for (let offset = 0; offset < paths.length; offset += 100) {
      const { error } = await bucket.remove(paths.slice(offset, offset + 100));
      if (error) throw new Error("avatar_deletion_failed");
    }
    // Hard delete Auth identities, refresh sessions and private account rows.
    // The database trigger anonymizes historical profile references atomically.
    const { error: deletionError } = await admin.auth.admin.deleteUser(
      identity.user.id,
    );
    if (deletionError) throw new Error("auth_deletion_failed");
    return json({ deleted: true }, 200);
  } catch {
    return json({
      error:
        "Deletion has not finished. Your account is paused. Retry deletion or contact support; we have not marked it deleted.",
      status: "deletion_pending",
    }, 503);
  }
});
