import { NextRequest, NextResponse } from "next/server";

import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = {
  params: Promise<{
    matchKind: string;
    gameId: string;
    refundId: string;
  }>;
};

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PRIVATE_NO_STORE = { "Cache-Control": "private, no-store" };

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const {
    matchKind: rawMatchKind,
    gameId,
    refundId,
  } = await route.params;
  const matchKind = rawMatchKind.trim().toUpperCase();
  if (
    !["SOLO", "CLAN"].includes(matchKind) ||
    !UUID.test(gameId) ||
    !UUID.test(refundId)
  ) {
    return NextResponse.json(
      { error: "Choose a valid clan or solo game and refund." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }

  const body = await request.json().catch(() => null) as
    | Record<string, unknown>
    | null;
  const reason = typeof body?.reason === "string" ? body.reason.trim() : "";
  if (reason.length < 10 || reason.length > 2000) {
    return NextResponse.json(
      { error: "Explain the refund retry in 10 to 2000 characters." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }

  const matchColumn = matchKind === "CLAN"
    ? "fixture_id"
    : "open_queue_game_id";
  const { data: caseData, error: caseError } = await context.db
    .from("match_resolution_cases")
    .select("id")
    .eq("match_kind", matchKind)
    .eq(matchColumn, gameId)
    .maybeSingle();
  if (caseError) {
    return NextResponse.json(
      { error: `Could not verify this match resolution: ${caseError.message}` },
      { status: 500, headers: PRIVATE_NO_STORE },
    );
  }
  if (!caseData) {
    return NextResponse.json(
      { error: "No match resolution case exists for this game." },
      { status: 404, headers: PRIVATE_NO_STORE },
    );
  }

  const { data: refundData, error: refundError } = await context.db
    .from("match_resolution_refunds")
    .select("id,case_id,status")
    .eq("id", refundId)
    .maybeSingle();
  if (refundError) {
    return NextResponse.json(
      { error: `Could not verify this refund: ${refundError.message}` },
      { status: 500, headers: PRIVATE_NO_STORE },
    );
  }
  if (!refundData || String(refundData.case_id) !== String(caseData.id)) {
    return NextResponse.json(
      { error: "This refund does not belong to this match resolution." },
      { status: 404, headers: PRIVATE_NO_STORE },
    );
  }
  if (String(refundData.status).toUpperCase() !== "FAILED") {
    return NextResponse.json(
      {
        error:
          `Only failed refunds can be retried. This refund is ${String(refundData.status).toLowerCase()}.`,
      },
      { status: 409, headers: PRIVATE_NO_STORE },
    );
  }

  const { data, error } = await context.db.rpc(
    "admin_retry_match_resolution_refund",
    {
      actor_admin_id: context.referee.profileId,
      refund_id_to_retry: refundId,
      reason_to_use: reason,
    },
  );
  if (error) {
    return retryFailure(error.message);
  }

  const result = data && typeof data === "object"
    ? data as Record<string, unknown>
    : {};
  if (String(result.status ?? "").toUpperCase() === "FAILED") {
    const failureReason =
      typeof result.failure_reason === "string" &&
        result.failure_reason.trim()
        ? result.failure_reason.trim()
        : "The Field Wallet credit failed again.";
    return NextResponse.json(
      {
        error: `Refund retry failed: ${failureReason}`,
        result,
      },
      { status: 502, headers: PRIVATE_NO_STORE },
    );
  }

  return NextResponse.json(
    { ok: true, result },
    { headers: PRIVATE_NO_STORE },
  );
}

function retryFailure(message: string) {
  const normalized = message.toLowerCase();
  const status = normalized.includes("access") ? 403
    : normalized.includes("not found") ? 404
      : normalized.includes("superseded") ||
          normalized.includes("original payer") ||
          normalized.includes("missing") ||
          normalized.includes("reconcile")
        ? 409
        : 400;
  return NextResponse.json(
    { error: message },
    { status, headers: PRIVATE_NO_STORE },
  );
}
