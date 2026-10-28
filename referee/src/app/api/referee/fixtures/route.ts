import { NextRequest, NextResponse } from "next/server";

import { loadAdminFixtures, loadRefereeFixtures } from "@/lib/referee-data";
import {
  loadAdminOpenQueueGames,
  loadRefereeOpenQueueGames,
} from "@/lib/open-queue-referee-data";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";
import { sortAssignedRefereeMatches } from "@/lib/referee-assigned-matches";

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;

  try {
    const scope = request.nextUrl.searchParams.get("scope");
    const isAdminScope = scope === "admin" && context.referee.role === "admin";
    const [clanFixtures, soloGames] = await Promise.all(
      isAdminScope
        ? [loadAdminFixtures(context.db), loadAdminOpenQueueGames(context.db)]
        : [
            loadRefereeFixtures(context.db, context.referee.profileId),
            loadRefereeOpenQueueGames(context.db, context.referee.profileId),
          ],
    );
    const combined = [...clanFixtures, ...soloGames];
    const fixtures = isAdminScope
      ? combined.sort((left, right) =>
          `${right.matchDate} ${right.timeSlot}`.localeCompare(`${left.matchDate} ${left.timeSlot}`))
      : sortAssignedRefereeMatches(combined);

    return NextResponse.json({ me: context.referee, fixtures });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load fixtures." },
      { status: 500 },
    );
  }
}
