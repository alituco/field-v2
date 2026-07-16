import { NextRequest, NextResponse } from "next/server";

import { loadFlaggedSubjects } from "@/lib/admin-moderation";
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
    const subjects = await loadFlaggedSubjects(context.db);
    return NextResponse.json({ subjects });
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error
          ? error.message
          : "Could not load flagged players and clans.",
      },
      { status: 500 },
    );
  }
}
