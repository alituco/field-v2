import { NextRequest, NextResponse } from "next/server";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const headers = { "Cache-Control": "private, no-store" };

export async function POST(request: NextRequest, { params }: { params: Promise<{ matchKind: string; gameId: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const { matchKind, gameId } = await params;
  if (matchKind.toUpperCase() !== "SOLO" || !UUID.test(gameId)) {
    return NextResponse.json({ error: "Choose a valid solo game." }, { status: 400, headers });
  }
  let body: unknown;
  try { body = await request.json(); }
  catch { return NextResponse.json({ error: "Choose the unassigned players and their teams." }, { status: 400, headers }); }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return NextResponse.json({ error: "Choose the unassigned players and their teams." }, { status: 400, headers });
  }
  const { requestId, assignments } = body as Record<string, unknown>;
  if (typeof requestId !== "string" || !UUID.test(requestId) || !Array.isArray(assignments) ||
    assignments.length < 1 || assignments.length > 14 || assignments.some(value =>
      !value || typeof value !== "object" || Array.isArray(value) ||
      typeof value.profileId !== "string" || !UUID.test(value.profileId) || !["WHITE", "BLACK"].includes(value.team)) ||
    new Set(assignments.map(value => value.profileId)).size !== assignments.length) {
    return NextResponse.json({ error: "Choose each unassigned player once and select White or Black." }, { status: 400, headers });
  }
  const { data, error } = await context.db.rpc("admin_assign_unassigned_open_queue_players", {
    actor_admin_id: context.referee.profileId, game_id_to_use: gameId, request_id_to_use: requestId,
    assignments_input: assignments.map(value => ({ profile_id: value.profileId, to_team: value.team })),
  });
  if (error) return NextResponse.json({ error: ["PGRST202", "42883"].includes(error.code ?? "")
    ? "Player assignment needs the latest database migration before it can be used." : error.message }, { status: 409, headers });
  if (!data || data.game_id !== gameId || data.request_id !== requestId || data.action !== "ASSIGN_UNASSIGNED" || data.assigned_count !== assignments.length) {
    return NextResponse.json({ error: "Player assignment was not acknowledged. Retry the same request before making another change." }, { status: 502, headers });
  }
  return NextResponse.json({ ok: true, assignment: data }, { headers });
}
