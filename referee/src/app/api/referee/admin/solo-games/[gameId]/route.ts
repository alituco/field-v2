import { NextRequest, NextResponse } from "next/server";

import { parseAdminSoloGameRemoveInput } from "@/lib/admin-solo-games";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = { params: Promise<{ gameId: string }> };

export async function DELETE(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  try {
    const { gameId } = await route.params;
    const input = parseAdminSoloGameRemoveInput(await request.json());
    const { data, error } = await context.db.rpc(
      "admin_remove_empty_open_queue_game",
      {
        actor_admin_id: context.referee.profileId,
        game_id_to_remove: gameId,
        reason_to_use: input.reason,
      },
    );
    if (error) throw new Error(error.message);
    return NextResponse.json({ removedGame: data });
  } catch (error) {
    return NextResponse.json(
      {
        error:
          error instanceof Error
            ? error.message
            : "Could not remove the solo game.",
      },
      { status: 400 },
    );
  }
}
