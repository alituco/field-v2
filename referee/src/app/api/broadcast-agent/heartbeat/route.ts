import { NextRequest, NextResponse } from "next/server";

import {
  broadcastDeviceKey,
  broadcastDeviceName,
  isBroadcastAgentRequest,
} from "@/lib/broadcast-agent-auth";
import { syncBroadcastFromCloudflare } from "@/lib/broadcasts";
import { createSupabaseAdmin } from "@/lib/supabase-admin";

type HeartbeatBody = {
  deviceKey?: string;
  displayName?: string;
  obsConnected?: boolean;
  obsStreaming?: boolean;
  currentFixtureId?: string | null;
  errorMessage?: string | null;
  metadata?: Record<string, unknown>;
};

export async function POST(request: NextRequest) {
  if (!isBroadcastAgentRequest(request)) {
    return NextResponse.json({ error: "Invalid broadcaster token." }, { status: 401 });
  }

  try {
    const body = (await request.json()) as HeartbeatBody;
    const configuredKey = broadcastDeviceKey();
    if (body.deviceKey && body.deviceKey !== configuredKey) {
      throw new Error("This broadcaster is not registered for the configured pitch.");
    }

    const db = createSupabaseAdmin();
    const obsConnected = body.obsConnected === true;
    const obsStreaming = body.obsStreaming === true;
    const errorMessage = body.errorMessage?.trim() || null;
    const status = errorMessage
      ? "ERROR"
      : obsStreaming
      ? "STREAMING"
      : obsConnected
      ? "READY"
      : "OFFLINE";
    const { error } = await db.from("broadcast_devices").upsert(
      {
        device_key: configuredKey,
        display_name: body.displayName?.trim() || broadcastDeviceName(),
        status,
        obs_connected: obsConnected,
        obs_streaming: obsStreaming,
        current_fixture_id: body.currentFixtureId || null,
        last_seen_at: new Date().toISOString(),
        error_message: errorMessage,
        metadata: body.metadata ?? {},
      },
      { onConflict: "device_key" },
    );
    if (error) throw new Error(`Could not save broadcaster heartbeat: ${error.message}`);

    if (body.currentFixtureId) {
      await syncBroadcastFromCloudflare(db, body.currentFixtureId);
    }

    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Heartbeat failed." },
      { status: 400 },
    );
  }
}

