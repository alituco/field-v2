import { NextRequest, NextResponse } from "next/server";
import { hashBroadcastCredential, normalizePairingCode, publicBroadcastSession } from "@/lib/broadcast-pairing";
import { createSupabaseAdmin } from "@/lib/supabase-admin";

export async function POST(request: NextRequest) {
  try {
    if (Number(request.headers.get("content-length") ?? 0) > 2048) throw new Error("Pairing request is too large.");
    const body = await request.json();
    const code = normalizePairingCode(body.code);
    if (typeof body.deviceToken !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(body.deviceToken)) throw new Error("Invalid laptop credential.");
    if (typeof body.displayName !== "string" || body.displayName.trim().length < 2 || body.displayName.trim().length > 120) throw new Error("Choose a laptop name between 2 and 120 characters.");
    const { data, error } = await createSupabaseAdmin().rpc("redeem_broadcast_pairing", {
      pair_code_hash: hashBroadcastCredential(code), new_token_hash: hashBroadcastCredential(body.deviceToken),
      laptop_name: body.displayName.trim(),
    });
    if (error) return NextResponse.json({ error: "Pairing code is invalid, expired, already used, or the match is no longer assigned to you." }, { status: ["42501", "P0001"].includes(error.code ?? "") ? 401 : 503 });
    return NextResponse.json(publicBroadcastSession(data), { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not pair laptop." }, { status: 400 });
  }
}
