import { NextRequest, NextResponse } from "next/server";
import { parseAdminSeasonTransitionInput, seasonErrorMessage, serializeSeasonTransition } from "@/lib/admin-seasons";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  try {
    const input = parseAdminSeasonTransitionInput(await request.json());
    const { data, error } = await context.db.rpc("admin_preview_fieldrush_season_transition", { actor_admin_id: context.referee.profileId,
      current_season_id_to_use: input.currentSeasonId, next_season_id_to_use: input.nextSeasonId, starts_on_to_use: input.startsOn });
    if (error) return NextResponse.json({ error: seasonErrorMessage(error) }, { status: error.code === "40001" ? 409 : 400, headers });
    return NextResponse.json({ preview: serializeSeasonTransition(data) }, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid season transition." }, { status: 400, headers });
  }
}
