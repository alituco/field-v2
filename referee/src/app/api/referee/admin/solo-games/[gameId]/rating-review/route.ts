import { NextRequest, NextResponse } from "next/server";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";
import { assertSeasonZeroAcknowledgement, loadSeasonZeroState, parseSeasonZeroResolution } from "@/lib/season-zero-actions";
import { queueOpenQueueBroadcastStop } from "@/lib/broadcasts";

type RouteContext = { params: Promise<{ gameId: string }> };
const headers = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  try {
    const { gameId } = await route.params;
    return NextResponse.json({ state: await loadSeasonZeroState(context.db, context.referee.profileId, gameId) }, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not load rating evidence." }, { status: 400, headers });
  }
}

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  try {
    const { gameId } = await route.params;
    const body = await request.json();
    if (!Number.isInteger(body.expectedRevision) || body.expectedRevision < 1 || typeof body.requestId !== "string") {
      throw new Error("Refresh the match evidence before submitting a review.");
    }
    const resolution = parseSeasonZeroResolution(body);
    const { data, error } = await context.db.rpc("admin_resolve_season_zero_match", {
      actor_admin_id: context.referee.profileId, game_id_to_use: gameId, request_id_to_use: body.requestId,
      expected_revision: body.expectedRevision, resolution_input: resolution,
    });
    if (error) return NextResponse.json({ error: error.message }, { status: error.code === "40001" ? 409 : 400, headers });
    assertSeasonZeroAcknowledgement(data, gameId, resolution.status !== "pending_review");
    try { await queueOpenQueueBroadcastStop(context.db, gameId, context.referee.profileId); }
    catch (broadcastError) { console.error("Could not stop reviewed solo broadcast", broadcastError); }
    return NextResponse.json({ state: data }, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not save rating review." }, { status: 400, headers });
  }
}
