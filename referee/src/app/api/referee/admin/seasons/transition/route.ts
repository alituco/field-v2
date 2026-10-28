import { NextRequest, NextResponse } from "next/server";
import { parseAdminSeasonTransitionInput, seasonErrorMessage, serializeAdminSeason } from "@/lib/admin-seasons";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  try {
    const input = parseAdminSeasonTransitionInput(await request.json(), true);
    const { data, error } = await context.db.rpc("admin_schedule_fieldrush_season_transition", { actor_admin_id: context.referee.profileId,
      current_season_id_to_use: input.currentSeasonId, next_season_id_to_use: input.nextSeasonId, starts_on_to_use: input.startsOn,
      reason_to_use: input.reason, expected_current_revision_to_use: input.expectedCurrentRevision, expected_next_revision_to_use: input.expectedNextRevision });
    if (error) return NextResponse.json({ error: seasonErrorMessage(error) }, { status: error.code === "40001" ? 409 : 400, headers });
    return NextResponse.json({ currentSeason: serializeAdminSeason(data.current_season), nextSeason: serializeAdminSeason(data.next_season), startsOn: data.starts_on, scheduled: data.scheduled === true }, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid season transition." }, { status: 400, headers });
  }
}
