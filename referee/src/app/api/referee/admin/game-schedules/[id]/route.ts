import { NextRequest, NextResponse } from "next/server";
import { parseAdminGameScheduleInput, parseScheduleId, scheduleErrorMessage } from "@/lib/admin-game-schedules";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

export async function PATCH(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  try {
    const id = parseScheduleId((await params).id);
    const values = parseAdminGameScheduleInput(await request.json(), true);
    const { data, error } = await context.db.rpc("admin_save_game_schedule", {
      actor_admin_id: context.referee.profileId, schedule_id_to_update: id, values_to_use: values,
    });
    if (error) throw new Error(scheduleErrorMessage(error));
    return NextResponse.json({ schedule: data }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not save schedule." }, { status: 400 });
  }
}
