import { NextRequest, NextResponse } from "next/server";

import { parseAdminSoloGameCreateInput } from "@/lib/admin-solo-games";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  try {
    const input = parseAdminSoloGameCreateInput(await request.json());
    const { data, error } = await context.db.rpc(
      "admin_create_open_queue_game",
      {
        actor_admin_id: context.referee.profileId,
        venue_to_use: input.venue,
        starts_at_to_use: input.startsAt,
        price_fils_to_use: input.priceFils,
        age_label_to_use: input.ageLabel,
      },
    );
    if (error) throw new Error(error.message);
    return NextResponse.json({ gameId: String(data) }, { status: 201 });
  } catch (error) {
    return NextResponse.json(
      {
        error:
          error instanceof Error
            ? error.message
            : "Could not create the solo game.",
      },
      { status: 400 },
    );
  }
}
