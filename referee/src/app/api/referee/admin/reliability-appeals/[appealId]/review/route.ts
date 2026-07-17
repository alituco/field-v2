import { NextRequest, NextResponse } from "next/server";

import { loadAdminReliabilityPolicies } from "@/lib/admin-reliability";
import {
  cleanReliabilityText,
  optionalReliabilityUuid,
  reliabilityMutationStatus,
} from "@/lib/reliability-admin-input";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = { params: Promise<{ appealId: string }> };

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const { appealId: rawAppealId } = await route.params;
  const appealId = optionalReliabilityUuid(rawAppealId, "reliability appeal");
  if (appealId instanceof NextResponse || appealId === null) {
    return appealId ?? NextResponse.json(
      { error: "Choose a reliability appeal." },
      { status: 400 },
    );
  }

  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
  const decision = cleanReliabilityText(body?.decision).toUpperCase();
  const note = cleanReliabilityText(body?.note);
  if (decision !== "UPHOLD" && decision !== "OVERTURN") {
    return NextResponse.json(
      { error: "Decision must be UPHOLD or OVERTURN." },
      { status: 400 },
    );
  }
  if (note.length < 10 || note.length > 2000) {
    return NextResponse.json(
      { error: "Record a clear 10 to 2,000 character review note." },
      { status: 400 },
    );
  }

  const { data, error } = await context.db.rpc("admin_review_reliability_appeal", {
    actor_admin_id: context.referee.profileId,
    appeal_id_to_review: appealId,
    decision_to_use: decision,
    resolution_note_to_use: note,
  });
  if (error) {
    return NextResponse.json(
      { error: error.message },
      { status: reliabilityMutationStatus(error.message) },
    );
  }

  try {
    return NextResponse.json({
      ok: true,
      result: data,
      policies: await loadAdminReliabilityPolicies(context.db),
    });
  } catch (loadError) {
    return NextResponse.json({
      ok: true,
      result: data,
      warning: loadError instanceof Error
        ? loadError.message
        : "The appeal was reviewed, but the operations queue could not be refreshed.",
    });
  }
}
