import { NextRequest, NextResponse } from "next/server";
import { parseReferralTieReview, referralError, serializeAdminReferrals } from "@/lib/admin-referrals";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  let input;
  try { input = parseReferralTieReview(await request.json()); }
  catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Check the referral review details." }, { status: 400, headers });
  }
  const { data, error } = await context.db.rpc("admin_review_fieldrush_referral_tie", {
    actor_admin_id: context.referee.profileId,
    evidence_token_to_use: input.evidenceToken,
    ordered_profile_ids: input.orderedProfileIds,
    review_note: input.note,
  });
  if (error) {
    const failure = referralError(error);
    return NextResponse.json({ error: failure.message }, { status: failure.status, headers });
  }
  try { return NextResponse.json({ ok: true, referrals: serializeAdminReferrals(data) }, { headers }); }
  catch {
    return NextResponse.json({ ok: true, warning: "The review was saved, but the standings could not be refreshed. Refresh before making another decision." }, { headers });
  }
}
