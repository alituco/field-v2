import { NextRequest, NextResponse } from "next/server";
import { requireReferee, isRefereeContext } from "@/lib/referee-session";
import { loadSeasonZeroState } from "@/lib/season-zero-actions";

export async function GET(request: NextRequest, context: { params: Promise<{ gameId: string }> }) {
  const referee = await requireReferee(request);
  if (!isRefereeContext(referee)) return referee;
  try {
    const { gameId } = await context.params;
    return NextResponse.json({ state: await loadSeasonZeroState(referee.db, referee.referee.profileId, gameId) });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not load playing time." }, { status: 400 });
  }
}
