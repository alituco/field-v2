import { NextRequest, NextResponse } from "next/server";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function PATCH(request: NextRequest, { params }: { params: Promise<{ matchKind: string; gameId: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const { matchKind, gameId } = await params;
  if (matchKind.toUpperCase() !== "SOLO" || !uuid.test(gameId)) {
    return NextResponse.json({ error: "Choose a valid solo game." }, { status: 400, headers });
  }
  const input = await request.json().catch(() => null);
  if (typeof input?.hidden !== "boolean") {
    return NextResponse.json({ error: "Specify whether the game should be hidden." }, { status: 400, headers });
  }

  const { data, error } = await context.db.rpc("admin_set_solo_fixture_visibility", {
    actor_admin_id: context.referee.profileId,
    game_id_to_use: gameId,
    hidden_to_use: input.hidden,
  });
  if (error) {
    const knownStatuses: Record<string, number> = { "42501": 403, P0002: 404, "22023": 409 };
    const status = knownStatuses[error.code] ?? 500;
    const message = status === 500 ? "Could not update fixture visibility." : error.message;
    return NextResponse.json({ error: message }, { status, headers });
  }
  return NextResponse.json({ fixturesHiddenAt: data.fixtures_hidden_at }, { headers });
}
