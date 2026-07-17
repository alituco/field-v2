import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  BlueCard,
  Clan,
  FixtureClock,
  FixtureEvent,
  Goal,
  Player,
  RefereeFixture,
} from "./types";
import {
  loadRefereeRiskSignals,
  riskContextFor,
} from "./referee-risk-context";
import { loadMatchReliabilityContext } from "./match-reliability";

const fixtureSelect = `
  id,
  status,
  venue,
  day,
  time_slot,
  match_date,
  home_score,
  away_score,
  cancellation_code,
  cancellation_reason,
  cancelled_at,
  cancelled_by,
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

export async function loadRefereeFixtures(
  db: SupabaseClient,
  refereeId: string,
): Promise<RefereeFixture[]> {
  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);
  today.setUTCDate(today.getUTCDate() - 1);

  const { data: assignments, error: assignmentsError } = await db
    .from("fixture_referee_assignments")
    .select("fixture_id")
    .eq("referee_id", refereeId);

  if (assignmentsError) throw assignmentsError;

  const assignedFixtureIds = (assignments ?? []).map((row) =>
    String(row.fixture_id)
  );

  if (assignedFixtureIds.length === 0) return [];

  const { data: fixtures, error: fixturesError } = await db
    .from("fixtures")
    .select(fixtureSelect)
    .in("id", assignedFixtureIds)
    .in("status", ["SCHEDULED", "LIVE", "FINAL"])
    .not("away_clan_id", "is", null)
    .gte("match_date", today.toISOString().slice(0, 10))
    .order("match_date")
    .order("time_slot");

  if (fixturesError) throw fixturesError;

  return hydrateFixtureRows(db, fixtures ?? [], true);
}

export async function loadAdminFixtures(
  db: SupabaseClient,
): Promise<RefereeFixture[]> {
  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);
  today.setUTCDate(today.getUTCDate() - 730);

  const { data: fixtures, error: fixturesError } = await db
    .from("fixtures")
    .select(fixtureSelect)
    .in("status", ["OPEN", "SCHEDULED", "LIVE", "FINAL", "CANCELLED"])
    .not("away_clan_id", "is", null)
    .gte("match_date", today.toISOString().slice(0, 10))
    .order("match_date", { ascending: false })
    .order("time_slot")
    .limit(300);

  if (fixturesError) throw fixturesError;

  return hydrateFixtureRows(db, fixtures ?? [], false);
}

async function hydrateFixtureRows(
  db: SupabaseClient,
  fixtures: Record<string, unknown>[],
  includeReliabilityContext: boolean,
) {
  if (fixtures.length === 0) return [];

  const fixtureRows = fixtures.map((row) => normalizeFixtureRow(row));
  const fixtureIds = fixtureRows.map((fixture) => fixture.id);
  const clanIds = [
    ...new Set(
      fixtureRows.flatMap((fixture) => [
        fixture.homeClan.id,
        fixture.awayClan.id,
      ]),
    ),
  ];

  const [
    players,
    participantIds,
    clocks,
    goals,
    events,
    blueCards,
    reliabilityContexts,
  ] =
    await Promise.all([
      loadPlayers(db, clanIds),
      loadParticipantIds(db, fixtureIds),
      loadClocks(db, fixtureIds),
      loadGoals(db, fixtureIds),
      loadEvents(db, fixtureIds),
      loadBlueCards(db, fixtureIds),
      includeReliabilityContext
        ? Promise.all(
            fixtureIds.map((fixtureId) =>
              loadMatchReliabilityContext(db, "CLAN", fixtureId)
            ),
          )
        : Promise.resolve(fixtureIds.map(() => null)),
    ]);

  const riskSignals = await loadRefereeRiskSignals(
    db,
    players.map((player) => player.id),
    clanIds,
  );

  return fixtureRows.map((fixture, fixtureIndex) => {
    const fixturePlayers = players.filter(
      (player) =>
        player.clanId === fixture.homeClan.id ||
        player.clanId === fixture.awayClan.id,
    );
    const fixtureParticipantIds = participantIds.get(fixture.id) ?? [];
    const relevantPlayerIds = fixtureParticipantIds.length > 0
      ? fixtureParticipantIds
      : fixturePlayers.map((player) => player.id);

    return {
      ...fixture,
      players: fixturePlayers,
      participantIds: fixtureParticipantIds,
      clock: clocks.get(fixture.id) ?? null,
      goals: goals.filter((goal) => goal.fixtureId === fixture.id),
      events: events.filter((event) => event.fixtureId === fixture.id),
      blueCards: blueCards.filter((card) => card.fixtureId === fixture.id),
      riskContext: riskContextFor(
        riskSignals,
        [fixture.homeClan.id, fixture.awayClan.id],
        relevantPlayerIds,
      ),
      reliabilityContext: reliabilityContexts[fixtureIndex] ?? null,
    };
  });
}

async function loadParticipantIds(db: SupabaseClient, fixtureIds: string[]) {
  const participantIds = new Map<string, string[]>();
  if (fixtureIds.length === 0) return participantIds;

  const { data, error } = await db
    .from("fixture_player_appearances")
    .select("fixture_id,profile_id")
    .in("fixture_id", fixtureIds)
    .eq("played", true);

  if (error) throw error;

  for (const row of data ?? []) {
    const fixtureId = String(row.fixture_id);
    const current = participantIds.get(fixtureId) ?? [];
    current.push(String(row.profile_id));
    participantIds.set(fixtureId, current);
  }

  return participantIds;
}

async function loadPlayers(db: SupabaseClient, clanIds: string[]) {
  if (clanIds.length === 0) return [];

  const { data, error } = await db
    .from("clan_members")
    .select(
      `
        clan_id,
        profile_id,
        role,
        profiles!clan_members_profile_id_fkey(
          id,
          display_name,
          username,
          avatar_url
        )
      `,
    )
    .in("clan_id", clanIds)
    .is("left_at", null)
    .order("role");

  if (error) throw error;

  return (data ?? []).map((row) => {
    const profile = asObject(row.profiles);
    return {
      id: String(row.profile_id),
      clanId: String(row.clan_id),
      role: String(row.role ?? "member"),
      displayName: String(profile.display_name ?? "Unnamed player"),
      username: nullableString(profile.username),
      avatarUrl: nullableString(profile.avatar_url),
      ratingAtTeamAssignment: null,
    } satisfies Player;
  });
}

async function loadClocks(db: SupabaseClient, fixtureIds: string[]) {
  const clocks = new Map<string, FixtureClock>();
  if (fixtureIds.length === 0) return clocks;

  const { data, error } = await db
    .from("fixture_clock_states")
    .select(
      "fixture_id,status,started_at,accumulated_seconds,duration_seconds",
    )
    .in("fixture_id", fixtureIds);

  if (error) throw error;

  for (const row of data ?? []) {
    clocks.set(String(row.fixture_id), {
      status: String(row.status) as FixtureClock["status"],
      startedAt: nullableString(row.started_at),
      accumulatedSeconds: Number(row.accumulated_seconds ?? 0),
      durationSeconds: Number(row.duration_seconds ?? 3600),
    });
  }

  return clocks;
}

async function loadGoals(db: SupabaseClient, fixtureIds: string[]) {
  if (fixtureIds.length === 0) return [];

  const { data, error } = await db
    .from("fixture_scorers")
    .select(
      "id,fixture_id,clan_id,profile_id,assist_profile_id,minute,created_at",
    )
    .in("fixture_id", fixtureIds)
    .order("minute");

  if (error) throw error;

  return (data ?? []).map((row) => ({
    id: String(row.id),
    fixtureId: String(row.fixture_id),
    clanId: String(row.clan_id),
    profileId: String(row.profile_id),
    assistProfileId: nullableString(row.assist_profile_id),
    minute: Number(row.minute ?? 1),
    createdAt: String(row.created_at),
  } satisfies Goal));
}

async function loadEvents(db: SupabaseClient, fixtureIds: string[]) {
  if (fixtureIds.length === 0) return [];

  const { data, error } = await db
    .from("fixture_events")
    .select(
      "id,fixture_id,event_type,clan_id,profile_id,assist_profile_id,blue_card_id,minute,second,note,created_at",
    )
    .in("fixture_id", fixtureIds)
    .order("created_at", { ascending: false });

  if (error) throw error;

  return (data ?? []).map((row) => ({
    id: String(row.id),
    fixtureId: String(row.fixture_id),
    eventType: String(row.event_type) as FixtureEvent["eventType"],
    clanId: nullableString(row.clan_id),
    profileId: nullableString(row.profile_id),
    assistProfileId: nullableString(row.assist_profile_id),
    blueCardId: nullableString(row.blue_card_id),
    minute: Number(row.minute ?? 0),
    second: Number(row.second ?? 0),
    note: String(row.note ?? ""),
    createdAt: String(row.created_at),
  } satisfies FixtureEvent));
}

async function loadBlueCards(db: SupabaseClient, fixtureIds: string[]) {
  if (fixtureIds.length === 0) return [];

  const { data, error } = await db
    .from("fixture_blue_cards")
    .select(
      "id,fixture_id,clan_id,profile_id,started_at,expires_at,duration_seconds,status,minute,second",
    )
    .in("fixture_id", fixtureIds)
    .order("created_at", { ascending: false });

  if (error) throw error;

  return (data ?? []).map((row) => ({
    id: String(row.id),
    fixtureId: String(row.fixture_id),
    clanId: String(row.clan_id),
    profileId: String(row.profile_id),
    startedAt: String(row.started_at),
    expiresAt: String(row.expires_at),
    durationSeconds: Number(row.duration_seconds ?? 120),
    status: String(row.status) as BlueCard["status"],
    minute: Number(row.minute ?? 0),
    second: Number(row.second ?? 0),
  } satisfies BlueCard));
}

function normalizeFixtureRow(row: Record<string, unknown>) {
  return {
    matchKind: "CLAN",
    id: String(row.id),
    status: String(row.status) as RefereeFixture["status"],
    venue: String(row.venue ?? ""),
    day: String(row.day ?? ""),
    timeSlot: String(row.time_slot ?? ""),
    matchDate: String(row.match_date ?? ""),
    cancellationCode: nullableString(row.cancellation_code),
    cancellationReason: nullableString(row.cancellation_reason),
    cancelledAt: nullableString(row.cancelled_at),
    cancelledBy: nullableString(row.cancelled_by),
    homeScore: nullableNumber(row.home_score),
    awayScore: nullableNumber(row.away_score),
    whiteAverageSr: null,
    blackAverageSr: null,
    matchAverageSr: null,
    teamSrSpread: null,
    homeClan: normalizeClan(asObject(row.home_clan)),
    awayClan: normalizeClan(asObject(row.away_clan)),
    players: [],
    participantIds: [],
    clock: null,
    goals: [],
    events: [],
    blueCards: [],
    riskContext: riskContextFor(new Map(), [], []),
    reliabilityContext: null,
  } satisfies RefereeFixture;
}

function normalizeClan(row: Record<string, unknown>): Clan {
  return {
    id: String(row.id),
    name: String(row.name ?? ""),
    tag: String(row.tag ?? ""),
    emblem: String(row.emblem ?? "⚽"),
    skillRating: Number(row.skill_rating ?? 1500),
  };
}

function asObject(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) {
    return asObject(value[0]);
  }

  if (value && typeof value === "object") {
    return value as Record<string, unknown>;
  }

  return {};
}

function nullableString(value: unknown) {
  if (value === null || value === undefined) return null;
  return String(value);
}

function nullableNumber(value: unknown) {
  if (value === null || value === undefined) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}
