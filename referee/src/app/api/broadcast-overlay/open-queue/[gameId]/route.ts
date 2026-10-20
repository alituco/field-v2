import { NextRequest, NextResponse } from "next/server";

import { authorizeBroadcastOverlay } from "@/lib/broadcast-agent-auth";
import { createSupabaseAdmin } from "@/lib/supabase-admin";
import { soloScheduledDurationSeconds } from "@/lib/match-duration";
import {
  latestOverlayGoal,
  overlayClock,
  overlayHalftimePaused,
  overlayScores,
  overlayTimestamp,
  overlayTimeZone,
} from "@/lib/broadcast-overlay-data";

type RouteContext = { params: Promise<{ gameId: string }> };

export async function GET(request: NextRequest, context: RouteContext) {
  const token = request.headers.get("authorization")
    ?.replace(/^Bearer\s+/i, "")
    .trim() ?? null;
  const { gameId } = await context.params;
  if (!await authorizeBroadcastOverlay(token, "SOLO", gameId)) {
    return NextResponse.json({ error: "Invalid overlay token." }, { status: 401, headers: { "Cache-Control": "no-store" } });
  }
  const db = createSupabaseAdmin();

  try {
    const [gameResult, clockResult, goalsResult, pauseResult] = await Promise.all([
      db.from("open_queue_games")
        .select("id,status,white_score,black_score,starts_at,ends_at,timezone")
        .eq("id", gameId)
        .single(),
      db.from("open_queue_clock_states")
        .select("status,started_at,accumulated_seconds,duration_seconds,updated_at")
        .eq("game_id", gameId)
        .maybeSingle(),
      db.from("open_queue_goals")
        .select("id,team,minute,created_at,player:profiles!open_queue_goals_profile_id_fkey(display_name,username)")
        .eq("game_id", gameId),
      db.from("open_queue_events")
        .select("event_type,minute,second,note,occurred_at")
        .eq("game_id", gameId).eq("event_type", "MATCH_PAUSED")
        .order("occurred_at", { ascending: false }).limit(1).maybeSingle(),
    ]);
    if (gameResult.error) throw gameResult.error;
    if (clockResult.error) throw clockResult.error;
    if (goalsResult.error) throw goalsResult.error;
    if (pauseResult.error) throw pauseResult.error;

    const game = gameResult.data;
    const goals = goalsResult.data ?? [];
    const clock = overlayClock(clockResult.data, soloScheduledDurationSeconds(game.starts_at, game.ends_at));
    return NextResponse.json({
      fixtureId: gameId,
      fixtureStatus: String(game.status),
      serverTime: new Date().toISOString(),
      scheduledStart: overlayTimestamp(game.starts_at),
      timeZone: overlayTimeZone(game.timezone),
      home: { name: "White Team", tag: "WHITE", emblem: "⚪" },
      away: { name: "Black Team", tag: "BLACK", emblem: "⚫" },
      ...overlayScores({ status: game.status, goals, sideField: "team", homeSide: "WHITE", awaySide: "BLACK", homeScore: game.white_score, awayScore: game.black_score }),
      clock,
      halftimeSeconds: clock.duration_seconds / 2,
      halftimePaused: overlayHalftimePaused(clock, pauseResult.data),
      latestGoal: latestOverlayGoal(goals, "team", "WHITE", "BLACK"),
    }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load overlay." },
      { status: 500, headers: { "Cache-Control": "no-store" } },
    );
  }
}
