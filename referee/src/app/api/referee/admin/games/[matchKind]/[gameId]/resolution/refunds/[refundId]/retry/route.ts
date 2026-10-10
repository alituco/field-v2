import { NextRequest, NextResponse } from "next/server";

import { retryAdminRefund } from "@/lib/admin-payment-refund-retry";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";

type RouteContext = {
  params: Promise<{ matchKind: string; gameId: string; refundId: string }>;
};

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const { matchKind, gameId, refundId } = await route.params;
  const reply = await retryAdminRefund({
    actor: context.referee,
    refundId,
    body: await request.json().catch(() => null),
    match: { kind: matchKind, gameId },
    store: {
      retry: async (name, args) => await context.db.rpc(name, args),
      resolutionCase: async (kind, id) => await context.db
        .from("match_resolution_cases")
        .select("id")
        .eq("match_kind", kind)
        .eq(kind === "CLAN" ? "fixture_id" : "open_queue_game_id", id)
        .maybeSingle(),
      resolutionRefund: async (id) => await context.db
        .from("match_resolution_refunds")
        .select("id,case_id,status,payment_refund_id,payment_refund:payment_refunds(provider_status,payment_intent:payment_intents(external_refund_review_required))")
        .eq("id", id)
        .maybeSingle(),
    },
  });
  return NextResponse.json(reply.body, {
    status: reply.status,
    headers: { "Cache-Control": "private, no-store" },
  });
}
