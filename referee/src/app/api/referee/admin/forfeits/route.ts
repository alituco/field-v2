import { NextRequest, NextResponse } from "next/server";

import {
  FORFEIT_REVIEW_STATES,
  loadAdminForfeits,
  type ForfeitReviewState,
} from "@/lib/admin-forfeits";
import { parseAdminForfeitReviewInput } from "@/lib/match-action-input";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const rawState = request.nextUrl.searchParams.get("status")?.toUpperCase() ?? null;
  if (rawState && !FORFEIT_REVIEW_STATES.includes(rawState as ForfeitReviewState)) {
    return NextResponse.json({ error: "Choose a valid forfeit review status." }, { status: 400 });
  }

  try {
    const forfeits = await loadAdminForfeits(
      context.db,
      rawState as ForfeitReviewState | null,
    );
    return NextResponse.json({ forfeits });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load forfeits." },
      { status: 500 },
    );
  }
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  try {
    const review = parseAdminForfeitReviewInput(
      await request.json() as Record<string, unknown>,
    );
    const { data, error } = await context.db.rpc("admin_review_clan_forfeit", {
      actor_admin_id: context.referee.profileId,
      decision_id_to_review: review.decisionId,
      action_to_take: review.action,
      review_note_to_use: review.note,
    });
    if (error) throw new Error(`Could not review forfeit: ${error.message}`);
    return NextResponse.json({
      ok: true,
      decision: data && typeof data === "object" ? data : { decisionId: String(data) },
    });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Forfeit review failed." },
      { status: 400 },
    );
  }
}

