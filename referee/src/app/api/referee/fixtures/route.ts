import { NextRequest, NextResponse } from "next/server";

import { loadAdminFixtures, loadRefereeFixtures } from "@/lib/referee-data";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;

  try {
    const scope = request.nextUrl.searchParams.get("scope");
    const fixtures =
      scope === "admin" && context.referee.role === "admin"
        ? await loadAdminFixtures(context.db)
        : await loadRefereeFixtures(context.db, context.referee.profileId);

    return NextResponse.json({ me: context.referee, fixtures });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load fixtures." },
      { status: 500 },
    );
  }
}
