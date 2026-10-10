import { NextRequest, NextResponse } from "next/server";

import { loadAdminReliabilityPolicies } from "@/lib/admin-reliability";
import {
  cleanReliabilityText,
  optionalReliabilityUuid,
  reliabilityMutationStatus,
  validReliabilityBahrainDateStart,
} from "@/lib/reliability-admin-input";
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

  const atValue = request.nextUrl.searchParams.get("at");
  const at = atValue ? new Date(atValue) : new Date();
  if (!Number.isFinite(at.getTime())) {
    return NextResponse.json({ error: "Choose a valid policy preview date." }, { status: 400 });
  }

  try {
    return NextResponse.json(await loadAdminReliabilityPolicies(context.db, at));
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load reliability policy." },
      { status: 500 },
    );
  }
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
  const sourceVersionId = optionalReliabilityUuid(body?.sourceVersionId, "source policy");
  if (sourceVersionId instanceof NextResponse) return sourceVersionId;
  const effectiveFrom = validReliabilityBahrainDateStart(body?.effectiveFrom);
  if (!effectiveFrom) {
    return NextResponse.json({ error: "Choose when this policy should start." }, { status: 400 });
  }
  const summary = cleanReliabilityText(body?.summary);
  if (summary.length < 5 || summary.length > 500) {
    return NextResponse.json(
      { error: "Describe this policy change in 5 to 500 characters." },
      { status: 400 },
    );
  }

  const { data, error } = await context.db.rpc("admin_create_reliability_policy_draft", {
    actor_admin_id: context.referee.profileId,
    source_version_id: sourceVersionId,
    effective_from_to_use: effectiveFrom,
    summary_to_use: summary,
  });
  if (error) {
    return NextResponse.json({ error: error.message }, { status: reliabilityMutationStatus(error.message) });
  }

  try {
    return NextResponse.json({
      ok: true,
      result: data,
      policies: await loadAdminReliabilityPolicies(context.db),
    }, { status: 201 });
  } catch (loadError) {
    return NextResponse.json({
      ok: true,
      result: data,
      warning: loadError instanceof Error
        ? loadError.message
        : "The draft was created, but the policy list could not be refreshed.",
    }, { status: 201 });
  }
}
