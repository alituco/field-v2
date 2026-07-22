import type { SupabaseClient } from "@supabase/supabase-js";

export type AdminSubjectReport = {
  id: string;
  category: string;
  priority: string;
  status: string;
  details: string;
  source: string;
  reporterName: string;
  assignedTo: string | null;
  matchKind: "CLAN" | "SOLO" | null;
  matchId: string | null;
  createdAt: string;
  resolvedAt: string | null;
  resolutionNote: string | null;
};

export type AdminSubjectAction = {
  id: string;
  actionType: string;
  restrictionScope: string;
  reasonCode: string;
  userMessage: string;
  privateNote: string;
  startsAt: string;
  endsAt: string | null;
  revokedAt: string | null;
  revocationReason: string | null;
};

export type AdminSubjectIncident = {
  id: string;
  outcome: string;
  strikeDelta: number;
  activeBefore: number;
  activeAfter: number;
  occurredAt: string;
  expiresAt: string | null;
  matchId: string | null;
  reversed: boolean;
};

export type AdminSubjectGame = {
  id: string;
  matchKind: "CLAN" | "SOLO";
  label: string;
  date: string;
  venue: string;
  status: string;
  result: string;
  role: string | null;
  ratingChange: number | null;
  played: boolean;
};

export type AdminSubjectDetail = {
  subjectType: "PLAYER" | "CLAN";
  id: string;
  name: string;
  secondary: string | null;
  avatar: string | null;
  createdAt: string;
  archivedAt: string | null;
  facts: Array<{ label: string; value: string }>;
  reports: AdminSubjectReport[];
  actions: AdminSubjectAction[];
  incidents: AdminSubjectIncident[];
  games: AdminSubjectGame[];
  memberships: Array<{
    id: string;
    name: string;
    tag: string;
    emblem: string;
    role: string;
    startedAt: string;
    endedAt: string | null;
  }>;
  ratingEvents: Array<{
    id: string;
    sourceType: string;
    sourceId: string;
    result: string;
    before: number;
    change: number;
    after: number;
    createdAt: string;
  }>;
  members: Array<{
    profileId: string;
    name: string;
    username: string | null;
    avatarUrl: string | null;
    role: string;
    joinedAt: string;
    leftAt: string | null;
  }>;
  audit: Array<{
    id: string;
    action: string;
    reason: string;
    createdAt: string;
  }>;
};

type Row = Record<string, unknown>;

export async function loadAdminSubjectDetail(
  db: SupabaseClient,
  subjectType: "PLAYER" | "CLAN",
  subjectId: string,
): Promise<AdminSubjectDetail> {
  return subjectType === "PLAYER"
    ? loadPlayerDetail(db, subjectId)
    : loadClanDetail(db, subjectId);
}

async function loadPlayerDetail(db: SupabaseClient, profileId: string) {
  const [
    profileResult,
    ratingResult,
    membershipResult,
    appearanceResult,
    bookingResult,
    ratingEventResult,
    reportResult,
    actionResult,
    incidentResult,
    auditResult,
  ] = await Promise.all([
    db.from("profiles").select("id,phone,display_name,username,avatar_url,bio,date_of_birth,created_at").eq("id", profileId).maybeSingle(),
    db.from("player_ratings").select("skill_rating,matches_played,wins,losses,draws,last_change,region").eq("profile_id", profileId).maybeSingle(),
    db.from("clan_members").select("clan_id,role,created_at,left_at").eq("profile_id", profileId).order("created_at", { ascending: false }),
    db.from("fixture_player_appearances").select("fixture_id,clan_id,side,played,rating_at_start,rating_change,created_at").eq("profile_id", profileId).order("created_at", { ascending: false }),
    db.from("open_queue_bookings").select("game_id,role,status,team,played,rating_change,booked_at").eq("profile_id", profileId).order("booked_at", { ascending: false }),
    db.from("player_rating_events").select("id,source_type,source_id,result,rating_before,rating_change,rating_after,created_at").eq("profile_id", profileId).order("created_at", { ascending: false }),
    db.from("moderation_reports").select("id,category,priority,status,details,source,reporter_profile_id,reporter_referee_id,assigned_admin_id,resolved_by,fixture_id,open_queue_game_id,created_at,resolved_at,resolution_note").eq("subject_profile_id", profileId).order("created_at", { ascending: false }),
    db.from("moderation_actions").select("id,action_type,restriction_scope,reason_code,user_message,private_note,starts_at,ends_at,revoked_at,revocation_reason").eq("subject_profile_id", profileId).order("created_at", { ascending: false }),
    db.from("reliability_incidents").select("id,outcome,strike_delta,active_count_before,active_count_after,occurred_at,expires_at,fixture_id,detail,reversal_of").eq("profile_id", profileId).order("occurred_at", { ascending: false }),
    db.from("admin_audit_events").select("id,action,reason,created_at").eq("entity_type", "PLAYER").eq("entity_id", profileId).order("created_at", { ascending: false }),
  ]);
  throwResultErrors([
    profileResult, ratingResult, membershipResult, appearanceResult,
    bookingResult, ratingEventResult, reportResult, actionResult,
    incidentResult, auditResult,
  ]);
  if (!profileResult.data) throw new Error("Player not found.");

  const memberships = rows(membershipResult.data);
  const clanIds = unique([
    ...memberships.map((row) => text(row.clan_id)),
    ...rows(appearanceResult.data).map((row) => text(row.clan_id)),
  ]);
  const fixtureIds = unique(rows(appearanceResult.data).map((row) => text(row.fixture_id)));
  const soloIds = unique(rows(bookingResult.data).map((row) => text(row.game_id)));
  const [clansResult, fixturesResult, soloResult] = await Promise.all([
    clanIds.length ? db.from("clans").select("id,name,tag,emblem").in("id", clanIds) : emptyResult(),
    fixtureIds.length ? db.from("fixtures").select("id,status,match_date,time_slot,venue,home_clan_id,away_clan_id,home_score,away_score").in("id", fixtureIds) : emptyResult(),
    soloIds.length ? db.from("open_queue_games").select("id,status,starts_at,venue,white_score,black_score").in("id", soloIds) : emptyResult(),
  ]);
  throwResultErrors([clansResult, fixturesResult, soloResult]);
  const fixtureById = rowMap(fixturesResult.data);
  const soloById = rowMap(soloResult.data);
  const fixtureClanIds = unique(rows(fixturesResult.data).flatMap((fixture) => [
    text(fixture.home_clan_id),
    text(fixture.away_clan_id),
  ]));
  const missingClanIds = fixtureClanIds.filter((id) => id && !clanIds.includes(id));
  const opponentClansResult = missingClanIds.length
    ? await db.from("clans").select("id,name,tag,emblem").in("id", missingClanIds)
    : await emptyResult();
  throwResultErrors([opponentClansResult]);
  const clanById = rowMap([
    ...rows(clansResult.data),
    ...rows(opponentClansResult.data),
  ]);
  const profile = profileResult.data as Row;
  const rating = (ratingResult.data ?? {}) as Row;

  return {
    subjectType: "PLAYER" as const,
    id: profileId,
    name: text(profile.display_name, "Unknown player"),
    secondary: nullableText(profile.username),
    avatar: nullableText(profile.avatar_url),
    createdAt: text(profile.created_at),
    archivedAt: null,
    facts: [
      { label: "Phone", value: text(profile.phone, "Not provided") },
      { label: "Date of birth", value: text(profile.date_of_birth, "Not provided") },
      { label: "Player SR", value: text(rating.skill_rating, "1200") },
      { label: "Record", value: `${integer(rating.wins)}W · ${integer(rating.draws)}D · ${integer(rating.losses)}L` },
      { label: "Matches played", value: text(rating.matches_played, "0") },
      { label: "Last SR change", value: signed(integer(rating.last_change)) },
    ],
    reports: await hydrateReports(db, reportResult.data),
    actions: mapActions(actionResult.data),
    incidents: mapIncidents(incidentResult.data),
    games: [
      ...rows(appearanceResult.data).map((appearance) => clanGame(appearance, fixtureById, clanById)),
      ...rows(bookingResult.data).map((booking) => soloGame(booking, soloById)),
    ].sort((left, right) => right.date.localeCompare(left.date)),
    memberships: memberships.map((membership) => {
      const clan = clanById.get(text(membership.clan_id)) ?? {};
      return {
        id: text(membership.clan_id),
        name: text(clan.name, "Unknown clan"),
        tag: text(clan.tag),
        emblem: text(clan.emblem, "⚽"),
        role: text(membership.role, "member"),
        startedAt: text(membership.created_at),
        endedAt: nullableText(membership.left_at),
      };
    }),
    ratingEvents: rows(ratingEventResult.data).map((row) => ({
      id: text(row.id),
      sourceType: text(row.source_type),
      sourceId: text(row.source_id),
      result: text(row.result),
      before: integer(row.rating_before),
      change: integer(row.rating_change),
      after: integer(row.rating_after),
      createdAt: text(row.created_at),
    })),
    members: [],
    audit: mapAudit(auditResult.data),
  } satisfies AdminSubjectDetail;
}

async function loadClanDetail(db: SupabaseClient, clanId: string) {
  const [clanResult, allClansResult, memberResult, homeResult, awayResult, reportResult, actionResult, incidentResult, auditResult] = await Promise.all([
    db.from("clans").select("id,name,tag,emblem,motto,skill_rating,wins,losses,created_at,archived_at").eq("id", clanId).maybeSingle(),
    db.from("clans").select("id,skill_rating").is("archived_at", null).order("skill_rating", { ascending: false }).order("name"),
    db.from("clan_members").select("profile_id,role,created_at,left_at").eq("clan_id", clanId).order("created_at", { ascending: false }),
    db.from("fixtures").select("id,status,match_date,time_slot,venue,home_clan_id,away_clan_id,home_score,away_score,home_sr_change,away_sr_change").eq("home_clan_id", clanId).order("match_date", { ascending: false }),
    db.from("fixtures").select("id,status,match_date,time_slot,venue,home_clan_id,away_clan_id,home_score,away_score,home_sr_change,away_sr_change").eq("away_clan_id", clanId).order("match_date", { ascending: false }),
    db.from("moderation_reports").select("id,category,priority,status,details,source,reporter_profile_id,reporter_referee_id,assigned_admin_id,resolved_by,fixture_id,open_queue_game_id,created_at,resolved_at,resolution_note").eq("subject_clan_id", clanId).order("created_at", { ascending: false }),
    db.from("moderation_actions").select("id,action_type,restriction_scope,reason_code,user_message,private_note,starts_at,ends_at,revoked_at,revocation_reason").eq("subject_clan_id", clanId).order("created_at", { ascending: false }),
    db.from("reliability_incidents").select("id,outcome,strike_delta,active_count_before,active_count_after,occurred_at,expires_at,fixture_id,detail,reversal_of").eq("clan_id", clanId).order("occurred_at", { ascending: false }),
    db.from("admin_audit_events").select("id,action,reason,created_at").eq("entity_type", "CLAN").eq("entity_id", clanId).order("created_at", { ascending: false }),
  ]);
  throwResultErrors([clanResult, allClansResult, memberResult, homeResult, awayResult, reportResult, actionResult, incidentResult, auditResult]);
  if (!clanResult.data) throw new Error("Clan not found.");

  const members = rows(memberResult.data);
  const memberIds = unique(members.map((row) => text(row.profile_id)));
  const fixtureRows = dedupeRows([...rows(homeResult.data), ...rows(awayResult.data)]);
  const opponentIds = unique(fixtureRows.flatMap((row) => [text(row.home_clan_id), text(row.away_clan_id)]));
  const [profilesResult, clansResult] = await Promise.all([
    memberIds.length ? db.from("profiles").select("id,display_name,username,avatar_url").in("id", memberIds) : emptyResult(),
    opponentIds.length ? db.from("clans").select("id,name,tag,emblem").in("id", opponentIds) : emptyResult(),
  ]);
  throwResultErrors([profilesResult, clansResult]);
  const profileById = rowMap(profilesResult.data);
  const clanById = rowMap(clansResult.data);
  const clan = clanResult.data as Row;
  const allClans = rows(allClansResult.data);
  const rank = allClans.findIndex((row) => text(row.id) === clanId);

  return {
    subjectType: "CLAN" as const,
    id: clanId,
    name: text(clan.name, "Unknown clan"),
    secondary: text(clan.tag),
    avatar: text(clan.emblem, "⚽"),
    createdAt: text(clan.created_at),
    archivedAt: nullableText(clan.archived_at),
    facts: [
      { label: "Clan SR", value: text(clan.skill_rating, "1500") },
      { label: "Bahrain rank", value: rank < 0 ? "Not ranked" : `#${rank + 1}` },
      { label: "Record", value: `${integer(clan.wins)}W · ${integer(clan.losses)}L` },
      { label: "Members", value: String(members.filter((row) => !row.left_at).length) },
      { label: "Motto", value: text(clan.motto, "No motto") },
      { label: "Status", value: clan.archived_at ? "Archived" : "Active" },
    ],
    reports: await hydrateReports(db, reportResult.data),
    actions: mapActions(actionResult.data),
    incidents: mapIncidents(incidentResult.data),
    games: fixtureRows.map((fixture) => {
      const home = clanById.get(text(fixture.home_clan_id)) ?? {};
      const away = clanById.get(text(fixture.away_clan_id)) ?? {};
      const homeSide = text(fixture.home_clan_id) === clanId;
      return {
        id: text(fixture.id),
        matchKind: "CLAN" as const,
        label: `${text(home.tag, "HOME")} vs ${text(away.tag, "AWAY")}`,
        date: text(fixture.match_date),
        venue: text(fixture.venue),
        status: text(fixture.status),
        result: scoreText(fixture.home_score, fixture.away_score),
        role: homeSide ? "HOME" : "AWAY",
        ratingChange: nullableInteger(homeSide ? fixture.home_sr_change : fixture.away_sr_change),
        played: text(fixture.status) === "FINAL",
      };
    }).sort((left, right) => right.date.localeCompare(left.date)),
    memberships: [],
    ratingEvents: [],
    members: members.map((membership) => {
      const profile = profileById.get(text(membership.profile_id)) ?? {};
      return {
        profileId: text(membership.profile_id),
        name: text(profile.display_name, "Unknown player"),
        username: nullableText(profile.username),
        avatarUrl: nullableText(profile.avatar_url),
        role: text(membership.role, "member"),
        joinedAt: text(membership.created_at),
        leftAt: nullableText(membership.left_at),
      };
    }),
    audit: mapAudit(auditResult.data),
  } satisfies AdminSubjectDetail;
}

async function hydrateReports(db: SupabaseClient, value: unknown): Promise<AdminSubjectReport[]> {
  const reportRows = rows(value);
  const profileIds = unique(reportRows.map((row) => text(row.reporter_profile_id)));
  const refereeIds = unique(reportRows.flatMap((row) => [
    text(row.reporter_referee_id),
    text(row.assigned_admin_id),
    text(row.resolved_by),
  ]));
  const [profilesResult, refereesResult] = await Promise.all([
    profileIds.length
      ? db.from("profiles").select("id,display_name").in("id", profileIds)
      : emptyResult(),
    refereeIds.length
      ? db.from("referee_profiles").select("profile_id,display_name").in("profile_id", refereeIds)
      : emptyResult(),
  ]);
  throwResultErrors([profilesResult, refereesResult]);
  const profiles = rowMap(profilesResult.data);
  const referees = new Map(rows(refereesResult.data).map((row) => [text(row.profile_id), row]));
  return reportRows.map((row) => ({
    id: text(row.id), category: text(row.category), priority: text(row.priority),
    status: text(row.status), details: text(row.details), source: text(row.source),
    reporterName: row.reporter_profile_id
      ? text(profiles.get(text(row.reporter_profile_id))?.display_name, "Field player")
      : row.reporter_referee_id
        ? text(referees.get(text(row.reporter_referee_id))?.display_name, "Field official")
        : "Anonymous report",
    assignedTo: row.assigned_admin_id
      ? text(referees.get(text(row.assigned_admin_id))?.display_name, "Field admin")
      : null,
    matchKind: row.fixture_id ? "CLAN" : row.open_queue_game_id ? "SOLO" : null,
    matchId: nullableText(row.fixture_id) ?? nullableText(row.open_queue_game_id),
    createdAt: text(row.created_at), resolvedAt: nullableText(row.resolved_at),
    resolutionNote: nullableText(row.resolution_note),
  }));
}

function mapActions(value: unknown): AdminSubjectAction[] {
  return rows(value).map((row) => ({
    id: text(row.id), actionType: text(row.action_type),
    restrictionScope: text(row.restriction_scope), reasonCode: text(row.reason_code),
    userMessage: text(row.user_message), privateNote: text(row.private_note),
    startsAt: text(row.starts_at), endsAt: nullableText(row.ends_at),
    revokedAt: nullableText(row.revoked_at), revocationReason: nullableText(row.revocation_reason),
  }));
}

function mapIncidents(value: unknown): AdminSubjectIncident[] {
  return rows(value).map((row) => ({
    id: text(row.id), outcome: text(row.outcome), strikeDelta: integer(row.strike_delta),
    activeBefore: integer(row.active_count_before), activeAfter: integer(row.active_count_after),
    occurredAt: text(row.occurred_at), expiresAt: nullableText(row.expires_at),
    matchId: nullableText(row.fixture_id) ?? nullableText(asRow(row.detail).open_queue_game_id),
    reversed: Boolean(row.reversal_of),
  }));
}

function mapAudit(value: unknown) {
  return rows(value).map((row) => ({ id: text(row.id), action: text(row.action), reason: text(row.reason), createdAt: text(row.created_at) }));
}

function clanGame(appearance: Row, fixtures: Map<string, Row>, clans: Map<string, Row>): AdminSubjectGame {
  const fixture = fixtures.get(text(appearance.fixture_id)) ?? {};
  const home = clans.get(text(fixture.home_clan_id)) ?? {};
  const away = clans.get(text(fixture.away_clan_id)) ?? {};
  return {
    id: text(appearance.fixture_id), matchKind: "CLAN",
    label: `${text(home.tag, "HOME")} vs ${text(away.tag, "AWAY")}`,
    date: text(fixture.match_date, text(appearance.created_at)), venue: text(fixture.venue),
    status: text(fixture.status), result: scoreText(fixture.home_score, fixture.away_score),
    role: text(appearance.side), ratingChange: nullableInteger(appearance.rating_change),
    played: appearance.played === true,
  };
}

function soloGame(booking: Row, games: Map<string, Row>): AdminSubjectGame {
  const game = games.get(text(booking.game_id)) ?? {};
  return {
    id: text(booking.game_id), matchKind: "SOLO", label: "White vs Black",
    date: text(game.starts_at, text(booking.booked_at)), venue: text(game.venue),
    status: text(game.status), result: scoreText(game.white_score, game.black_score),
    role: text(booking.role), ratingChange: nullableInteger(booking.rating_change),
    played: booking.played === true,
  };
}

function throwResultErrors(results: Array<{ error: { message: string } | null }>) {
  const error = results.find((result) => result.error)?.error;
  if (error) throw new Error(error.message);
}

function emptyResult() { return Promise.resolve({ data: [] as Row[], error: null }); }
function rows(value: unknown): Row[] { return Array.isArray(value) ? value.filter((row): row is Row => Boolean(row) && typeof row === "object") : []; }
function asRow(value: unknown): Row { return value && typeof value === "object" ? value as Row : {}; }
function rowMap(value: unknown) { return new Map(rows(value).map((row) => [text(row.id), row])); }
function dedupeRows(value: Row[]) { return [...new Map(value.map((row) => [text(row.id), row])).values()]; }
function unique(values: string[]) { return [...new Set(values.filter(Boolean))]; }
function text(value: unknown, fallback = "") { return value === null || value === undefined || String(value).trim() === "" ? fallback : String(value).trim(); }
function nullableText(value: unknown) { const valueText = text(value); return valueText || null; }
function integer(value: unknown) { const parsed = Number(value); return Number.isFinite(parsed) ? Math.round(parsed) : 0; }
function nullableInteger(value: unknown) { if (value === null || value === undefined || value === "") return null; const parsed = Number(value); return Number.isFinite(parsed) ? Math.round(parsed) : null; }
function signed(value: number) { return value > 0 ? `+${value}` : String(value); }
function scoreText(home: unknown, away: unknown) { return home === null || home === undefined || away === null || away === undefined ? "—" : `${integer(home)}–${integer(away)}`; }
