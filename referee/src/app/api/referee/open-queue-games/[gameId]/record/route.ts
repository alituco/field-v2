import { NextRequest, NextResponse } from "next/server";
import { requireReferee, isRefereeContext } from "@/lib/referee-session";
import { assertCanManageOpenQueueGame } from "@/lib/fixture-access";
import { loadSeasonZeroState } from "@/lib/season-zero-actions";
import { saveMatchRecord } from "@/lib/solo-match-record";

type Context = { params: Promise<{ gameId: string }> };
const headers = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest, route: Context) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  try {
    const { gameId } = await route.params;
    await assertCanManageOpenQueueGame(context.db, gameId, context.referee.profileId, context.referee.role);
    return NextResponse.json({ state: await loadSeasonZeroState(context.db, context.referee.profileId, gameId) }, { headers });
  } catch (failure) {
    return NextResponse.json({ error: failure instanceof Error ? failure.message : "Could not load the match record." }, { status: 400, headers });
  }
}

export async function POST(request: NextRequest, route: Context) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  try {
    const { gameId } = await route.params;
    await assertCanManageOpenQueueGame(context.db, gameId, context.referee.profileId, context.referee.role);
    const result = await saveMatchRecord(context.db, context.referee.profileId, gameId, await request.json());
    return NextResponse.json(result, { headers });
  } catch (failure) {
    const code = failure && typeof failure === "object" && "code" in failure ? failure.code : null;
    return NextResponse.json({ error: failure instanceof Error ? failure.message : "Could not save the match record." },
      { status: code === "40001" ? 409 : code === "42501" ? 403 : code === "MATCH_RECORD_ACK_UNKNOWN" ? 502 : 400, headers });
  }
}
