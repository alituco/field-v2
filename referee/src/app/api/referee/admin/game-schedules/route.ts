import { NextRequest, NextResponse } from "next/server";
import { FIELD_SELECT, serializeAdminField } from "@/lib/admin-fields";
import { parseAdminGameScheduleInput, SCHEDULE_SELECT, scheduleErrorMessage, serializeGameSchedule } from "@/lib/admin-game-schedules";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Phoenix", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  const [schedules, fields, occurrences, skips] = await Promise.all([
    context.db.from("game_schedules").select(SCHEDULE_SELECT).order("created_at", { ascending: false }),
    context.db.from("fields").select(FIELD_SELECT).order("name"),
    context.db.from("game_schedule_occurrences").select("schedule_id,match_date,game_id,status,error_message").gte("match_date", today).order("match_date"),
    context.db.from("game_schedule_skips").select("schedule_id,match_date,reason").gte("match_date", today).order("match_date"),
  ]);
  const error = [schedules, fields, occurrences, skips].find((result) => result.error)?.error;
  if (error) return NextResponse.json({ error: scheduleErrorMessage(error) }, { status: 500, headers });
  const fieldList = (fields.data ?? []).map(serializeAdminField);
  return NextResponse.json({
    fields: fieldList,
    schedules: (schedules.data ?? []).map((row) => serializeGameSchedule(row,
      fieldList.find((field) => field.id === row.field_id)?.name ?? "Unavailable field",
      (occurrences.data ?? []).filter((item) => item.schedule_id === row.id),
      (skips.data ?? []).filter((item) => item.schedule_id === row.id))),
  }, { headers });
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  try {
    const values = parseAdminGameScheduleInput(await request.json());
    const { data, error } = await context.db.rpc("admin_save_game_schedule", {
      actor_admin_id: context.referee.profileId, schedule_id_to_update: null, values_to_use: values,
    });
    if (error) throw new Error(scheduleErrorMessage(error));
    return NextResponse.json({ schedule: data }, { status: 201, headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not save schedule." }, { status: 400, headers });
  }
}
