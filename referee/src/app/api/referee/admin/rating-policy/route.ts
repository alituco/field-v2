import { NextRequest, NextResponse } from "next/server";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  const { data, error } = await context.db.rpc("admin_get_season_zero_policy", { actor_admin_id: context.referee.profileId });
  return error ? NextResponse.json({ error: error.message }, { status: 400, headers })
    : NextResponse.json({ policy: data }, { headers });
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee); if (denied) return denied;
  try {
    const body = await request.json();
    if (typeof body.enabled !== "boolean" || typeof body.reason !== "string" || body.reason.trim().length < 10 || body.reason.length > 500 || body.confirmed !== true) {
      throw new Error("Confirm this prospective policy change and provide a reason of at least ten characters.");
    }
    const { data, error } = await context.db.rpc("admin_set_season_zero_policy", {
      actor_admin_id: context.referee.profileId, enabled_to_use: body.enabled, reason_to_use: body.reason.trim(),
    });
    if (error) throw new Error(error.message);
    return NextResponse.json({ policy: data }, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not update rating policy." }, { status: 400, headers });
  }
}
