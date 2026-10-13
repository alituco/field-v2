import { NextRequest, NextResponse } from "next/server";
import { CITY_SELECT, serializeAdminCity } from "@/lib/admin-cities";
import { seasonErrorMessage, serializeAdminSeason, serializeAdminSeasonReward, serializeSeasonAudit } from "@/lib/admin-seasons";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  const [catalog, cities] = await Promise.all([
    context.db.rpc("admin_list_fieldrush_seasons", { actor_admin_id: context.referee.profileId }),
    context.db.from("fieldrush_cities").select(CITY_SELECT).order("display_name"),
  ]);
  const error = catalog.error ?? cities.error;
  if (error) return NextResponse.json({ error: seasonErrorMessage(error) }, { status: 500, headers });
  return NextResponse.json({ today: catalog.data.today,
    seasons: (catalog.data.seasons ?? []).map(serializeAdminSeason), rewards: (catalog.data.rewards ?? []).map(serializeAdminSeasonReward),
    audit: (catalog.data.audit ?? []).map(serializeSeasonAudit), cities: (cities.data ?? []).map(serializeAdminCity) }, { headers });
}
