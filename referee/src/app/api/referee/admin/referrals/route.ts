import { NextRequest, NextResponse } from "next/server";
import { referralError, serializeAdminReferrals } from "@/lib/admin-referrals";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const { data, error } = await context.db.rpc("admin_get_fieldrush_referrals", {
    actor_admin_id: context.referee.profileId,
  });
  if (error) {
    const failure = referralError(error);
    return NextResponse.json({ error: failure.message }, { status: failure.status, headers });
  }
  try { return NextResponse.json(serializeAdminReferrals(data), { headers }); }
  catch { return NextResponse.json({ error: "Could not read the referral standings. Try again." }, { status: 500, headers }); }
}
