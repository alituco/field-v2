import { NextRequest, NextResponse } from "next/server";

import { parseAdminMatchResolutionReopenInput } from "@/lib/match-action-input";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = {
  params: Promise<{ matchKind: string; gameId: string }>;
};

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PRIVATE_NO_STORE = { "Cache-Control": "private, no-store" };

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const { matchKind: rawMatchKind, gameId } = await route.params;
  const matchKind = rawMatchKind.trim().toUpperCase();
  if (!["SOLO", "CLAN"].includes(matchKind) || !UUID.test(gameId)) {
    return NextResponse.json(
      { error: "Choose a valid clan or solo game." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }

  try {
    const input = parseAdminMatchResolutionReopenInput(
      await request.json() as Record<string, unknown>,
    );
    const matchColumn = matchKind === "CLAN"
      ? "fixture_id"
      : "open_queue_game_id";
    const { data: reviewCase, error: caseError } = await context.db
      .from("match_resolution_cases")
      .select("id")
      .eq("id", input.caseId)
      .eq("match_kind", matchKind)
      .eq(matchColumn, gameId)
      .maybeSingle();
    if (caseError) throw new Error(caseError.message);
    if (!reviewCase) {
      return NextResponse.json(
        { error: "Match resolution case not found for this game." },
        { status: 404, headers: PRIVATE_NO_STORE },
      );
    }

    const { data, error } = await context.db.rpc(
      "admin_reopen_match_resolution",
      {
        actor_admin_id: context.referee.profileId,
        case_id_to_reopen: input.caseId,
        reason_to_use: input.reason,
      },
    );
    if (error) throw new Error(error.message);

    return NextResponse.json(
      {
        ok: true,
        result: data && typeof data === "object" ? data : { id: String(data) },
      },
      { headers: PRIVATE_NO_STORE },
    );
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "Could not reopen this match resolution.";
    return NextResponse.json(
      { error: message },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
}
