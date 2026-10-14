import { NextRequest, NextResponse } from "next/server";
import { parseAdminSeasonDuplicateInput, parseSeasonId, seasonErrorMessage, serializeAdminSeason } from "@/lib/admin-seasons";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function POST(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  try {
    const id = parseSeasonId((await params).id);
    const input = parseAdminSeasonDuplicateInput(await request.json());
    if (input.id === id) throw new Error("Choose a new season ID.");
    const { data, error } = await context.db.rpc("admin_duplicate_fieldrush_season", { actor_admin_id: context.referee.profileId,
      source_season_id_to_use: id, new_season_id_to_use: input.id, values_to_use: input.values,
      expected_source_revision_to_use: input.expectedSourceRevision });
    if (error) return NextResponse.json({ error: seasonErrorMessage(error) }, { status: error.code === "40001" ? 409 : 400, headers });
    return NextResponse.json({ season: serializeAdminSeason(data) }, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid new season details." }, { status: 400, headers });
  }
}
