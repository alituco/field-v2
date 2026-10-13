import { NextRequest, NextResponse } from "next/server";
import { parseCityId } from "@/lib/admin-cities";
import { parseAdminRewardInput, parseRatingTrack, parseSeasonId, seasonErrorMessage, serializeAdminSeasonReward } from "@/lib/admin-seasons";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function PUT(request: NextRequest, { params }: { params: Promise<{ id: string; cityId: string; ratingTrack: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  try {
    const route = await params; const id = parseSeasonId(route.id); const cityId = parseCityId(route.cityId); const track = parseRatingTrack(route.ratingTrack);
    const input = parseAdminRewardInput(await request.json());
    const { data, error } = await context.db.rpc("admin_save_fieldrush_season_reward", { actor_admin_id: context.referee.profileId,
      season_id_to_use: id, city_id_to_use: cityId, rating_track_to_use: track, values_to_use: input.values,
      action_to_use: input.action, reason_to_use: input.reason, expected_revision_to_use: input.expectedRevision });
    if (error) return NextResponse.json({ error: seasonErrorMessage(error) }, { status: error.code === "40001" ? 409 : 400, headers });
    return NextResponse.json({ reward: serializeAdminSeasonReward(data) }, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid cash reward details." }, { status: 400, headers });
  }
}
