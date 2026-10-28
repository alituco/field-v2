import { NextRequest, NextResponse } from "next/server";
import { adminCitiesErrorMessage, parseAdminCityInput, parseCityId, serializeAdminCity } from "@/lib/admin-cities";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function PUT(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  try {
    const id = parseCityId((await params).id);
    const values = parseAdminCityInput(await request.json());
    const { data, error } = await context.db.rpc("admin_save_fieldrush_city", {
      actor_admin_id: context.referee.profileId, city_id_to_use: id, values_to_use: values,
    });
    if (error) return NextResponse.json({ error: adminCitiesErrorMessage(error) }, { status: 400, headers });
    return NextResponse.json({ city: serializeAdminCity(data) }, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid city details." }, { status: 400, headers });
  }
}
