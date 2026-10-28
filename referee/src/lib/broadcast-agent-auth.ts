import { createHmac, timingSafeEqual } from "node:crypto";
import { createSupabaseAdmin } from "./supabase-admin";
import type { BroadcastAgentContext, BroadcastMatchKind } from "./broadcast-pairing";

export function isBroadcastAgentRequest(request: Request) {
  const expected = process.env.BROADCAST_AGENT_TOKEN?.trim();
  const provided = request.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "")
    .trim();

  if (!expected || !provided) return false;

  const expectedBytes = Buffer.from(expected);
  const providedBytes = Buffer.from(provided);
  return expectedBytes.length === providedBytes.length &&
    timingSafeEqual(expectedBytes, providedBytes);
}

export function broadcastDeviceKey() {
  return process.env.BROADCAST_DEVICE_KEY?.trim() || "main-pitch";
}

export function broadcastDeviceName() {
  return process.env.BROADCAST_DEVICE_NAME?.trim() || "Main Pitch Camera";
}

export function broadcastOverlayToken() {
  const value = process.env.BROADCAST_OVERLAY_TOKEN?.trim();
  if (!value) throw new Error("BROADCAST_OVERLAY_TOKEN is not configured.");
  return value;
}

export function isValidOverlayToken(value: string | null) {
  const expected = process.env.BROADCAST_OVERLAY_TOKEN?.trim();
  if (!expected || !value) return false;

  const expectedBytes = Buffer.from(expected);
  const providedBytes = Buffer.from(value);
  return expectedBytes.length === providedBytes.length &&
    timingSafeEqual(expectedBytes, providedBytes);
}

export function pairedBroadcastOverlayToken(context: BroadcastAgentContext) {
  const signature = createHmac("sha256", context.tokenHash)
    .update(`overlay|${context.deviceKey}|${context.matchKind}|${context.matchId}|${context.expiresAt}`)
    .digest("base64url");
  return `paired.${context.deviceKey}.${signature}`;
}

export async function authorizeBroadcastOverlay(value: string | null, kind: BroadcastMatchKind, matchId: string) {
  if (!value) return false;
  const db = createSupabaseAdmin();
  if (!value.startsWith("paired.")) {
    // Existing legacy streams may finish with their old overlay. A newly paired
    // match never accepts that deployment-wide credential.
    if (!isValidOverlayToken(value)) return false;
    const { data, error } = await db.from("broadcast_device_credentials").select("device_key")
      .eq("match_kind", kind).eq(kind === "SOLO" ? "open_queue_game_id" : "fixture_id", matchId).limit(1);
    return !error && data?.length === 0;
  }
  const parts = value.split(".");
  if (parts.length !== 3 || !/^paired-[0-9a-f-]{36}$/.test(parts[1])) return false;
  const { data: credential, error } = await db.from("broadcast_device_credentials")
    .select("token_hash").eq("device_key", parts[1]).maybeSingle();
  if (error || !credential) return false;
  const { data: session, error: sessionError } = await db.rpc("broadcast_device_session", { credential_hash: credential.token_hash });
  if (sessionError || session?.matchKind !== kind || session?.matchId !== matchId) return false;
  const expected = pairedBroadcastOverlayToken({ ...session, db, tokenHash: credential.token_hash });
  const expectedBytes = Buffer.from(expected);
  const givenBytes = Buffer.from(value);
  return expectedBytes.length === givenBytes.length && timingSafeEqual(expectedBytes, givenBytes);
}
