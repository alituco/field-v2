import { NextRequest, NextResponse } from "next/server";

import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";
import type {
  AssignableFixture,
  RefereeAssignmentsResponse,
  RefereeListItem,
} from "@/lib/types";

const assignmentFixtureSelect = `
  id,
  status,
  venue,
  match_date,
  time_slot,
  home_clan:clans!fixtures_home_clan_id_fkey(
    id,
    name,
    tag,
    emblem,
    skill_rating
  ),
  away_clan:clans!fixtures_away_clan_id_fkey(
    id,
    name,
    tag,
    emblem,
    skill_rating
  )
`;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const adminError = adminOnly(context.referee);
  if (adminError) return adminError;

  try {
    const [
      refereesResult,
      fixturesResult,
      assignmentsResult,
      soloGamesResult,
      soloAssignmentsResult,
    ] = await Promise.all([
      context.db
        .from("referee_profiles")
        .select("profile_id,display_name,phone,role")
        .eq("is_active", true)
        .order("display_name"),
      context.db
        .from("fixtures")
        .select(assignmentFixtureSelect)
        .in("status", ["OPEN", "SCHEDULED", "LIVE", "FINAL", "CANCELLED"])
        .not("away_clan_id", "is", null)
        .order("match_date")
        .order("time_slot"),
      context.db
        .from("fixture_referee_assignments")
        .select("fixture_id,referee_id"),
      context.db
        .from("open_queue_games")
        .select("id,status,venue,starts_at,ends_at,timezone")
        .in("status", ["OPEN", "FULL", "LIVE", "FINAL", "CANCELLED"])
        .order("starts_at"),
      context.db
        .from("open_queue_referee_assignments")
        .select("game_id,referee_id"),
    ]);

    if (refereesResult.error) throw refereesResult.error;
    if (fixturesResult.error) throw fixturesResult.error;
    if (assignmentsResult.error) throw assignmentsResult.error;
    if (soloGamesResult.error) throw soloGamesResult.error;
    if (soloAssignmentsResult.error) throw soloAssignmentsResult.error;

    const refereeByFixture = new Map(
      (assignmentsResult.data ?? []).map((row) => [
        String(row.fixture_id),
        String(row.referee_id),
      ]),
    );
    const refereeBySoloGame = new Map(
      (soloAssignmentsResult.data ?? []).map((row) => [
        String(row.game_id),
        String(row.referee_id),
      ]),
    );

    const payload: RefereeAssignmentsResponse = {
      referees: (refereesResult.data ?? []).map((row) => ({
        profileId: String(row.profile_id),
        displayName: String(row.display_name),
        phone: String(row.phone),
        role: String(row.role) === "admin" ? "admin" : "referee",
      } satisfies RefereeListItem)),
      fixtures: [
        ...(fixturesResult.data ?? []).map((row) =>
          normalizeAssignableFixture(
            row as Record<string, unknown>,
            refereeByFixture.get(String(row.id)) ?? null,
          )
        ),
        ...(soloGamesResult.data ?? []).map((row) =>
          normalizeAssignableSoloGame(
            row as Record<string, unknown>,
            refereeBySoloGame.get(String(row.id)) ?? null,
          )
        ),
      ].sort((left, right) =>
        `${left.matchDate} ${left.timeSlot}`.localeCompare(
          `${right.matchDate} ${right.timeSlot}`,
        )
      ),
    };

    return NextResponse.json(payload);
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load assignments." },
      { status: 500 },
    );
  }
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const adminError = adminOnly(context.referee);
  if (adminError) return adminError;

  try {
    const body = (await request.json()) as {
      fixtureId?: string;
      refereeId?: string | null;
      matchKind?: "CLAN" | "SOLO";
    };
    const fixtureId = requireValue(body.fixtureId, "Missing fixture.");
    if (!UUID.test(fixtureId)) throw new Error("Choose a valid game.");
    if (body.matchKind !== "CLAN" && body.matchKind !== "SOLO") {
      throw new Error("Game type must be clan or solo.");
    }
    const isSolo = body.matchKind === "SOLO";
    const assignmentTable = isSolo
      ? "open_queue_referee_assignments"
      : "fixture_referee_assignments";
    const idColumn = isSolo ? "game_id" : "fixture_id";
    const gameTable = isSolo ? "open_queue_games" : "fixtures";
    const { data: game, error: gameError } = await context.db
      .from(gameTable)
      .select("id,status")
      .eq("id", fixtureId)
      .maybeSingle();
    if (gameError) throw gameError;
    if (!game) throw new Error("Game not found.");
    if (!isAssignableStatus(String(game.status), isSolo)) {
      throw new Error(
        String(game.status) === "LIVE"
          ? "A live referee assignment is locked."
          : "Only upcoming games can be assigned.",
      );
    }

    if (!body.refereeId) {
      const { error } = await context.db
        .from(assignmentTable)
        .delete()
        .eq(idColumn, fixtureId);

      if (error) throw error;
      return NextResponse.json({ ok: true });
    }

    if (!UUID.test(body.refereeId)) throw new Error("Choose a valid referee.");
    const { data: referee, error: refereeError } = await context.db
      .from("referee_profiles")
      .select("profile_id")
      .eq("profile_id", body.refereeId)
      .eq("is_active", true)
      .maybeSingle();
    if (refereeError) throw refereeError;
    if (!referee) throw new Error("That referee is not active.");

    const { error } = await context.db
      .from(assignmentTable)
      .upsert(
        {
          [idColumn]: fixtureId,
          referee_id: body.refereeId,
          assigned_by: context.referee.profileId,
        },
        { onConflict: idColumn },
      );

    if (error) throw error;
    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not assign referee." },
      { status: 400 },
    );
  }
}

function normalizeAssignableFixture(
  row: Record<string, unknown>,
  assignedRefereeId: string | null,
): AssignableFixture {
  return {
    matchKind: "CLAN",
    id: String(row.id),
    status: String(row.status) as AssignableFixture["status"],
    venue: String(row.venue ?? ""),
    matchDate: String(row.match_date ?? ""),
    timeSlot: String(row.time_slot ?? ""),
    homeClan: normalizeClan(asObject(row.home_clan)),
    awayClan: normalizeClan(asObject(row.away_clan)),
    assignedRefereeId,
  };
}

function normalizeAssignableSoloGame(
  row: Record<string, unknown>,
  assignedRefereeId: string | null,
): AssignableFixture {
  const startsAt = String(row.starts_at);
  const endsAt = String(row.ends_at);
  const timezone = String(row.timezone || "Asia/Bahrain");
  return {
    matchKind: "SOLO",
    id: String(row.id),
    status: String(row.status) as AssignableFixture["status"],
    venue: String(row.venue ?? ""),
    matchDate: zonedDate(startsAt, timezone),
    timeSlot: `${zonedTime(startsAt, timezone)} - ${zonedTime(endsAt, timezone)}`,
    homeClan: {
      id: "WHITE",
      name: "White Team",
      tag: "WHITE",
      emblem: "⚪",
      skillRating: 0,
    },
    awayClan: {
      id: "BLACK",
      name: "Black Team",
      tag: "BLACK",
      emblem: "⚫",
      skillRating: 0,
    },
    assignedRefereeId,
  };
}

function zonedDate(value: string, timezone: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(value));
  const get = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

function zonedTime(value: string, timezone: string) {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  }).format(new Date(value));
}

function normalizeClan(row: Record<string, unknown>) {
  return {
    id: String(row.id),
    name: String(row.name ?? ""),
    tag: String(row.tag ?? ""),
    emblem: String(row.emblem ?? "⚽"),
    skillRating: Number(row.skill_rating ?? 1500),
  };
}

function asObject(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return asObject(value[0]);
  if (value && typeof value === "object") {
    return value as Record<string, unknown>;
  }
  return {};
}

function requireValue(value: string | undefined, message: string) {
  if (!value) throw new Error(message);
  return value;
}

function isAssignableStatus(status: string, isSolo: boolean) {
  return isSolo
    ? status === "OPEN" || status === "FULL"
    : status === "OPEN" || status === "SCHEDULED";
}
