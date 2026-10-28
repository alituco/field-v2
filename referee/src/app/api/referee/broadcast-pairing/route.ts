import { NextRequest, NextResponse } from "next/server";
import { getPairedBroadcastDevice, hashBroadcastCredential, newPairingCode, normalizePairingCode, parseBroadcastTarget } from "@/lib/broadcast-pairing";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";
import { setCloudflareLiveInputEnabled } from "@/lib/cloudflare-stream";
import { markBroadcastStopped, markOpenQueueBroadcastStopped } from "@/lib/broadcasts";
import { cleanupRevokedCameraTest, cloudflareCameraTestProvider } from "@/lib/broadcast-camera-test";

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  try {
    const target = parseBroadcastTarget(Object.fromEntries(request.nextUrl.searchParams));
    const { error } = await context.db.rpc("broadcast_match_context", {
      actor_id: context.referee.profileId, kind: target.matchKind, target_id: target.matchId,
    });
    if (error) throw new Error(error.message);
    return NextResponse.json({ device: await getPairedBroadcastDevice(context.db, target.matchKind, target.matchId) }, {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not load laptop." }, { status: 400 });
  }
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  try {
    const target = parseBroadcastTarget(await request.json());
    const code = newPairingCode();
    const { data, error } = await context.db.rpc("create_broadcast_pairing", {
      actor_id: context.referee.profileId, kind: target.matchKind, target_id: target.matchId,
      new_code_hash: hashBroadcastCredential(normalizePairingCode(code)),
    });
    if (error) throw new Error(error.message);
    return NextResponse.json({ code, expiresAt: data }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not create pairing code." }, { status: 400 });
  }
}

export async function DELETE(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  try {
    const body = await request.json();
    if (typeof body.deviceKey !== "string" || !/^paired-[0-9a-f-]{36}$/.test(body.deviceKey)) throw new Error("Choose a paired laptop.");
    if (body.force === true) {
      const { data, error } = await context.db.rpc("begin_broadcast_device_revocation", {
        actor_id: context.referee.profileId, target_device_key: body.deviceKey,
      });
      if (error) throw new Error(error.message);
      if (data.inputId) {
        await setCloudflareLiveInputEnabled(data.inputId, false);
        if (data.matchKind === "SOLO") await markOpenQueueBroadcastStopped(context.db, data.matchId);
        else await markBroadcastStopped(context.db, data.matchId);
      }
      if (data.testInputId) {
        await cleanupRevokedCameraTest(
          { db: context.db, deviceKey: body.deviceKey },
          String(data.testInputId),
          cloudflareCameraTestProvider(),
        );
      }
      const { data: released, error: releaseError } = await context.db.from("broadcast_device_credentials")
        .update({ reservation_active: false }).eq("device_key", body.deviceKey)
        .not("revoked_at", "is", null).is("test_input_id", null)
        .select("device_key").maybeSingle();
      if (releaseError) throw releaseError;
      if (!released) throw new Error("The laptop still has pending test cleanup. Retry administrator cleanup before releasing it.");
      const { error: deviceError } = await context.db.from("broadcast_devices")
        .update({ status: "OFFLINE", obs_connected: false, obs_streaming: false }).eq("device_key", body.deviceKey);
      if (deviceError) throw deviceError;
      return NextResponse.json({ ok: true });
    }
    const { error } = await context.db.rpc("revoke_broadcast_device", {
      actor_id: context.referee.profileId, target_device_key: body.deviceKey,
    });
    if (error) throw new Error(error.message);
    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not disconnect laptop." }, { status: 400 });
  }
}
