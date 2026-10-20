import { NextRequest, NextResponse } from "next/server";

import {
  ensureOpenQueueBroadcast,
  getBroadcastDevice,
  getOpenQueueBroadcast,
  queueOpenQueueBroadcastStart,
  queueOpenQueueBroadcastStop,
  syncOpenQueueBroadcastFromCloudflare,
} from "@/lib/broadcasts";
import { assertCanManageOpenQueueGame } from "@/lib/fixture-access";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";

type RouteContext = { params: Promise<{ gameId: string }> };
type BroadcastAction = { action: "prepare" | "start" | "stop" };

export async function GET(request: NextRequest, context: RouteContext) {
  const refereeContext = await requireReferee(request);
  if (!isRefereeContext(refereeContext)) return refereeContext;
  const { gameId } = await context.params;

  try {
    await assertCanManageOpenQueueGame(
      refereeContext.db,
      gameId,
      refereeContext.referee.profileId,
      refereeContext.referee.role,
    );
    const current = await getOpenQueueBroadcast(refereeContext.db, gameId);
    const shouldSync = current?.liveInputId &&
      ["STARTING", "LIVE", "STOPPING", "PROCESSING"].includes(current.status);
    const broadcast = shouldSync
      ? await syncOpenQueueBroadcastFromCloudflare(refereeContext.db, gameId)
      : current;
    const device = await getBroadcastDevice(refereeContext.db, "SOLO", gameId);
    return NextResponse.json({ broadcast, device });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load stream." },
      { status: 500 },
    );
  }
}

export async function POST(request: NextRequest, context: RouteContext) {
  const refereeContext = await requireReferee(request);
  if (!isRefereeContext(refereeContext)) return refereeContext;
  const { gameId } = await context.params;

  try {
    await assertCanManageOpenQueueGame(
      refereeContext.db,
      gameId,
      refereeContext.referee.profileId,
      refereeContext.referee.role,
    );
    const body = (await request.json()) as BroadcastAction;
    if (body.action === "prepare") {
      await ensureOpenQueueBroadcast(
        refereeContext.db,
        gameId,
        refereeContext.referee.profileId,
      );
    } else if (body.action === "start") {
      const device = await getBroadcastDevice(refereeContext.db, "SOLO", gameId);
      if (!device || device.status === "OFFLINE" || !device.obsConnected) {
        throw new Error("Camera laptop is offline. Open the Field broadcaster first.");
      }
      if (
        device.obsStreaming &&
        (device.currentOpenQueueGameId !== gameId || device.currentFixtureId)
      ) {
        throw new Error("Camera is already streaming another match.");
      }
      await queueOpenQueueBroadcastStart(
        refereeContext.db,
        gameId,
        refereeContext.referee.profileId,
      );
    } else if (body.action === "stop") {
      const device = await getBroadcastDevice(refereeContext.db, "SOLO", gameId);
      if (
        device?.obsStreaming &&
        (device.currentOpenQueueGameId !== gameId || device.currentFixtureId)
      ) {
        throw new Error("Camera is streaming another match and cannot be stopped here.");
      }
      await queueOpenQueueBroadcastStop(
        refereeContext.db,
        gameId,
        refereeContext.referee.profileId,
      );
    } else {
      return NextResponse.json({ error: "Unknown stream action." }, { status: 400 });
    }

    const [broadcast, device] = await Promise.all([
      getOpenQueueBroadcast(refereeContext.db, gameId),
      getBroadcastDevice(refereeContext.db, "SOLO", gameId),
    ]);
    return NextResponse.json({ broadcast, device });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Stream action failed." },
      { status: 400 },
    );
  }
}
