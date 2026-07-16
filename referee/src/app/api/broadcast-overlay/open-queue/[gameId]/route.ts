import { NextRequest, NextResponse } from "next/server";

import { isValidOverlayToken } from "@/lib/broadcast-agent-auth";
import { createSupabaseAdmin } from "@/lib/supabase-admin";

type RouteContext = { params: Promise<{ gameId: string }> };

export async function GET(request: NextRequest, context: RouteContext) {
  const token = request.headers.get("authorization")
    ?.replace(/^Bearer\s+/i, "")
    .trim() ?? null;
  if (!isValidOverlayToken(token)) {
    return NextResponse.json({ error: "Invalid overlay token." }, { status: 401 });
  }
  const { gameId } = await context.params;
  const db = createSupabaseAdmin();

  try {
    const [gameResult, clockResult, goalsResult] = await Promise.all([
      db.from("open_queue_games")
        .select("id,status,white_score,black_score")
        .eq("id", gameId)
        .single(),
      db.from("open_queue_clock_states")
        .select("status,started_at,accumulated_seconds,duration_seconds")
        .eq("game_id", gameId)
        .maybeSingle(),
      db.from("open_queue_goals").select("team").eq("game_id", gameId),
    ]);
    if (gameResult.error) throw gameResult.error;
    if (clockResult.error) throw clockResult.error;
    if (goalsResult.error) throw goalsResult.error;

    const goals = goalsResult.data ?? [];
    const whiteGoals = goals.filter((goal) => goal.team === "WHITE").length;
    const blackGoals = goals.filter((goal) => goal.team === "BLACK").length;
    return NextResponse.json({
      fixtureId: gameId,
      fixtureStatus: String(gameResult.data.status),
      home: { name: "White Team", tag: "WHITE", emblem: "⚪" },
      away: { name: "Black Team", tag: "BLACK", emblem: "⚫" },
      homeScore: goals.length > 0
        ? whiteGoals
        : Number(gameResult.data.white_score ?? 0),
      awayScore: goals.length > 0
        ? blackGoals
        : Number(gameResult.data.black_score ?? 0),
      clock: clockResult.data ?? {
        status: "NOT_STARTED",
        started_at: null,
        accumulated_seconds: 0,
        duration_seconds: 3600,
      },
    });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load overlay." },
      { status: 500 },
    );
  }
}
