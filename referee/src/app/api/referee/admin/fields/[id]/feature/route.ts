import { NextRequest, NextResponse } from "next/server";
import { adminFieldsErrorMessage, FIELD_SELECT, parseFeaturedFieldInput, parseFieldId, serializeAdminField } from "@/lib/admin-fields";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const HEADERS = { "Cache-Control": "private, no-store" };

export async function PATCH(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  try {
    const fieldId = parseFieldId((await params).id);
    const input = parseFeaturedFieldInput(await request.json());
    const { error } = await context.db.rpc("admin_set_featured_field", {
      actor_admin_id: context.referee.profileId,
      city_id_to_use: input.cityId,
      field_id_to_use: fieldId,
      featured_to_use: input.featured,
    });
    if (error) return NextResponse.json({ error: adminFieldsErrorMessage(error) }, { status: 400, headers: HEADERS });
    const saved = await context.db.from("fields").select(FIELD_SELECT).order("is_active", { ascending: false }).order("name");
    if (saved.error) return NextResponse.json({ error: adminFieldsErrorMessage(saved.error) }, { status: 500, headers: HEADERS });
    return NextResponse.json({ fields: (saved.data ?? []).map(serializeAdminField) }, { headers: HEADERS });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not update the featured field." }, { status: 400, headers: HEADERS });
  }
}
