import { NextRequest, NextResponse } from "next/server";

import { getBroadcastAgentContext } from "@/lib/broadcast-pairing";
import { syncBroadcastFromCloudflare } from "@/lib/broadcasts";
import { syncOpenQueueBroadcastFromCloudflare } from "@/lib/broadcasts";

type HeartbeatBody = {
  deviceKey?: string;
  displayName?: string;
  obsConnected?: boolean;
  obsStreaming?: boolean;
  currentFixtureId?: string | null;
  currentOpenQueueGameId?: string | null;
  errorMessage?: string | null;
  metadata?: Record<string, unknown>;
};

export async function POST(request: NextRequest) {
  const context = await getBroadcastAgentContext(request);
  if (context instanceof NextResponse) return context;

  try {
    const body = (await request.json()) as HeartbeatBody;
    const configuredKey = context.deviceKey;
    if (body.deviceKey && body.deviceKey !== configuredKey) {
      throw new Error("This broadcaster is not registered for the configured pitch.");
    }

    const db = context.db;
    if (body.currentFixtureId && body.currentOpenQueueGameId) {
      throw new Error("The camera can only stream one match at a time.");
    }
    if ((body.currentFixtureId && (context.matchKind !== "CLAN" || body.currentFixtureId !== context.matchId)) ||
        (body.currentOpenQueueGameId && (context.matchKind !== "SOLO" || body.currentOpenQueueGameId !== context.matchId))) {
      throw new Error("This laptop is paired to a different match.");
    }
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
    const { error } = await db.from("broadcast_devices").update(
      {
        status,
        obs_connected: obsConnected,
        obs_streaming: obsStreaming,
        current_fixture_id: body.currentFixtureId || null,
        current_open_queue_game_id: body.currentOpenQueueGameId || null,
        last_seen_at: new Date().toISOString(),
        error_message: errorMessage,
        metadata: body.metadata ?? {},
      },
    ).eq("device_key", configuredKey);
    if (error) throw new Error(`Could not save broadcaster heartbeat: ${error.message}`);

    if (body.currentFixtureId) {
      await syncBroadcastFromCloudflare(db, body.currentFixtureId);
    } else if (body.currentOpenQueueGameId) {
      await syncOpenQueueBroadcastFromCloudflare(db, body.currentOpenQueueGameId);
    }

    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Heartbeat failed." },
      { status: 400 },
    );
  }
}
