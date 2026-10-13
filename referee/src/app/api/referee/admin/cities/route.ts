import { NextRequest, NextResponse } from "next/server";
import { adminCitiesErrorMessage, CITY_SELECT, serializeAdminCity } from "@/lib/admin-cities";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const { data, error } = await context.db.from("fieldrush_cities").select(CITY_SELECT).order("active", { ascending: false }).order("display_name");
  if (error) return NextResponse.json({ error: adminCitiesErrorMessage(error) }, { status: 500, headers });
  return NextResponse.json({ cities: (data ?? []).map(serializeAdminCity) }, { headers });
}
