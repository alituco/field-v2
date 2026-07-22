import { NextRequest, NextResponse } from "next/server";

import { loadAdminReliabilityPolicies } from "@/lib/admin-reliability";
import {
  cleanReliabilityText,
  optionalReliabilityUuid,
  reliabilityMutationStatus,
  validReliabilityBahrainDateStart,
} from "@/lib/reliability-admin-input";
import {
  parseReliabilityPolicyConfig,
  validReliabilityRevision,
} from "@/lib/reliability-policy";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = { params: Promise<{ policyId: string }> };

export async function PATCH(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const { policyId: rawPolicyId } = await route.params;
  const policyId = optionalReliabilityUuid(rawPolicyId, "policy draft");
  if (policyId instanceof NextResponse || policyId === null) {
    return policyId ?? NextResponse.json({ error: "Choose a policy draft." }, { status: 400 });
  }
  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
  const effectiveFrom = validReliabilityBahrainDateStart(body?.effectiveFrom);
  const expectedUpdatedAt = validReliabilityRevision(body?.expectedUpdatedAt);
  const summary = cleanReliabilityText(body?.summary);
  if (!effectiveFrom || !expectedUpdatedAt) {
    return NextResponse.json(
      { error: "The effective date and draft revision are required." },
      { status: 400 },
    );
  }
  if (summary.length < 5 || summary.length > 500) {
    return NextResponse.json(
      { error: "Describe this policy change in 5 to 500 characters." },
      { status: 400 },
    );
  }

  let config;
  try {
    config = parseReliabilityPolicyConfig(body?.config);
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Policy settings are invalid." },
      { status: 400 },
    );
  }

  const { data, error } = await context.db.rpc("admin_update_reliability_policy_draft", {
    actor_admin_id: context.referee.profileId,
    policy_id_to_update: policyId,
    config_to_use: config,
    effective_from_to_use: effectiveFrom,
    summary_to_use: summary,
    expected_updated_at: expectedUpdatedAt,
  });
  if (error) {
    return NextResponse.json({ error: error.message }, { status: reliabilityMutationStatus(error.message) });
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
        : "The draft was saved, but the policy list could not be refreshed.",
    });
  }
}
