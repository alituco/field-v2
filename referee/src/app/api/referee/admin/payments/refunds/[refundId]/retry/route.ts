import { NextRequest, NextResponse } from "next/server";

import { retryAdminRefund } from "@/lib/admin-payment-refund-retry";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";

const HEADERS = { "Cache-Control": "private, no-store" };

export async function POST(
  request: NextRequest,
  route: { params: Promise<{ refundId: string }> },
) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const { refundId } = await route.params;
  const body = await request.json().catch(() => null);
  const reply = await retryAdminRefund({
    actor: context.referee,
    refundId,
    body,
    store: { retry: async (name, args) => await context.db.rpc(name, args) },
  });
  return NextResponse.json(reply.body, { status: reply.status, headers: HEADERS });
}
