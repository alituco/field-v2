import { NextRequest, NextResponse } from "next/server";

import {
  ensureFixtureBroadcast,
  getBroadcastDevice,
  getFixtureBroadcast,
  queueBroadcastStart,
  queueBroadcastStop,
  syncBroadcastFromCloudflare,
} from "@/lib/broadcasts";
import { assertCanManageFixture } from "@/lib/fixture-access";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";

type RouteContext = {
  params: Promise<{ fixtureId: string }>;
};

type BroadcastAction = {
  action: "prepare" | "start" | "stop";
};

export async function GET(request: NextRequest, context: RouteContext) {
  const refereeContext = await requireReferee(request);
  if (!isRefereeContext(refereeContext)) return refereeContext;

  const { fixtureId } = await context.params;

  try {
    await assertCanManageFixture(
      refereeContext.db,
      fixtureId,
      refereeContext.referee.profileId,
      refereeContext.referee.role,
    );

    const current = await getFixtureBroadcast(refereeContext.db, fixtureId);
    const shouldSync = current?.liveInputId &&
      ["STARTING", "LIVE", "STOPPING", "PROCESSING"].includes(current.status);
    const broadcast = shouldSync
      ? await syncBroadcastFromCloudflare(refereeContext.db, fixtureId)
      : current;
    const device = await getBroadcastDevice(refereeContext.db);
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

  const { fixtureId } = await context.params;

  try {
    await assertCanManageFixture(
      refereeContext.db,
      fixtureId,
      refereeContext.referee.profileId,
      refereeContext.referee.role,
    );
    const body = (await request.json()) as BroadcastAction;

    if (body.action === "prepare") {
      await ensureFixtureBroadcast(
        refereeContext.db,
        fixtureId,
        refereeContext.referee.profileId,
      );
    } else if (body.action === "start") {
      const device = await getBroadcastDevice(refereeContext.db);
      if (!device || device.status === "OFFLINE" || !device.obsConnected) {
        throw new Error("Camera laptop is offline. Open the Field broadcaster first.");
      }
      await queueBroadcastStart(
        refereeContext.db,
        fixtureId,
        refereeContext.referee.profileId,
      );
    } else if (body.action === "stop") {
      await queueBroadcastStop(
        refereeContext.db,
        fixtureId,
        refereeContext.referee.profileId,
      );
    } else {
      return NextResponse.json({ error: "Unknown stream action." }, { status: 400 });
    }

    const [broadcast, device] = await Promise.all([
      getFixtureBroadcast(refereeContext.db, fixtureId),
      getBroadcastDevice(refereeContext.db),
    ]);
    return NextResponse.json({ broadcast, device });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Stream action failed." },
      { status: 400 },
    );
  }
}
