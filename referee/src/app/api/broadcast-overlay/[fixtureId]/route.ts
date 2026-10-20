import { NextRequest, NextResponse } from "next/server";

import { authorizeBroadcastOverlay } from "@/lib/broadcast-agent-auth";
import { createSupabaseAdmin } from "@/lib/supabase-admin";
import {
  latestOverlayGoal,
  overlayClock,
  overlayHalftimePaused,
  overlayScores,
} from "@/lib/broadcast-overlay-data";

type RouteContext = {
  params: Promise<{ fixtureId: string }>;
};

export async function GET(request: NextRequest, context: RouteContext) {
  const token = request.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "")
    .trim() ?? null;
  const { fixtureId } = await context.params;
  if (!await authorizeBroadcastOverlay(token, "CLAN", fixtureId)) {
    return NextResponse.json({ error: "Invalid overlay token." }, { status: 401, headers: { "Cache-Control": "no-store" } });
  }

  const db = createSupabaseAdmin();

  try {
    const [fixtureResult, clockResult, scorersResult, pauseResult] = await Promise.all([
      db
        .from("fixtures")
        .select(`
          id,
          status,
          home_score,
          away_score,
          home_clan_id,
          away_clan_id,
          home_clan:clans!fixtures_home_clan_id_fkey(name,tag,emblem),
          away_clan:clans!fixtures_away_clan_id_fkey(name,tag,emblem)
        `)
        .eq("id", fixtureId)
        .single(),
      db
        .from("fixture_clock_states")
        .select("status,started_at,accumulated_seconds,duration_seconds,updated_at")
        .eq("fixture_id", fixtureId)
        .maybeSingle(),
      db.from("fixture_scorers")
        .select("id,clan_id,minute,created_at,player:profiles!fixture_scorers_profile_id_fkey(display_name,username)")
        .eq("fixture_id", fixtureId),
      db.from("fixture_events")
        .select("event_type,minute,second,note,occurred_at")
        .eq("fixture_id", fixtureId).eq("event_type", "MATCH_PAUSED")
        .order("occurred_at", { ascending: false }).limit(1).maybeSingle(),
    ]);

    if (fixtureResult.error) throw fixtureResult.error;
    if (clockResult.error) throw clockResult.error;
    if (scorersResult.error) throw scorersResult.error;
    if (pauseResult.error) throw pauseResult.error;

    const fixture = fixtureResult.data;
    const home = firstObject(fixture.home_clan);
    const away = firstObject(fixture.away_clan);
    const goals = scorersResult.data ?? [];
    const clock = overlayClock(clockResult.data);

    return NextResponse.json({
      fixtureId,
      fixtureStatus: String(fixture.status),
      serverTime: new Date().toISOString(),
      // Clan fixtures still use legacy wall-clock slots; do not invent an ISO instant.
      scheduledStart: null,
      timeZone: "Asia/Bahrain",
      home: normalizeClan(home),
      away: normalizeClan(away),
      ...overlayScores({ status: fixture.status, goals, sideField: "clan_id", homeSide: fixture.home_clan_id, awaySide: fixture.away_clan_id, homeScore: fixture.home_score, awayScore: fixture.away_score }),
      clock,
      halftimeSeconds: clock.duration_seconds / 2,
      halftimePaused: overlayHalftimePaused(clock, pauseResult.data),
      latestGoal: latestOverlayGoal(goals, "clan_id", fixture.home_clan_id, fixture.away_clan_id),
    }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load overlay." },
      { status: 500, headers: { "Cache-Control": "no-store" } },
    );
  }
}

function firstObject(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return firstObject(value[0]);
  if (value && typeof value === "object") return value as Record<string, unknown>;
  return {};
}

function normalizeClan(value: Record<string, unknown>) {
  return {
    name: String(value.name ?? "TBD"),
    tag: String(value.tag ?? ""),
    emblem: String(value.emblem ?? "⚽"),
  };
}
