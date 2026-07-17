import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  BlueCard,
  FixtureClock,
  FixtureEvent,
  Goal,
  Player,
  RefereeFixture,
} from "./types";
import { nullableSr, persistedOpenQueueTeam } from "./open-queue-ratings";
import { loadMatchReliabilityContext } from "./match-reliability";
import {
  loadRefereeRiskSignals,
  riskContextFor,
} from "./referee-risk-context";

const WHITE = {
  id: "WHITE",
  name: "White Team",
  tag: "WHITE",
  emblem: "⚪",
  skillRating: 0,
};

const BLACK = {
  id: "BLACK",
  name: "Black Team",
  tag: "BLACK",
  emblem: "⚫",
  skillRating: 0,
};

const gameSelect = `
  id,
  status,
  venue,
  starts_at,
  ends_at,
  timezone,
  white_score,
  black_score,
  white_average_sr,
  black_average_sr,
  match_average_sr,
  team_sr_spread,
  teams_assigned_at,
  cancellation_code,
  cancellation_reason,
  cancelled_at,
  cancelled_by
`;

export async function loadRefereeOpenQueueGames(
  db: SupabaseClient,
  refereeId: string,
): Promise<RefereeFixture[]> {
  const { data: assignments, error: assignmentsError } = await db
    .from("open_queue_referee_assignments")
    .select("game_id")
    .eq("referee_id", refereeId);

  if (assignmentsError) throw assignmentsError;
  const gameIds = (assignments ?? []).map((row) => String(row.game_id));
  if (gameIds.length === 0) return [];

  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await db
    .from("open_queue_games")
    .select(gameSelect)
    .in("id", gameIds)
    .in("status", ["FULL", "LIVE", "FINAL"])
    .gte("starts_at", since)
    .order("starts_at");

  if (error) throw error;
  return hydrateOpenQueueRows(
    db,
    (data ?? []) as Record<string, unknown>[],
    true,
  );
}

export async function loadAdminOpenQueueGames(
  db: SupabaseClient,
): Promise<RefereeFixture[]> {
  const since = new Date(Date.now() - 730 * 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await db
    .from("open_queue_games")
    .select(gameSelect)
    .in("status", ["OPEN", "FULL", "LIVE", "FINAL", "CANCELLED"])
    .gte("starts_at", since)
    .order("starts_at", { ascending: false })
    .limit(300);

  if (error) throw error;
  return hydrateOpenQueueRows(
    db,
    (data ?? []) as Record<string, unknown>[],
    false,
  );
}

async function hydrateOpenQueueRows(
  db: SupabaseClient,
  rows: Record<string, unknown>[],
  includeReliabilityContext: boolean,
): Promise<RefereeFixture[]> {
  if (rows.length === 0) return [];
  const gameIds = rows.map((row) => String(row.id));

  const [players, clocks, goals, events, blueCards, reliabilityContexts] = await Promise.all([
    loadPlayers(db, gameIds),
    loadClocks(db, gameIds),
    loadGoals(db, gameIds),
    loadEvents(db, gameIds),
    loadBlueCards(db, gameIds),
    includeReliabilityContext
      ? Promise.all(
          gameIds.map((gameId) =>
            loadMatchReliabilityContext(db, "SOLO", gameId)
          ),
        )
      : Promise.resolve(gameIds.map(() => null)),
  ]);
  const riskSignals = await loadRefereeRiskSignals(
    db,
    players.map((player) => player.id),
    [],
  );

  return rows.map((row, rowIndex) => {
    const id = String(row.id);
    const startsAt = String(row.starts_at);
    const endsAt = String(row.ends_at);
    const timezone = String(row.timezone || "Asia/Bahrain");
    const gamePlayers = players.filter((player) => player.gameId === id);
    const playedPlayerIds = gamePlayers
      .filter((player) => player.played)
      .map((player) => player.id);
    const relevantPlayerIds = playedPlayerIds.length > 0
      ? playedPlayerIds
      : gamePlayers.map((player) => player.id);

    return {
      matchKind: "SOLO",
      id,
      status: String(row.status) as RefereeFixture["status"],
      venue: String(row.venue ?? ""),
      day: zonedPart(startsAt, timezone, "weekday").toUpperCase(),
      timeSlot: `${zonedTime(startsAt, timezone)} - ${zonedTime(endsAt, timezone)}`,
      matchDate: zonedDate(startsAt, timezone),
      cancellationCode: nullableString(row.cancellation_code),
      cancellationReason: nullableString(row.cancellation_reason),
      cancelledAt: nullableString(row.cancelled_at),
      cancelledBy: nullableString(row.cancelled_by),
      homeScore: nullableNumber(row.white_score),
      awayScore: nullableNumber(row.black_score),
      whiteAverageSr: nullableSr(row.white_average_sr),
      blackAverageSr: nullableSr(row.black_average_sr),
      matchAverageSr: nullableSr(row.match_average_sr),
      teamSrSpread: nullableSr(row.team_sr_spread),
      teamsAssignedAt: nullableString(row.teams_assigned_at),
      homeClan: WHITE,
      awayClan: BLACK,
      players: gamePlayers.map(
        ({ gameId: _gameId, played: _played, ...player }) => player,
      ),
      participantIds: gamePlayers
        .filter((player) => player.played)
        .map((player) => player.id),
      clock: clocks.get(id) ?? null,
      goals: goals.filter((goal) => goal.fixtureId === id),
      events: events.filter((event) => event.fixtureId === id),
      blueCards: blueCards.filter((card) => card.fixtureId === id),
      riskContext: riskContextFor(riskSignals, [], relevantPlayerIds),
      reliabilityContext: reliabilityContexts[rowIndex] ?? null,
    } satisfies RefereeFixture;
  });
}

type GamePlayer = Player & { gameId: string; played: boolean };

async function loadPlayers(
  db: SupabaseClient,
  gameIds: string[],
): Promise<GamePlayer[]> {
  const { data, error } = await db
    .from("open_queue_bookings")
    .select(`
      id,
      game_id,
      profile_id,
      role,
      team,
      rating_at_team_assignment,
      played,
      profiles!open_queue_bookings_profile_id_fkey(
        id,
        display_name,
        username,
        avatar_url
      )
    `)
    .in("game_id", gameIds)
    .eq("status", "CONFIRMED")
    .order("booked_at");

  if (error) throw error;

  return (data ?? []).map((row) => {
    const profile = asObject(row.profiles);
    const persistedTeam = persistedOpenQueueTeam(row.team);
    return {
      id: String(row.profile_id),
      gameId: String(row.game_id),
      played: row.played === true,
      clanId: persistedTeam ?? "UNASSIGNED",
      role: String(row.role ?? "MID"),
      displayName: String(profile.display_name ?? "Unnamed player"),
      username: nullableString(profile.username),
      avatarUrl: nullableString(profile.avatar_url),
      ratingAtTeamAssignment: nullableSr(row.rating_at_team_assignment),
    };
  });
}

async function loadClocks(db: SupabaseClient, gameIds: string[]) {
  const clocks = new Map<string, FixtureClock>();
  const { data, error } = await db
    .from("open_queue_clock_states")
    .select("game_id,status,started_at,accumulated_seconds,duration_seconds")
    .in("game_id", gameIds);
  if (error) throw error;

  for (const row of data ?? []) {
    clocks.set(String(row.game_id), {
      status: String(row.status) as FixtureClock["status"],
      startedAt: nullableString(row.started_at),
      accumulatedSeconds: Number(row.accumulated_seconds ?? 0),
      durationSeconds: Number(row.duration_seconds ?? 3600),
    });
  }
  return clocks;
}

async function loadGoals(db: SupabaseClient, gameIds: string[]) {
  const { data, error } = await db
    .from("open_queue_goals")
    .select("id,game_id,team,profile_id,assist_profile_id,minute,created_at")
    .in("game_id", gameIds)
    .order("minute");
  if (error) throw error;

  return (data ?? []).map((row) => ({
    id: String(row.id),
    fixtureId: String(row.game_id),
    clanId: String(row.team),
    profileId: String(row.profile_id),
    assistProfileId: nullableString(row.assist_profile_id),
    minute: Number(row.minute ?? 1),
    createdAt: String(row.created_at),
  } satisfies Goal));
}

async function loadEvents(db: SupabaseClient, gameIds: string[]) {
  const { data, error } = await db
    .from("open_queue_events")
    .select(
      "id,game_id,event_type,team,profile_id,assist_profile_id,blue_card_id,minute,second,note,created_at",
    )
    .in("game_id", gameIds)
    .order("created_at", { ascending: false });
  if (error) throw error;

  return (data ?? []).map((row) => ({
    id: String(row.id),
    fixtureId: String(row.game_id),
    eventType: String(row.event_type) as FixtureEvent["eventType"],
    clanId: nullableString(row.team),
    profileId: nullableString(row.profile_id),
    assistProfileId: nullableString(row.assist_profile_id),
    blueCardId: nullableString(row.blue_card_id),
    minute: Number(row.minute ?? 0),
    second: Number(row.second ?? 0),
    note: String(row.note ?? ""),
    createdAt: String(row.created_at),
  } satisfies FixtureEvent));
}

async function loadBlueCards(db: SupabaseClient, gameIds: string[]) {
  const { data, error } = await db
    .from("open_queue_blue_cards")
    .select(
      "id,game_id,team,profile_id,started_at,expires_at,duration_seconds,status,minute,second",
    )
    .in("game_id", gameIds)
    .order("created_at", { ascending: false });
  if (error) throw error;

  return (data ?? []).map((row) => ({
    id: String(row.id),
    fixtureId: String(row.game_id),
    clanId: String(row.team),
    profileId: String(row.profile_id),
    startedAt: String(row.started_at),
    expiresAt: String(row.expires_at),
    durationSeconds: Number(row.duration_seconds ?? 120),
    status: String(row.status) as BlueCard["status"],
    minute: Number(row.minute ?? 0),
    second: Number(row.second ?? 0),
  } satisfies BlueCard));
}

function zonedDate(value: string, timezone: string) {
  const parts = dateParts(value, timezone);
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function zonedTime(value: string, timezone: string) {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  }).format(new Date(value));
}

function zonedPart(value: string, timezone: string, type: "weekday") {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    weekday: type === "weekday" ? "long" : undefined,
  }).format(new Date(value));
}

function dateParts(value: string, timezone: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(value));
  const get = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value ?? "";
  return { year: get("year"), month: get("month"), day: get("day") };
}

function asObject(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return asObject(value[0]);
  if (value && typeof value === "object") return value as Record<string, unknown>;
  return {};
}

function nullableString(value: unknown) {
  return value === null || value === undefined ? null : String(value);
}

function nullableNumber(value: unknown) {
  if (value === null || value === undefined) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}
