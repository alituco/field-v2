import { NextRequest, NextResponse } from "next/server";
import { parseAdminSeasonEndPreviewInput, parseSeasonId, seasonErrorMessage, serializeSeasonEndPreview } from "@/lib/admin-seasons";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function POST(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  try {
    const id = parseSeasonId((await params).id); const input = parseAdminSeasonEndPreviewInput(await request.json());
    const { data, error } = await context.db.rpc("admin_preview_fieldrush_season_end", { actor_admin_id: context.referee.profileId,
      season_id_to_use: id, ends_on_to_use: input.endsOn });
    if (error) return NextResponse.json({ error: seasonErrorMessage(error) }, { status: error.code === "40001" ? 409 : 400, headers });
    return NextResponse.json({ preview: serializeSeasonEndPreview(data) }, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid season end date." }, { status: 400, headers });
  }
}
