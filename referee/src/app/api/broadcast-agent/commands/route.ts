import { NextRequest, NextResponse } from "next/server";

import {
  broadcastDeviceKey,
  broadcastOverlayToken,
  isBroadcastAgentRequest,
} from "@/lib/broadcast-agent-auth";
import {
  getFixtureBroadcast,
  getStreamCredentials,
  markBroadcastStopped,
  syncBroadcastFromCloudflare,
} from "@/lib/broadcasts";
import { createSupabaseAdmin } from "@/lib/supabase-admin";

type CommandAck = {
  commandId?: string;
  ok?: boolean;
  errorMessage?: string | null;
  obsStreaming?: boolean;
};

export async function GET(request: NextRequest) {
  if (!isBroadcastAgentRequest(request)) {
    return NextResponse.json({ error: "Invalid broadcaster token." }, { status: 401 });
  }

  try {
    const configuredKey = broadcastDeviceKey();
    const requestedKey = request.nextUrl.searchParams.get("deviceKey") || configuredKey;
    if (requestedKey !== configuredKey) throw new Error("Unknown broadcaster device.");

    const db = createSupabaseAdmin();
    const staleClaim = new Date(Date.now() - 45_000).toISOString();
    const { error: resetError } = await db
      .from("broadcast_commands")
      .update({ status: "PENDING", claimed_at: null })
      .eq("device_key", configuredKey)
      .eq("status", "CLAIMED")
      .lt("claimed_at", staleClaim);
    if (resetError) throw resetError;

    const { data: queued, error: queuedError } = await db
      .from("broadcast_commands")
      .select("id,fixture_id,action")
      .eq("device_key", configuredKey)
      .eq("status", "PENDING")
      .lte("available_at", new Date().toISOString())
      .order("created_at")
      .limit(1)
      .maybeSingle();
    if (queuedError) throw queuedError;
    if (!queued) return NextResponse.json({ command: null });

    const { data: claimed, error: claimError } = await db
      .from("broadcast_commands")
      .update({ status: "CLAIMED", claimed_at: new Date().toISOString() })
      .eq("id", queued.id)
      .eq("status", "PENDING")
      .select("id,fixture_id,action")
      .maybeSingle();
    if (claimError) throw claimError;
    if (!claimed) return NextResponse.json({ command: null });

    const fixtureId = String(claimed.fixture_id);
    const broadcast = await getFixtureBroadcast(db, fixtureId);
    if (!broadcast?.liveInputId) throw new Error("Fixture stream input is missing.");

    const command: Record<string, unknown> = {
      id: String(claimed.id),
      fixtureId,
      action: String(claimed.action),
    };

    if (claimed.action === "START_STREAM") {
      const credentials = await getStreamCredentials(broadcast.liveInputId);
      const overlayOrigin = new URL(request.nextUrl.origin);
      if (overlayOrigin.hostname === "localhost") {
        overlayOrigin.hostname = "127.0.0.1";
      }
      const overlayUrl = new URL(
        `/broadcast/obs/${fixtureId}`,
        overlayOrigin,
      );
      overlayUrl.hash = `token=${encodeURIComponent(broadcastOverlayToken())}`;
      command.rtmpsUrl = credentials.url;
      command.streamKey = credentials.streamKey;
      command.overlayUrl = overlayUrl.toString();
    }

    return NextResponse.json({ command });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not claim command." },
      { status: 400 },
    );
  }
}

export async function POST(request: NextRequest) {
  if (!isBroadcastAgentRequest(request)) {
    return NextResponse.json({ error: "Invalid broadcaster token." }, { status: 401 });
  }

  try {
    const body = (await request.json()) as CommandAck;
    if (!body.commandId) throw new Error("Missing command id.");

    const db = createSupabaseAdmin();
    const { data: command, error: commandError } = await db
      .from("broadcast_commands")
      .select("id,fixture_id,device_key,action,status")
      .eq("id", body.commandId)
      .eq("device_key", broadcastDeviceKey())
      .single();
    if (commandError) throw new Error(`Could not load command: ${commandError.message}`);

    const completedAt = new Date().toISOString();
    const ok = body.ok === true;
    const errorMessage = ok ? null : body.errorMessage?.trim() || "OBS command failed.";
    const { error: ackError } = await db
      .from("broadcast_commands")
      .update({
        status: ok ? "ACKNOWLEDGED" : "FAILED",
        completed_at: completedAt,
        error_message: errorMessage,
      })
      .eq("id", command.id);
    if (ackError) throw ackError;

    const fixtureId = String(command.fixture_id);
    if (ok && command.action === "STOP_STREAM") {
      await markBroadcastStopped(db, fixtureId);
    } else if (ok) {
      if (command.action === "START_STREAM" && body.obsStreaming === true) {
        const { error: startedAtError } = await db
          .from("fixture_broadcasts")
          .update({ stream_started_at: completedAt })
          .eq("fixture_id", fixtureId)
          .is("stream_started_at", null);
        if (startedAtError) throw startedAtError;
      }
      await syncBroadcastFromCloudflare(db, fixtureId);
    } else {
      await db
        .from("fixture_broadcasts")
        .update({ status: "ERROR", error_message: errorMessage })
        .eq("fixture_id", fixtureId);
    }

    await db
      .from("broadcast_devices")
      .update({
        status: errorMessage
          ? "ERROR"
          : body.obsStreaming
          ? "STREAMING"
          : "READY",
        obs_streaming: body.obsStreaming === true,
        current_fixture_id: body.obsStreaming ? fixtureId : null,
        error_message: errorMessage,
        last_seen_at: new Date().toISOString(),
      })
      .eq("device_key", broadcastDeviceKey());

    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not acknowledge command." },
      { status: 400 },
    );
  }
}
