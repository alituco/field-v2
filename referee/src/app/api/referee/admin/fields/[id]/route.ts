import { NextRequest, NextResponse } from "next/server";
import { adminFieldsErrorMessage, parseAdminFieldInput, parseFieldId, serializeAdminField } from "@/lib/admin-fields";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const HEADERS = { "Cache-Control": "private, no-store" };

export async function PATCH(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  try {
    const fieldId = parseFieldId((await params).id);
    const values = parseAdminFieldInput(await request.json(), true);
    const { data, error } = await context.db.rpc("admin_save_field", {
      actor_admin_id: context.referee.profileId, field_id_to_update: fieldId, values_to_use: values,
    });
    if (error) return NextResponse.json({ error: adminFieldsErrorMessage(error) }, { status: 400, headers: HEADERS });
    return NextResponse.json({ field: serializeAdminField(data) }, { headers: HEADERS });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid field details." }, { status: 400, headers: HEADERS });
  }
}
