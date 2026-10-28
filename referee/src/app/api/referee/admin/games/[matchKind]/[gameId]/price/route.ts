import { NextRequest, NextResponse } from "next/server";
import { parseGamePriceUpdate } from "@/lib/admin-game-price-update";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const headers = { "Cache-Control": "private, no-store" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function PATCH(request: NextRequest, { params }: { params: Promise<{ matchKind: string; gameId: string }> }) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  let input;
  let gameId: string;
  try {
    const route = await params;
    if (route.matchKind.toUpperCase() !== "SOLO") throw new Error("Price editing is available for solo games only. Clan games remain paused.");
    if (!UUID.test(route.gameId)) throw new Error("Choose a valid game.");
    gameId = route.gameId;
    input = parseGamePriceUpdate(await request.json());
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid price update." }, { status: 400, headers });
  }
  const { data, error } = await context.db.rpc("admin_update_open_queue_game_price", {
    actor_admin_id: context.referee.profileId, game_id_to_use: gameId,
    price_fils_to_use: input.priceFils, expected_price_fils: input.expectedPriceFils, reason_to_use: input.reason,
  });
  if (error) {
    const missing = ["PGRST202", "42883"].includes(error.code ?? "");
    return NextResponse.json({ error: missing ? "The game-price database update is not installed yet. Apply the latest migration and try again." : error.message }, { status: missing ? 503 : 409, headers });
  }
  return NextResponse.json({ priceFils: data.price_fils, currency: data.currency }, { headers });
}
