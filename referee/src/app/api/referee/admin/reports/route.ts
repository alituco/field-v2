import { NextRequest, NextResponse } from "next/server";

import { loadAdminReports } from "@/lib/admin-moderation";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

const ALLOWED_STATUSES = new Set([
  "ALL",
  "OPEN",
  "TRIAGED",
  "INVESTIGATING",
  "ACTIONED",
  "RESOLVED",
  "DISMISSED",
  "DUPLICATE",
]);

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const status = (request.nextUrl.searchParams.get("status") ?? "ALL").toUpperCase();
  if (!ALLOWED_STATUSES.has(status)) {
    return NextResponse.json({ error: "Unknown report status." }, { status: 400 });
  }

  try {
    const reports = await loadAdminReports(context.db, status);
    return NextResponse.json({ reports });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load reports." },
      { status: 500 },
    );
  }
}
