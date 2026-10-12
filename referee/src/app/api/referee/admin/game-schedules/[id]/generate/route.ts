import { NextRequest, NextResponse } from "next/server";
import { parseScheduleId, scheduleErrorMessage } from "@/lib/admin-game-schedules";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

export async function POST(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  try {
    const id = parseScheduleId((await params).id);
    const { data, error } = await context.db.rpc("admin_generate_game_schedule", {
      actor_admin_id: context.referee.profileId, schedule_id_to_use: id,
    });
    if (error) throw new Error(scheduleErrorMessage(error));
    return NextResponse.json(data, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not generate games." }, { status: 400 });
  }
}
