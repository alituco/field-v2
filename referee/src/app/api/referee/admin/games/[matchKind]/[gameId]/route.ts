import { NextRequest, NextResponse } from "next/server";

import { loadAdminGameDetail } from "@/lib/admin-game-detail";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = {
  params: Promise<{ matchKind: string; gameId: string }>;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PRIVATE_NO_STORE = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const parsed = await parseGameRoute(route);
  if (parsed instanceof NextResponse) return parsed;
  try {
    return NextResponse.json({
      detail: await loadAdminGameDetail(context.db, parsed.matchKind, parsed.gameId),
    }, { headers: PRIVATE_NO_STORE });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not load game overview.";
    return NextResponse.json(
      { error: message },
      { status: message.toLowerCase().includes("not found") ? 404 : 500, headers: PRIVATE_NO_STORE },
    );
  }
}

async function parseGameRoute(route: RouteContext) {
  const { matchKind: rawMatchKind, gameId } = await route.params;
  const matchKind = rawMatchKind.trim().toUpperCase();
  if (matchKind !== "SOLO" && matchKind !== "CLAN") {
    return NextResponse.json(
      { error: "Game type must be solo or clan." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
  if (!UUID.test(gameId)) {
    return NextResponse.json(
      { error: "Choose a valid game." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
  return { matchKind, gameId } as const;
}
