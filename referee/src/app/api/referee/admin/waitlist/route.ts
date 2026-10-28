import { NextRequest, NextResponse } from "next/server";

import { loadAdminWaitlist } from "@/lib/admin-waitlist";
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

  try {
    const applicants = await loadAdminWaitlist(context.db);
    return NextResponse.json(
      { applicants },
      {
        headers: {
          "Cache-Control": "private, no-store, max-age=0",
        },
      },
    );
  } catch (error) {
    return NextResponse.json(
      {
        error:
          error instanceof Error
            ? error.message
            : "Could not load interest signups.",
      },
      { status: 500 },
    );
  }
}
