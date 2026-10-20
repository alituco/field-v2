import { NextRequest, NextResponse } from "next/server";

import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";
import {
  isStagingGameBotsEnabled,
  parseStagingBotFillInput,
  validateStagingBotFillReply,
} from "@/lib/staging-game-bots";

const headers = { "Cache-Control": "private, no-store" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ matchKind: string; gameId: string }> },
) {
  if (!isStagingGameBotsEnabled()) {
    return NextResponse.json({ error: "This test tool is available on Fieldrush staging only." }, { status: 404, headers });
  }
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) {
    context.headers.set("Cache-Control", headers["Cache-Control"]);
    return context;
  }
  const denied = adminOnly(context.referee);
  if (denied) {
    denied.headers.set("Cache-Control", headers["Cache-Control"]);
    return denied;
  }

  let gameId: string;
  let input: ReturnType<typeof parseStagingBotFillInput>;
  try {
    const route = await params;
    if (route.matchKind.toUpperCase() !== "SOLO" || !UUID.test(route.gameId)) {
      throw new Error("Choose a valid solo game.");
    }
    gameId = route.gameId.toLowerCase();
    input = parseStagingBotFillInput(await request.json());
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid bot fill request." }, { status: 400, headers });
  }

  try {
    const { data, error } = await context.db.rpc("admin_fill_open_queue_game_with_bots", {
      actor_admin_id: context.referee.profileId,
      game_id_to_use: gameId,
      request_id_to_use: input.requestId,
    });
    if (error) {
      const missing = ["PGRST202", "42883"].includes(error.code ?? "");
      return NextResponse.json({ error: missing
        ? "Staging bots need the latest database update and staging activation before they can be used."
        : error.message || "Staging bots are unavailable. Check that this staging tool is enabled." },
      { status: missing ? 503 : error.code === "42501" ? 403 : 409, headers });
    }
    try {
      return NextResponse.json(validateStagingBotFillReply(data, { gameId, requestId: input.requestId }), { headers });
    } catch (error) {
      return NextResponse.json({ error: error instanceof Error ? error.message : "The bot fill could not be confirmed." }, { status: 502, headers });
    }
  } catch {
    return NextResponse.json({ error: "The bot fill could not be confirmed. Refresh the game, then retry the same request." }, { status: 502, headers });
  }
}
