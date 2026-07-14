import { NextRequest, NextResponse } from "next/server";

import { loadAdminFixtures, loadRefereeFixtures } from "@/lib/referee-data";
import {
  loadAdminOpenQueueGames,
  loadRefereeOpenQueueGames,
} from "@/lib/open-queue-referee-data";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";

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
    const fixtures = [...clanFixtures, ...soloGames].sort((left, right) => {
      const leftKey = `${left.matchDate} ${left.timeSlot}`;
      const rightKey = `${right.matchDate} ${right.timeSlot}`;
      return isAdminScope
        ? rightKey.localeCompare(leftKey)
        : leftKey.localeCompare(rightKey);
    });

    return NextResponse.json({ me: context.referee, fixtures });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load fixtures." },
      { status: 500 },
    );
  }
}
