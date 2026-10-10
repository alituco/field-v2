import { NextRequest, NextResponse } from "next/server";

import {
  AdminGameNotFoundError,
  loadAdminGameParticipants,
} from "@/lib/admin-game-participants";
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

  try {
    const participants = await loadAdminGameParticipants(
      context.db,
      matchKind,
      gameId,
    );
    return NextResponse.json(
      { participants },
      { headers: PRIVATE_NO_STORE },
    );
  } catch (error) {
    if (error instanceof AdminGameNotFoundError) {
      return NextResponse.json(
        { error: error.message },
        { status: 404, headers: PRIVATE_NO_STORE },
      );
    }
    return NextResponse.json(
      {
        error: error instanceof Error
          ? error.message
          : "Could not load game players.",
      },
      { status: 500, headers: PRIVATE_NO_STORE },
    );
  }
}
