import { NextRequest, NextResponse } from "next/server";
import { adminFieldsErrorMessage, FIELD_SELECT, parseAdminFieldInput, serializeAdminField } from "@/lib/admin-fields";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const HEADERS = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const { data, error } = await context.db.from("fields").select(FIELD_SELECT).order("is_active", { ascending: false }).order("name");
  if (error) return NextResponse.json({ error: adminFieldsErrorMessage(error) }, { status: 500, headers: HEADERS });
  return NextResponse.json({ fields: (data ?? []).map(serializeAdminField) }, { headers: HEADERS });
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  try {
    const values = parseAdminFieldInput(await request.json());
    const { data, error } = await context.db.rpc("admin_save_field", {
      actor_admin_id: context.referee.profileId, field_id_to_update: null, values_to_use: values,
    });
    if (error) return NextResponse.json({ error: adminFieldsErrorMessage(error) }, { status: 400, headers: HEADERS });
    const saved = await context.db.from("fields").select(FIELD_SELECT).eq("id", data.id).single();
    if (saved.error) return NextResponse.json({ error: adminFieldsErrorMessage(saved.error) }, { status: 500, headers: HEADERS });
    return NextResponse.json({ field: serializeAdminField(saved.data) }, { status: 201, headers: HEADERS });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid field details." }, { status: 400, headers: HEADERS });
  }
}
