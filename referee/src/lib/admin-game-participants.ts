import type { SupabaseClient } from "@supabase/supabase-js";

export type AdminGameParticipantSide =
  | "HOME"
  | "AWAY"
  | "WHITE"
  | "BLACK"
  | null;

export type AdminGameParticipantSource =
  | "BOOKING"
  | "ATTENDANCE"
  | "RELIABILITY_ROSTER"
  | "APPEARANCE";

export type AdminGameParticipant = {
  profileId: string;
  displayName: string;
  username: string | null;
  avatarUrl: string | null;
  clanId: string | null;
  side: AdminGameParticipantSide;
  role: string | null;
  source: AdminGameParticipantSource;
  bookingId: string | null;
  rosterEntryId: string | null;
  bookingStatus: "CONFIRMED" | "CANCELLED" | null;
  bookedAt: string | null;
  cancelledAt: string | null;
  expectedForMatch: boolean | null;
  checkedInAt: string | null;
  attendanceOutcome: string | null;
  planned: boolean;
  played: boolean;
  ratingAtTeamAssignment: number | null;
  ratingAtStart: number | null;
  ratingChange: number | null;
};

export type AdminSoloGameParticipants = {
  matchKind: "SOLO";
  matchId: string;
  status: string;
  capacity: number;
  capacityPerSide: number;
  rosterSource:
    | "CONFIRMED_BOOKINGS"
    | "FIELD_CANCELLATION_ATTENDANCE"
    | "BOOKING_HISTORY";
  registeredPlayers: AdminGameParticipant[];
  actualPlayers: AdminGameParticipant[];
  withdrawnPlayers: AdminGameParticipant[];
  counts: {
    registered: number;
    actual: number;
    withdrawn: number;
  };
};

export type AdminClanGameParticipants = {
  matchKind: "CLAN";
  matchId: string;
  status: string;
  playersPerSide: number;
  homeClanId: string;
  awayClanId: string | null;
  plannedPlayers: AdminGameParticipant[];
  actualPlayers: AdminGameParticipant[];
  removedPlayers: AdminGameParticipant[];
  counts: {
    planned: number;
    plannedHome: number;
    plannedAway: number;
    actual: number;
    actualHome: number;
    actualAway: number;
    removed: number;
  };
};

export type AdminGameParticipants =
  | AdminSoloGameParticipants
  | AdminClanGameParticipants;

type Row = Record<string, unknown>;

export class AdminGameNotFoundError extends Error {
  constructor(matchKind: "SOLO" | "CLAN") {
    super(matchKind === "SOLO" ? "Solo game not found." : "Clan fixture not found.");
    this.name = "AdminGameNotFoundError";
  }
}

export async function loadAdminGameParticipants(
  db: SupabaseClient,
  matchKind: "SOLO" | "CLAN",
  matchId: string,
): Promise<AdminGameParticipants> {
  return matchKind === "SOLO"
    ? loadSoloGameParticipants(db, matchId)
    : loadClanGameParticipants(db, matchId);
}

async function loadSoloGameParticipants(
  db: SupabaseClient,
  matchId: string,
): Promise<AdminSoloGameParticipants> {
  const { data: game, error: gameError } = await db
    .from("open_queue_games")
    .select("id,status,capacity")
    .eq("id", matchId)
    .maybeSingle();

  if (gameError) {
    throw new Error(`Could not load solo game: ${gameError.message}`);
  }
  if (!game) throw new AdminGameNotFoundError("SOLO");

  const [bookingResult, attendanceResult] = await Promise.all([
    db
      .from("open_queue_bookings")
      .select(`
        id,
        profile_id,
        role,
        status,
        team,
        rating_at_team_assignment,
        played,
        booked_at,
        cancelled_at,
        profile:profiles!open_queue_bookings_profile_id_fkey(
          id,
          display_name,
          username,
          avatar_url
        )
      `)
      .eq("game_id", matchId)
      .order("booked_at"),
    db
      .from("match_attendance_records")
      .select(`
        id,
        booking_id,
        profile_id,
        side,
        role,
        expected_for_match,
        checked_in_at,
        outcome,
        cancelled_at,
        profile:profiles!match_attendance_records_profile_id_fkey(
          id,
          display_name,
          username,
          avatar_url
        )
      `)
      .eq("match_kind", "SOLO")
      .eq("open_queue_game_id", matchId),
  ]);

  if (bookingResult.error) {
    throw new Error(`Could not load solo bookings: ${bookingResult.error.message}`);
  }
  if (attendanceResult.error) {
    throw new Error(
      `Could not load solo attendance roster: ${attendanceResult.error.message}`,
    );
  }

  return buildSoloGameParticipants({
    matchId,
    status: stringValue(game.status),
    capacity: integerValue(game.capacity, 12),
    bookingRows: rows(bookingResult.data),
    attendanceRows: rows(attendanceResult.data),
  });
}

async function loadClanGameParticipants(
  db: SupabaseClient,
  matchId: string,
): Promise<AdminClanGameParticipants> {
  const { data: fixture, error: fixtureError } = await db
    .from("fixtures")
    .select("id,status,home_clan_id,away_clan_id")
    .eq("id", matchId)
    .maybeSingle();

  if (fixtureError) {
    throw new Error(`Could not load clan fixture: ${fixtureError.message}`);
  }
  if (!fixture) throw new AdminGameNotFoundError("CLAN");

  const [rosterResult, appearanceResult, attendanceResult] = await Promise.all([
    db
      .from("fixture_reliability_roster_history")
      .select(`
        id,
        clan_id,
        profile_id,
        status,
        confirmed_at,
        ended_at,
        profile:profiles!fixture_reliability_roster_history_profile_id_fkey(
          id,
          display_name,
          username,
          avatar_url
        )
      `)
      .eq("fixture_id", matchId)
      .order("confirmed_at"),
    db
      .from("fixture_player_appearances")
      .select(`
        profile_id,
        clan_id,
        side,
        played,
        rating_at_start,
        rating_change,
        profile:profiles!fixture_player_appearances_profile_id_fkey(
          id,
          display_name,
          username,
          avatar_url
        )
      `)
      .eq("fixture_id", matchId)
      .eq("played", true),
    db
      .from("match_attendance_records")
      .select(`
        id,
        profile_id,
        clan_id,
        side,
        role,
        expected_for_match,
        checked_in_at,
        outcome,
        cancelled_at,
        profile:profiles!match_attendance_records_profile_id_fkey(
          id,
          display_name,
          username,
          avatar_url
        )
      `)
      .eq("match_kind", "CLAN")
      .eq("fixture_id", matchId),
  ]);

  if (rosterResult.error) {
    throw new Error(`Could not load planned clan roster: ${rosterResult.error.message}`);
  }
  if (appearanceResult.error) {
    throw new Error(`Could not load actual clan lineup: ${appearanceResult.error.message}`);
  }
  if (attendanceResult.error) {
    throw new Error(`Could not load clan attendance: ${attendanceResult.error.message}`);
  }

  return buildClanGameParticipants({
    matchId,
    status: stringValue(fixture.status),
    homeClanId: stringValue(fixture.home_clan_id),
    awayClanId: nullableString(fixture.away_clan_id),
    rosterRows: rows(rosterResult.data),
    appearanceRows: rows(appearanceResult.data),
    attendanceRows: rows(attendanceResult.data),
  });
}

export function buildSoloGameParticipants(input: {
  matchId: string;
  status: string;
  capacity: number;
  bookingRows: Row[];
  attendanceRows: Row[];
}): AdminSoloGameParticipants {
  const bookings = input.bookingRows
    .map(normalizeBookingParticipant)
    .filter((player): player is AdminGameParticipant => player !== null);
  const bookingById = new Map(
    bookings.flatMap((player) =>
      player.bookingId ? [[player.bookingId, player] as const] : []
    ),
  );
  const attendance = input.attendanceRows
    .map((row) => normalizeAttendanceParticipant(row, bookingById))
    .filter((player): player is AdminGameParticipant => player !== null);
  const confirmed = bookings.filter(
    (player) => player.bookingStatus === "CONFIRMED",
  );
  const fieldCancelled = attendance.filter(
    (player) =>
      player.expectedForMatch === true &&
      player.attendanceOutcome === "FIELD_CANCELLED",
  );

  let rosterSource: AdminSoloGameParticipants["rosterSource"];
  let registeredPlayers: AdminGameParticipant[];
  if (input.status === "CANCELLED" && fieldCancelled.length > 0) {
    rosterSource = "FIELD_CANCELLATION_ATTENDANCE";
    registeredPlayers = fieldCancelled;
  } else if (input.status === "CANCELLED") {
    // Pre-policy games have no immutable attendance snapshot. The latest
    // booking per player is the best available historical record and is
    // deliberately labelled as history rather than a confirmed lineup.
    rosterSource = "BOOKING_HISTORY";
    registeredPlayers = bookings;
  } else {
    rosterSource = "CONFIRMED_BOOKINGS";
    registeredPlayers = confirmed;
  }

  registeredPlayers = sortParticipants(dedupeLatestByProfile(registeredPlayers));
  const registeredBookingIds = new Set(
    registeredPlayers.flatMap((player) =>
      player.bookingId ? [player.bookingId] : []
    ),
  );
  const playedBookings = confirmed.filter((player) => player.played);
  const checkedInAttendance = attendance.filter(
    (player) => player.checkedInAt !== null,
  );
  const actualPlayers = sortParticipants(dedupeLatestByProfile([
    ...playedBookings,
    ...checkedInAttendance,
  ]));
  const withdrawnPlayers = sortParticipants(dedupeLatestByProfile(
    bookings.filter(
      (player) =>
        player.bookingStatus === "CANCELLED" &&
        (!player.bookingId || !registeredBookingIds.has(player.bookingId)),
    ),
  ));

  return {
    matchKind: "SOLO",
    matchId: input.matchId,
    status: input.status,
    capacity: input.capacity,
    capacityPerSide: Math.floor(input.capacity / 2),
    rosterSource,
    registeredPlayers,
    actualPlayers,
    withdrawnPlayers,
    counts: {
      registered: registeredPlayers.length,
      actual: actualPlayers.length,
      withdrawn: withdrawnPlayers.length,
    },
  };
}

export function buildClanGameParticipants(input: {
  matchId: string;
  status: string;
  homeClanId: string;
  awayClanId: string | null;
  rosterRows: Row[];
  appearanceRows: Row[];
  attendanceRows: Row[];
}): AdminClanGameParticipants {
  const attendance = input.attendanceRows
    .map((row) => normalizeAttendanceParticipant(row, new Map()))
    .filter((player): player is AdminGameParticipant => player !== null);
  const attendanceByProfile = new Map(
    attendance.map((player) => [player.profileId, player]),
  );
  const roster = input.rosterRows
    .map((row) =>
      normalizeRosterParticipant(
        row,
        input.homeClanId,
        input.awayClanId,
        attendanceByProfile,
      )
    )
    .filter((player): player is AdminGameParticipant => player !== null);
  const plannedPlayers = sortParticipants(dedupeLatestByProfile(
    roster.filter((player) => player.planned),
  ));
  const removedPlayers = sortParticipants(dedupeLatestByProfile(
    roster.filter((player) => !player.planned),
  ));
  const appearances = input.appearanceRows
    .map((row) => normalizeAppearanceParticipant(row, attendanceByProfile))
    .filter((player): player is AdminGameParticipant => player !== null);
  const checkedInPlayers = attendance
    .filter((player) => player.checkedInAt !== null)
    .map((player) => ({ ...player, played: true }));
  const actualPlayers = sortParticipants(dedupeLatestByProfile([
    ...checkedInPlayers,
    ...appearances,
  ]));

  return {
    matchKind: "CLAN",
    matchId: input.matchId,
    status: input.status,
    playersPerSide: 6,
    homeClanId: input.homeClanId,
    awayClanId: input.awayClanId,
    plannedPlayers,
    actualPlayers,
    removedPlayers,
    counts: {
      planned: plannedPlayers.length,
      plannedHome: countSide(plannedPlayers, "HOME"),
      plannedAway: countSide(plannedPlayers, "AWAY"),
      actual: actualPlayers.length,
      actualHome: countSide(actualPlayers, "HOME"),
      actualAway: countSide(actualPlayers, "AWAY"),
      removed: removedPlayers.length,
    },
  };
}

function normalizeBookingParticipant(row: Row): AdminGameParticipant | null {
  const profileId = nullableString(row.profile_id);
  const bookingId = nullableString(row.id);
  if (!profileId || !bookingId) return null;
  const status = nullableString(row.status)?.toUpperCase();

  return {
    ...profileFields(row, profileId),
    clanId: null,
    side: sideValue(row.team),
    role: nullableString(row.role),
    source: "BOOKING",
    bookingId,
    rosterEntryId: null,
    bookingStatus: status === "CANCELLED" ? "CANCELLED" : "CONFIRMED",
    bookedAt: nullableString(row.booked_at),
    cancelledAt: nullableString(row.cancelled_at),
    expectedForMatch: status === "CONFIRMED",
    checkedInAt: null,
    attendanceOutcome: null,
    planned: status === "CONFIRMED",
    played: row.played === true,
    ratingAtTeamAssignment: nullableNumber(row.rating_at_team_assignment),
    ratingAtStart: null,
    ratingChange: null,
  };
}

function normalizeAttendanceParticipant(
  row: Row,
  bookingById: Map<string, AdminGameParticipant>,
): AdminGameParticipant | null {
  const profileId = nullableString(row.profile_id);
  if (!profileId) return null;
  const bookingId = nullableString(row.booking_id);
  const booking = bookingId ? bookingById.get(bookingId) : undefined;
  const checkedInAt = nullableString(row.checked_in_at);

  return {
    ...profileFields(row, profileId, booking),
    clanId: nullableString(row.clan_id) ?? booking?.clanId ?? null,
    side: sideValue(row.side) ?? booking?.side ?? null,
    role: nullableString(row.role) ?? booking?.role ?? null,
    source: "ATTENDANCE",
    bookingId,
    rosterEntryId: null,
    bookingStatus: booking?.bookingStatus ?? null,
    bookedAt: booking?.bookedAt ?? null,
    cancelledAt: nullableString(row.cancelled_at) ?? booking?.cancelledAt ?? null,
    expectedForMatch: booleanOrNull(row.expected_for_match),
    checkedInAt,
    attendanceOutcome: nullableString(row.outcome)?.toUpperCase() ?? null,
    planned: row.expected_for_match === true,
    played: booking?.played === true || checkedInAt !== null,
    ratingAtTeamAssignment: booking?.ratingAtTeamAssignment ?? null,
    ratingAtStart: null,
    ratingChange: null,
  };
}

function normalizeRosterParticipant(
  row: Row,
  homeClanId: string,
  awayClanId: string | null,
  attendanceByProfile: Map<string, AdminGameParticipant>,
): AdminGameParticipant | null {
  const profileId = nullableString(row.profile_id);
  const clanId = nullableString(row.clan_id);
  if (!profileId || !clanId) return null;
  const attendance = attendanceByProfile.get(profileId);
  const status = nullableString(row.status)?.toUpperCase();
  const planned = status === "CONFIRMED";

  return {
    ...profileFields(row, profileId, attendance),
    clanId,
    side: clanSide(clanId, homeClanId, awayClanId),
    role: attendance?.role ?? null,
    source: "RELIABILITY_ROSTER",
    bookingId: null,
    rosterEntryId: nullableString(row.id),
    bookingStatus: null,
    bookedAt: nullableString(row.confirmed_at),
    cancelledAt: nullableString(row.ended_at),
    expectedForMatch: planned,
    checkedInAt: attendance?.checkedInAt ?? null,
    attendanceOutcome: attendance?.attendanceOutcome ?? null,
    planned,
    played: attendance?.played ?? false,
    ratingAtTeamAssignment: null,
    ratingAtStart: null,
    ratingChange: null,
  };
}

function normalizeAppearanceParticipant(
  row: Row,
  attendanceByProfile: Map<string, AdminGameParticipant>,
): AdminGameParticipant | null {
  const profileId = nullableString(row.profile_id);
  if (!profileId) return null;
  const attendance = attendanceByProfile.get(profileId);

  return {
    ...profileFields(row, profileId, attendance),
    clanId: nullableString(row.clan_id) ?? attendance?.clanId ?? null,
    side: sideValue(row.side) ?? attendance?.side ?? null,
    role: attendance?.role ?? null,
    source: "APPEARANCE",
    bookingId: null,
    rosterEntryId: null,
    bookingStatus: null,
    bookedAt: null,
    cancelledAt: attendance?.cancelledAt ?? null,
    expectedForMatch: attendance?.expectedForMatch ?? null,
    checkedInAt: attendance?.checkedInAt ?? null,
    attendanceOutcome: attendance?.attendanceOutcome ?? null,
    planned: attendance?.planned ?? false,
    played: row.played === true,
    ratingAtTeamAssignment: null,
    ratingAtStart: nullableNumber(row.rating_at_start),
    ratingChange: nullableNumber(row.rating_change),
  };
}

function profileFields(
  row: Row,
  profileId: string,
  fallback?: AdminGameParticipant,
) {
  const profile = asObject(row.profile);
  return {
    profileId,
    displayName:
      nullableString(profile.display_name) ??
      fallback?.displayName ??
      "Unnamed player",
    username: nullableString(profile.username) ?? fallback?.username ?? null,
    avatarUrl: nullableString(profile.avatar_url) ?? fallback?.avatarUrl ?? null,
  };
}

function dedupeLatestByProfile(
  players: AdminGameParticipant[],
): AdminGameParticipant[] {
  const byProfile = new Map<string, AdminGameParticipant>();
  for (const player of players) {
    const existing = byProfile.get(player.profileId);
    if (!existing || participantTimestamp(player) >= participantTimestamp(existing)) {
      byProfile.set(player.profileId, player);
    }
  }
  return [...byProfile.values()];
}

function participantTimestamp(player: AdminGameParticipant) {
  const value = player.bookedAt ?? player.cancelledAt;
  if (!value) return 0;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : 0;
}

function sortParticipants(players: AdminGameParticipant[]) {
  const sideOrder = new Map<AdminGameParticipantSide, number>([
    ["HOME", 0],
    ["WHITE", 0],
    ["AWAY", 1],
    ["BLACK", 1],
    [null, 2],
  ]);
  const roleOrder = new Map([
    ["GK", 0],
    ["DEF", 1],
    ["MID", 2],
    ["ATT", 3],
  ]);
  return [...players].sort((left, right) =>
    (sideOrder.get(left.side) ?? 2) - (sideOrder.get(right.side) ?? 2) ||
    (roleOrder.get(left.role ?? "") ?? 4) -
      (roleOrder.get(right.role ?? "") ?? 4) ||
    left.displayName.localeCompare(right.displayName) ||
    left.profileId.localeCompare(right.profileId)
  );
}

function countSide(
  players: AdminGameParticipant[],
  side: Exclude<AdminGameParticipantSide, null>,
) {
  return players.filter((player) => player.side === side).length;
}

function clanSide(
  clanId: string,
  homeClanId: string,
  awayClanId: string | null,
): AdminGameParticipantSide {
  if (clanId === homeClanId) return "HOME";
  if (awayClanId && clanId === awayClanId) return "AWAY";
  return null;
}

function sideValue(value: unknown): AdminGameParticipantSide {
  const side = nullableString(value)?.toUpperCase();
  return side === "HOME" || side === "AWAY" || side === "WHITE" || side === "BLACK"
    ? side
    : null;
}

function rows(value: unknown): Row[] {
  return Array.isArray(value)
    ? value.filter(
      (item): item is Row => Boolean(item) && typeof item === "object",
    )
    : [];
}

function asObject(value: unknown): Row {
  if (Array.isArray(value)) return asObject(value[0]);
  return value && typeof value === "object" ? value as Row : {};
}

function stringValue(value: unknown) {
  return value === null || value === undefined ? "" : String(value);
}

function nullableString(value: unknown) {
  return value === null || value === undefined ? null : String(value);
}

function nullableNumber(value: unknown) {
  if (value === null || value === undefined) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function integerValue(value: unknown, fallback: number) {
  const number = Number(value);
  return Number.isInteger(number) ? number : fallback;
}

function booleanOrNull(value: unknown) {
  return typeof value === "boolean" ? value : null;
}
