import { NextRequest, NextResponse } from "next/server";

import { loadAdminSubjectDetail } from "@/lib/admin-subject-detail";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

type RouteContext = { params: Promise<{ subjectType: string; subjectId: string }> };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function GET(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const { subjectType: rawType, subjectId } = await route.params;
  const subjectType = rawType.toUpperCase();
  if (!UUID.test(subjectId) || (subjectType !== "PLAYER" && subjectType !== "CLAN")) {
    return NextResponse.json({ error: "Choose a valid player or clan." }, { status: 400 });
  }
  try {
    return NextResponse.json({ detail: await loadAdminSubjectDetail(context.db, subjectType, subjectId) }, {
      headers: { "Cache-Control": "private, no-store" },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not load this record.";
    return NextResponse.json({ error: message }, { status: message.toLowerCase().includes("not found") ? 404 : 500 });
  }
}
