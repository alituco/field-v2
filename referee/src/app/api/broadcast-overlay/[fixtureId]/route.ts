import { NextRequest, NextResponse } from "next/server";

import { isValidOverlayToken } from "@/lib/broadcast-agent-auth";
import { createSupabaseAdmin } from "@/lib/supabase-admin";

type RouteContext = {
  params: Promise<{ fixtureId: string }>;
};

export async function GET(request: NextRequest, context: RouteContext) {
  const token = request.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "")
    .trim() ?? null;
  if (!isValidOverlayToken(token)) {
    return NextResponse.json({ error: "Invalid overlay token." }, { status: 401 });
  }

  const { fixtureId } = await context.params;
  const db = createSupabaseAdmin();

  try {
    const [fixtureResult, clockResult, scorersResult] = await Promise.all([
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
        .select("status,started_at,accumulated_seconds,duration_seconds")
        .eq("fixture_id", fixtureId)
        .maybeSingle(),
      db.from("fixture_scorers").select("clan_id").eq("fixture_id", fixtureId),
    ]);

    if (fixtureResult.error) throw fixtureResult.error;
    if (clockResult.error) throw clockResult.error;
    if (scorersResult.error) throw scorersResult.error;

    const fixture = fixtureResult.data;
    const home = firstObject(fixture.home_clan);
    const away = firstObject(fixture.away_clan);
    const homeScore = scorersResult.data?.filter(
      (row) => String(row.clan_id) === String(fixture.home_clan_id),
    ).length ?? Number(fixture.home_score ?? 0);
    const awayScore = scorersResult.data?.filter(
      (row) => String(row.clan_id) === String(fixture.away_clan_id),
    ).length ?? Number(fixture.away_score ?? 0);

    return NextResponse.json({
      fixtureId,
      fixtureStatus: String(fixture.status),
      home: normalizeClan(home),
      away: normalizeClan(away),
      homeScore,
      awayScore,
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
