import { NextRequest, NextResponse } from "next/server";

import { parseAdminSoloGameCreateInput } from "@/lib/admin-solo-games";
import { adminFieldsErrorMessage, FIELD_SELECT, parseFieldId, serializeAdminField } from "@/lib/admin-fields";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  try {
    const body = await request.json();
    const fieldId = parseFieldId(body?.fieldId);
    const { data: fieldRow, error: fieldError } = await context.db.from("fields").select(FIELD_SELECT).eq("id", fieldId).single();
    if (fieldError) throw new Error(adminFieldsErrorMessage(fieldError));
    const field = serializeAdminField(fieldRow);
    if (!field.isActive || !field.marketActive) throw new Error("Choose an active field in an available competition city.");
    // Neither a client-supplied timezone nor postal city can move this game's market.
    const input = parseAdminSoloGameCreateInput(body, field.marketTimezone);
    const { data, error } = await context.db.rpc(
      "admin_create_open_queue_game",
      {
        actor_admin_id: context.referee.profileId,
        field_id_to_use: input.fieldId,
        starts_at_to_use: input.startsAt,
        price_fils_to_use: input.priceFils,
        age_label_to_use: input.ageLabel,
        duration_minutes_to_use: input.durationMinutes,
        highest_division_to_use: input.highestDivision,
        lowest_division_to_use: input.lowestDivision,
      },
    );
    if (error) {
      throw new Error(error.code === "23505"
        ? "This pitch already has a game at that time. Choose another time or pitch."
        : adminFieldsErrorMessage(error));
    }
    return NextResponse.json({ gameId: String(data) }, { status: 201 });
  } catch (error) {
    return NextResponse.json(
      {
        error:
          error instanceof Error
            ? error.message
            : "Could not create the solo game.",
      },
      { status: 400 },
    );
  }
}
