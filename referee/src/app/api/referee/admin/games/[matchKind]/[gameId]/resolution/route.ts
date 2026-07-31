import { NextRequest, NextResponse } from "next/server";

import { parseAdminMatchResolutionInput } from "@/lib/match-action-input";
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
    const resolution = parseAdminMatchResolutionInput(
      await request.json() as Record<string, unknown>,
    );
    const { data, error } = await context.db.rpc("admin_resolve_match_case", {
      actor_admin_id: context.referee.profileId,
      match_kind_to_use: matchKind,
      match_id_to_use: gameId,
      expected_revision_to_use: resolution.expectedRevision,
      resolution_type_to_use: resolution.resolutionType,
      reason_to_use: resolution.reason,
      payload_to_use: resolution.payload,
    });
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
      : "Could not resolve this match.";
    const stale = /revision|refresh|changed by another/i.test(message);
    return NextResponse.json(
      { error: message },
      { status: stale ? 409 : 400, headers: PRIVATE_NO_STORE },
    );
  }
}
