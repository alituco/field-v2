import { NextRequest, NextResponse } from "next/server";

import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

type RouteContext = { params: Promise<{ matchKind: string; gameId: string }> };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CATEGORIES = new Set([
  "HARASSMENT", "THREATS_OR_VIOLENCE", "DISCRIMINATION", "DANGEROUS_PLAY",
  "CHEATING", "NO_SHOW_OR_MATCH_MANIPULATION", "INAPPROPRIATE_CONTENT",
  "SAFETY_OR_VENUE", "SCORE_OR_RESULT", "REFEREE_ABUSE", "OTHER",
]);
const PRIORITIES = new Set(["LOW", "NORMAL", "HIGH", "URGENT"]);
const PRIVATE_NO_STORE = { "Cache-Control": "private, no-store" };

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const { matchKind, gameId } = await route.params;
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const clanId = text(body?.clanId);
  const category = text(body?.category).toUpperCase();
  const priority = text(body?.priority).toUpperCase();
  const details = text(body?.details);
  const strikeCount = Number(body?.strikeCount ?? 0);

  if (matchKind.toUpperCase() !== "CLAN" || !UUID.test(gameId) || !UUID.test(clanId)) {
    return NextResponse.json(
      { error: "Choose a valid clan fixture and clan." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
  if (!CATEGORIES.has(category) || !PRIORITIES.has(priority)) {
    return NextResponse.json(
      { error: "Choose a valid report reason and priority." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
  if (details.length < 10 || details.length > 2000) {
    return NextResponse.json(
      { error: "Record a clear reason between 10 and 2000 characters." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
  if (!Number.isInteger(strikeCount) || strikeCount < 0 || strikeCount > 3) {
    return NextResponse.json(
      { error: "Issue between zero and three strikes." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }

  const { data, error } = await context.db.rpc("admin_report_game_clan", {
    actor_admin_id: context.referee.profileId,
    fixture_id_to_use: gameId,
    clan_id_to_use: clanId,
    category_to_use: category,
    priority_to_use: priority,
    details_to_use: details,
    strike_count_to_use: strikeCount,
  });
  if (error) {
    return NextResponse.json(
      { error: error.message },
      { status: error.message.toLowerCase().includes("not found") ? 404 : 400, headers: PRIVATE_NO_STORE },
    );
  }
  return NextResponse.json({ ok: true, result: data }, { status: 201, headers: PRIVATE_NO_STORE });
}

function text(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}
