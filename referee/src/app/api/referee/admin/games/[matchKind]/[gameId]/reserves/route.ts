import { NextRequest, NextResponse } from "next/server";

import {
  loadAdminGameReserves,
  loadAdminReserveCandidates,
  type AdminGameReserveSide,
} from "@/lib/admin-game-reserves";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = {
  params: Promise<{ matchKind: string; gameId: string }>;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PRIVATE_NO_STORE = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const parsed = await parseRoute(route);
  if (parsed instanceof NextResponse) return parsed;
  const side = parseSide(parsed.matchKind, request.nextUrl.searchParams.get("side"));
  if (!side) {
    return NextResponse.json(
      { error: parsed.matchKind === "SOLO" ? "Choose White or Black." : "Choose Home or Away." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
  try {
    return NextResponse.json({
      candidates: await loadAdminReserveCandidates(
        context.db,
        parsed.matchKind,
        parsed.gameId,
        side,
        request.nextUrl.searchParams.get("query") ?? "",
      ),
    }, { headers: PRIVATE_NO_STORE });
  } catch (error) {
    return failure(error, "Could not search reserve players.");
  }
}

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const parsed = await parseRoute(route);
  if (parsed instanceof NextResponse) return parsed;
  const body = await jsonBody(request);
  const profileId = stringValue(body?.profileId);
  const side = parseSide(parsed.matchKind, body?.side);
  const note = stringValue(body?.note);
  if (!UUID.test(profileId) || !side || note.length < 3 || note.length > 500) {
    return NextResponse.json(
      { error: "Choose an eligible player, side, and a short assignment note." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
  const { error } = await context.db.rpc("admin_assign_match_reserve", {
    actor_admin_id: context.referee.profileId,
    match_kind_to_use: parsed.matchKind,
    match_id_to_use: parsed.gameId,
    profile_id_to_use: profileId,
    side_to_use: side,
    note_to_use: note,
  });
  if (error) return mutationFailure(error.message);
  try {
    return NextResponse.json({
      ok: true,
      reserves: await loadAdminGameReserves(context.db, parsed.matchKind, parsed.gameId),
    }, { status: 201, headers: PRIVATE_NO_STORE });
  } catch (loadError) {
    return NextResponse.json({
      ok: true,
      warning: loadError instanceof Error ? loadError.message : "Reserve assigned; refresh to view it.",
    }, { status: 201, headers: PRIVATE_NO_STORE });
  }
}

export async function DELETE(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;
  const parsed = await parseRoute(route);
  if (parsed instanceof NextResponse) return parsed;
  const body = await jsonBody(request);
  const assignmentId = stringValue(body?.assignmentId);
  const reason = stringValue(body?.reason);
  if (!UUID.test(assignmentId) || reason.length < 3 || reason.length > 500) {
    return NextResponse.json(
      { error: "Choose the reserve and explain why the assignment is being removed." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
  const { error } = await context.db.rpc("admin_remove_match_reserve", {
    actor_admin_id: context.referee.profileId,
    assignment_id_to_remove: assignmentId,
    reason_to_use: reason,
  });
  if (error) return mutationFailure(error.message);
  try {
    return NextResponse.json({
      ok: true,
      reserves: await loadAdminGameReserves(context.db, parsed.matchKind, parsed.gameId),
    }, { headers: PRIVATE_NO_STORE });
  } catch (loadError) {
    return NextResponse.json({
      ok: true,
      warning: loadError instanceof Error ? loadError.message : "Reserve removed; refresh to confirm.",
    }, { headers: PRIVATE_NO_STORE });
  }
}

async function parseRoute(route: RouteContext) {
  const { matchKind: rawKind, gameId } = await route.params;
  const matchKind = rawKind.trim().toUpperCase();
  if ((matchKind !== "SOLO" && matchKind !== "CLAN") || !UUID.test(gameId)) {
    return NextResponse.json(
      { error: "Choose a valid solo or clan game." },
      { status: 400, headers: PRIVATE_NO_STORE },
    );
  }
  return { matchKind, gameId } as const;
}

function parseSide(
  matchKind: "SOLO" | "CLAN",
  value: unknown,
): AdminGameReserveSide | null {
  const side = stringValue(value).toUpperCase();
  if (matchKind === "SOLO") return side === "WHITE" || side === "BLACK" ? side : null;
  return side === "HOME" || side === "AWAY" ? side : null;
}

async function jsonBody(request: NextRequest) {
  const value = await request.json().catch(() => null);
  return value && typeof value === "object" ? value as Record<string, unknown> : null;
}

function stringValue(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

function failure(error: unknown, fallback: string) {
  return NextResponse.json(
    { error: error instanceof Error ? error.message : fallback },
    { status: 500, headers: PRIVATE_NO_STORE },
  );
}

function mutationFailure(message: string) {
  const normalized = message.toLowerCase();
  const status = normalized.includes("not found") ? 404
    : normalized.includes("access") ? 403
      : normalized.includes("already") || normalized.includes("only") || normalized.includes("must")
        ? 409
        : 400;
  return NextResponse.json({ error: message }, { status, headers: PRIVATE_NO_STORE });
}
