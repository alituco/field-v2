import { NextRequest, NextResponse } from "next/server";
import { parseGamePaymentSettingsUpdate } from "@/lib/game-payment-settings";
import { adminOnly, isRefereeContext, requireReferee } from "@/lib/referee-session";

const HEADERS = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const { data, error } = await context.db.rpc("get_game_payment_settings");
  return error
    ? NextResponse.json({ error: "Could not load game pricing." }, { status: 500, headers: HEADERS })
    : NextResponse.json({ settings: data }, { headers: HEADERS });
}

export async function PATCH(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  let input;
  try {
    input = parseGamePaymentSettingsUpdate(await request.json());
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid price update." }, { status: 400, headers: HEADERS });
  }
  const { data, error } = await context.db.rpc("admin_set_game_payment_settings", {
    actor_admin_id: context.referee.profileId,
    clan_price_fils_to_use: input.priceFils,
    reason_to_use: input.reason,
    expected_updated_at: input.expectedUpdatedAt,
  });
  return error
    ? NextResponse.json({ error: error.message }, { status: 409, headers: HEADERS })
    : NextResponse.json({ settings: data }, { headers: HEADERS });
}
