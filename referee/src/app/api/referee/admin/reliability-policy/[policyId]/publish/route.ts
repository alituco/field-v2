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

type RouteContext = { params: Promise<{ policyId: string }> };

export async function POST(request: NextRequest, route: RouteContext) {
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
  const reason = cleanReliabilityText(body?.reason);
  if (reason.length < 10 || reason.length > 1000) {
    return NextResponse.json(
      { error: "Record a clear 10 to 1,000 character publishing reason." },
      { status: 400 },
    );
  }

  const { data, error } = await context.db.rpc("admin_publish_reliability_policy", {
    actor_admin_id: context.referee.profileId,
    policy_id_to_publish: policyId,
    reason_to_use: reason,
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
        : "The policy was published, but the policy list could not be refreshed.",
    });
  }
}
