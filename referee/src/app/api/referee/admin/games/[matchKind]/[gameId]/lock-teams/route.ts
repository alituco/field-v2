import { NextRequest, NextResponse } from "next/server";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

export async function POST(request: NextRequest, { params }: { params: Promise<{ matchKind: string; gameId: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const { matchKind, gameId } = await params;
  const headers = { "Cache-Control": "private, no-store" };
  if (matchKind.toUpperCase() !== "SOLO" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(gameId)) {
    return NextResponse.json({ error: "Choose a valid solo game." }, { status: 400, headers });
  }
  const { data, error } = await context.db.rpc("admin_lock_open_queue_teams", {
    actor_admin_id: context.referee.profileId, game_id_to_use: gameId,
  });
  if (error) return NextResponse.json({ error: ["PGRST202", "42883"].includes(error.code ?? "")
    ? "Team locking needs the latest database migration before it can be used." : error.message }, { status: 409, headers });
  return NextResponse.json({ ok: true, ...data }, { headers });
}
