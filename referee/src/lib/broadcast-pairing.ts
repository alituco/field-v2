import { createHash, randomInt } from "node:crypto";
import { NextResponse } from "next/server";
import type { SupabaseClient } from "@supabase/supabase-js";
import { createSupabaseAdmin } from "./supabase-admin";

export type BroadcastMatchKind = "SOLO" | "CLAN";
export type BroadcastAgentSession = {
  deviceKey: string;
  displayName: string;
  matchKind: BroadcastMatchKind;
  matchId: string;
  matchLabel: string;
  venue: string;
  startsAt: string | null;
  expiresAt: string;
  ownerId: string;
  refereeName: string;
  status: string;
  matchStatus: string;
};
export type BroadcastAgentContext = BroadcastAgentSession & {
  db: SupabaseClient;
  tokenHash: string;
};

export function hashBroadcastCredential(value: string) {
  return createHash("sha256").update(value).digest("hex");
}

export function newPairingCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  return Array.from({ length: 12 }, () => alphabet[randomInt(alphabet.length)])
    .join("").match(/.{4}/g)!.join("-");
}

export function normalizePairingCode(value: unknown) {
  if (typeof value !== "string") throw new Error("Enter the pairing code from your match page.");
  const code = value.toUpperCase().replace(/[\s-]/g, "");
  if (!/^[A-HJ-NP-Z2-9]{12}$/.test(code)) throw new Error("Enter the 12-character pairing code.");
  return code;
}

export function parseBroadcastTarget(body: Record<string, unknown>) {
  if ((body.matchKind !== "SOLO" && body.matchKind !== "CLAN") ||
      typeof body.matchId !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.matchId)) {
    throw new Error("Choose a valid assigned match.");
  }
  return { matchKind: body.matchKind as BroadcastMatchKind, matchId: body.matchId };
}

export async function getBroadcastAgentContext(request: Request): Promise<BroadcastAgentContext | NextResponse> {
  const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "").trim();
  if (!token || !/^[A-Za-z0-9_-]{43}$/.test(token)) {
    return NextResponse.json({ error: "Pair this laptop with a match first." }, { status: 401 });
  }
  const db = createSupabaseAdmin();
  const tokenHash = hashBroadcastCredential(token);
  const { data, error } = await db.rpc("broadcast_device_session", { credential_hash: tokenHash });
  if (error && !["42501", "P0001"].includes(error.code ?? "")) {
    return NextResponse.json({ error: "Could not check laptop pairing. Reconnecting shortly." }, { status: 503 });
  }
  if (error || !data?.deviceKey) {
    return NextResponse.json({ error: "Laptop pairing expired or was disconnected. Pair it again." }, { status: 401 });
  }
  return { ...data as BroadcastAgentSession, db, tokenHash };
}

export function publicBroadcastSession(session: BroadcastAgentSession) {
  return {
    deviceKey: session.deviceKey,
    displayName: session.displayName,
    matchKind: session.matchKind,
    matchId: session.matchId,
    matchLabel: session.matchLabel,
    venue: session.venue,
    startsAt: session.startsAt,
    expiresAt: session.expiresAt,
    refereeName: session.refereeName,
    status: session.status,
  };
}

export async function getPairedBroadcastDevice(db: SupabaseClient, kind: BroadcastMatchKind, matchId: string) {
  const { data: credential, error } = await db.from("broadcast_device_credentials")
    .select("device_key,expires_at,owner_profile_id,reservation_active,revoked_at,test_input_id")
    .eq("match_kind", kind)
    .eq(kind === "SOLO" ? "open_queue_game_id" : "fixture_id", matchId)
    // A revoked device with unresolved provider cleanup must remain visible so
    // an admin can retry. Never hide the held pitch just because auth is revoked.
    .or("revoked_at.is.null,reservation_active.eq.true,test_input_id.not.is.null")
    .order("reservation_active", { ascending: false }).order("test_input_id", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: false })
    .limit(1).maybeSingle();
  if (error) throw new Error(`Could not load paired laptop: ${error.message}`);
  if (!credential) return null;
  const { data, error: deviceError } = await db.from("broadcast_devices").select("*")
    .eq("device_key", credential.device_key).single();
  if (deviceError) throw new Error(`Could not load paired laptop: ${deviceError.message}`);
  const expired = credential.revoked_at != null || Date.parse(credential.expires_at) <= Date.now();
  const stale = !data.last_seen_at || Date.parse(data.last_seen_at) < Date.now() - 15_000;
  return {
    deviceKey: String(data.device_key), displayName: String(data.display_name),
    status: expired || stale ? "OFFLINE" as const : data.status as "OFFLINE" | "READY" | "STREAMING" | "ERROR",
    obsConnected: !expired && !stale && data.obs_connected === true,
    obsStreaming: data.obs_streaming === true,
    currentFixtureId: data.current_fixture_id as string | null,
    currentOpenQueueGameId: data.current_open_queue_game_id as string | null,
    lastSeenAt: data.last_seen_at as string | null, errorMessage: data.error_message as string | null,
    expiresAt: String(credential.expires_at),
    revokedAt: credential.revoked_at as string | null,
    reservationActive: credential.reservation_active === true,
    testCleanupPending: credential.test_input_id != null,
  };
}
