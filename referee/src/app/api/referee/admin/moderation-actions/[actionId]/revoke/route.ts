import { NextRequest, NextResponse } from "next/server";

import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = { params: Promise<{ actionId: string }> };

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const { actionId } = await route.params;
  const body = (await request.json().catch(() => null)) as { reason?: unknown } | null;
  const reason = typeof body?.reason === "string" ? body.reason.trim() : "";
  if (reason.length < 8) {
    return NextResponse.json(
      { error: "Add a clear revocation reason for the audit log." },
      { status: 400 },
    );
  }

  const { error } = await context.db.rpc("admin_revoke_moderation_action", {
    actor_admin_id: context.referee.profileId,
    action_id_to_revoke: actionId,
    reason_to_use: reason,
  });
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }
  return NextResponse.json({ ok: true });
}
