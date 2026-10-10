import { NextRequest, NextResponse } from "next/server";

import {
  loadAdminSupportTickets,
  parseSupportTicketStatusFilter,
} from "@/lib/admin-support";
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

  let status;
  try {
    status = parseSupportTicketStatusFilter(
      request.nextUrl.searchParams.get("status") ?? "ACTIVE",
    );
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error
          ? error.message
          : "Unknown support ticket status.",
      },
      { status: 400 },
    );
  }

  try {
    const [tickets, activeCountResult] = await Promise.all([
      loadAdminSupportTickets(context.db, status),
      context.db
        .from("support_tickets")
        .select("id", { count: "exact", head: true })
        .in("status", ["OPEN", "IN_PROGRESS"]),
    ]);
    if (activeCountResult.error) {
      throw new Error(
        `Could not count support requests: ${activeCountResult.error.message}`,
      );
    }
    return NextResponse.json({
      tickets,
      activeCount: activeCountResult.count ?? 0,
    });
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error
          ? error.message
          : "Could not load support requests.",
      },
      { status: 500 },
    );
  }
}
