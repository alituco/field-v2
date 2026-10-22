import { formatVenueDateTime } from "./admin-game-time.ts";
import type { createSupabaseAdmin } from "./supabase-admin";

type AdminDb = ReturnType<typeof createSupabaseAdmin>;
type Row = Record<string, unknown>;

const OPEN_REPORT_STATUSES = ["OPEN", "TRIAGED", "INVESTIGATING"];

function rows(value: unknown): Row[] {
  return Array.isArray(value)
    ? value.filter((item): item is Row => Boolean(item) && typeof item === "object")
    : [];
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function numberValue(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function unique(values: Array<string | null>): string[] {
  return [...new Set(values.filter((value): value is string => Boolean(value)))];
}

async function profilesById(db: AdminDb, ids: string[]) {
  const result = new Map<string, Row>();
  if (ids.length === 0) return result;
  const { data, error } = await db
    .from("profiles")
    .select("id,display_name,username,avatar_url")
    .in("id", ids);
  if (error) throw new Error(`Could not load report players: ${error.message}`);
  for (const row of rows(data)) {
    const id = stringValue(row.id);
    if (id) result.set(id, row);
  }
  return result;
}

async function clansById(db: AdminDb, ids: string[]) {
  const result = new Map<string, Row>();
  if (ids.length === 0) return result;
  const { data, error } = await db
    .from("clans")
    .select("id,name,tag,emblem")
    .in("id", ids);
  if (error) throw new Error(`Could not load report clans: ${error.message}`);
  for (const row of rows(data)) {
    const id = stringValue(row.id);
    if (id) result.set(id, row);
  }
  return result;
}

async function refereesById(db: AdminDb, ids: string[]) {
  const result = new Map<string, Row>();
  if (ids.length === 0) return result;
  const { data, error } = await db
    .from("referee_profiles")
    .select("profile_id,display_name,role")
    .in("profile_id", ids);
  if (error) throw new Error(`Could not load report staff: ${error.message}`);
  for (const row of rows(data)) {
    const id = stringValue(row.profile_id);
    if (id) result.set(id, row);
  }
  return result;
}

function displayName(row: Row | undefined, fallback: string) {
  return stringValue(row?.display_name) ?? stringValue(row?.name) ?? fallback;
}

export async function loadAdminReports(db: AdminDb, status?: string | null) {
  let query = db
    .from("moderation_reports")
    .select("*")
    .order("created_at", { ascending: false })
    .limit(250);

  if (status && status !== "ALL") query = query.eq("status", status);
  const { data, error } = await query;
  if (error) throw new Error(`Could not load reports: ${error.message}`);
  const reportRows = rows(data);

  const profileIds = unique(reportRows.flatMap((row) => [
    stringValue(row.reporter_profile_id),
    stringValue(row.subject_profile_id),
  ]));
  const clanIds = unique(reportRows.map((row) => stringValue(row.subject_clan_id)));
  const refereeIds = unique(reportRows.flatMap((row) => [
    stringValue(row.reporter_referee_id),
    stringValue(row.assigned_admin_id),
    stringValue(row.resolved_by),
  ]));
  const fixtureIds = unique(reportRows.map((row) => stringValue(row.fixture_id)));
  const soloIds = unique(reportRows.map((row) => stringValue(row.open_queue_game_id)));

  const [profiles, clans, referees, fixtureResult, soloResult] = await Promise.all([
    profilesById(db, profileIds),
    clansById(db, clanIds),
    refereesById(db, refereeIds),
    fixtureIds.length
      ? db.from("fixtures").select("id,home_clan_id,away_clan_id,match_date,time_slot,venue").in("id", fixtureIds)
      : Promise.resolve({ data: [], error: null }),
    soloIds.length
      ? db.from("open_queue_games").select("id,starts_at,timezone,venue").in("id", soloIds)
      : Promise.resolve({ data: [], error: null }),
  ]);
  if (fixtureResult.error) {
    throw new Error(`Could not load reported fixtures: ${fixtureResult.error.message}`);
  }
  if (soloResult.error) {
    throw new Error(`Could not load reported solo games: ${soloResult.error.message}`);
  }

  const fixtureRows = rows(fixtureResult.data);
  const fixtureClanIds = unique(fixtureRows.flatMap((row) => [
    stringValue(row.home_clan_id),
    stringValue(row.away_clan_id),
  ]));
  const fixtureClans = await clansById(
    db,
    fixtureClanIds.filter((id) => !clans.has(id)),
  );
  for (const [id, clan] of fixtureClans) clans.set(id, clan);
  const fixtures = new Map(fixtureRows.map((row) => [String(row.id), row]));
  const soloGames = new Map(rows(soloResult.data).map((row) => [String(row.id), row]));

  return reportRows.map((report) => {
    const subjectType = String(report.subject_type ?? "MATCH");
    const subjectProfileId = stringValue(report.subject_profile_id);
    const subjectClanId = stringValue(report.subject_clan_id);
    const fixtureId = stringValue(report.fixture_id);
    const soloId = stringValue(report.open_queue_game_id);
    const fixture = fixtureId ? fixtures.get(fixtureId) : undefined;
    const solo = soloId ? soloGames.get(soloId) : undefined;
    const homeClan = fixture
      ? clans.get(String(fixture.home_clan_id ?? ""))
      : undefined;
    const awayClan = fixture
      ? clans.get(String(fixture.away_clan_id ?? ""))
      : undefined;
    const reporterProfileId = stringValue(report.reporter_profile_id);
    const reporterRefereeId = stringValue(report.reporter_referee_id);
    const reporterProfile = reporterProfileId ? profiles.get(reporterProfileId) : undefined;
    const reporterReferee = reporterRefereeId ? referees.get(reporterRefereeId) : undefined;
    const assignedId = stringValue(report.assigned_admin_id);
    const subjectId = subjectProfileId ?? subjectClanId ?? fixtureId ?? soloId ?? "";
    const matchLabel = fixture
      ? `${stringValue(homeClan?.tag) ?? "Home"} vs ${stringValue(awayClan?.tag) ?? "Away"} · ${String(fixture.match_date ?? "")}`
      : solo
        ? `Solo match · ${formatVenueDateTime(String(solo.starts_at), solo.timezone)}`
        : null;

    return {
      id: String(report.id),
      status: String(report.status),
      priority: String(report.priority),
      category: String(report.category),
      description: String(report.details ?? ""),
      reporterName: reporterProfile
        ? displayName(reporterProfile, "Player")
        : reporterReferee
          ? displayName(reporterReferee, "Referee")
          : "Deleted account",
      reporterRole: reporterReferee ? String(reporterReferee.role ?? "REFEREE").toUpperCase() : "PLAYER",
      subjectType,
      subjectId,
      subjectName: subjectProfileId
        ? displayName(profiles.get(subjectProfileId), "Unknown player")
        : subjectClanId
          ? displayName(clans.get(subjectClanId), "Unknown clan")
          : matchLabel ?? "Match",
      matchLabel,
      matchKind: fixtureId ? "CLAN" : soloId ? "SOLO" : null,
      matchId: fixtureId ?? soloId,
      assignedTo: assignedId ? displayName(referees.get(assignedId), "Admin") : null,
      resolutionNote: stringValue(report.resolution_note),
      replayOffsetSeconds: report.replay_offset_seconds,
      createdAt: stringValue(report.created_at),
      updatedAt: stringValue(report.updated_at),
    };
  });
}

export async function loadFlaggedSubjects(db: AdminDb) {
  const [summaryResult, playerDirectoryResult, clanDirectoryResult] = await Promise.all([
    db
      .from("moderation_subject_summary")
      .select("*")
      .order("attention_score", { ascending: false })
      .limit(250),
    db
      .from("profiles")
      .select("id,display_name,username,avatar_url")
      .order("display_name", { ascending: true })
      .limit(500),
    db
      .from("clans")
      .select("id,name,tag,emblem")
      .is("archived_at", null)
      .order("name", { ascending: true })
      .limit(250),
  ]);
  if (summaryResult.error) {
    throw new Error(`Could not load flagged people and clans: ${summaryResult.error.message}`);
  }
  if (playerDirectoryResult.error || clanDirectoryResult.error) {
    throw new Error(
      `Could not load the moderation directory: ${
        playerDirectoryResult.error?.message ?? clanDirectoryResult.error?.message
      }`,
    );
  }

  const subjects = rows(summaryResult.data);
  const knownSubjects = new Set(
    subjects.map((row) => `${row.subject_type}:${row.subject_id}`),
  );
  for (const profile of rows(playerDirectoryResult.data)) {
    const id = stringValue(profile.id);
    if (!id || knownSubjects.has(`PLAYER:${id}`)) continue;
    subjects.push({
      subject_type: "PLAYER",
      subject_id: id,
      display_name: profile.display_name,
      secondary_label: profile.username,
      avatar_or_emblem: profile.avatar_url,
    });
  }
  for (const clan of rows(clanDirectoryResult.data)) {
    const id = stringValue(clan.id);
    if (!id || knownSubjects.has(`CLAN:${id}`)) continue;
    subjects.push({
      subject_type: "CLAN",
      subject_id: id,
      display_name: clan.name,
      secondary_label: clan.tag,
      avatar_or_emblem: clan.emblem,
    });
  }
  const playerIds = unique(
    subjects
      .filter((row) => row.subject_type === "PLAYER")
      .map((row) => stringValue(row.subject_id)),
  );
  const subjectIds = unique(subjects.map((row) => stringValue(row.subject_id)));
  const now = new Date().toISOString();

  const [appearanceResult, soloAppearanceResult, actionResult] = await Promise.all([
    playerIds.length
      ? db.from("fixture_player_appearances").select("profile_id").in("profile_id", playerIds).eq("played", true)
      : Promise.resolve({ data: [], error: null }),
    playerIds.length
      ? db.from("open_queue_bookings").select("profile_id").in("profile_id", playerIds).eq("status", "CONFIRMED").eq("played", true)
      : Promise.resolve({ data: [], error: null }),
    subjectIds.length
      ? db.from("moderation_actions")
          .select("id,subject_type,subject_profile_id,subject_clan_id,action_type,restriction_scope,reason_code,user_message,starts_at,ends_at,issued_by,created_at")
          .in("action_type", ["WARNING", "SUSPENSION", "BAN"])
          .is("revoked_at", null)
          .lte("starts_at", now)
          .or(`ends_at.is.null,ends_at.gt.${now}`)
          .order("created_at", { ascending: false })
      : Promise.resolve({ data: [], error: null }),
  ]);
  if (appearanceResult.error) throw new Error(`Could not count appearances: ${appearanceResult.error.message}`);
  if (soloAppearanceResult.error) throw new Error(`Could not count solo appearances: ${soloAppearanceResult.error.message}`);
  if (actionResult.error) throw new Error(`Could not load active moderation actions: ${actionResult.error.message}`);

  const appearances = new Map<string, number>();
  for (const row of [...rows(appearanceResult.data), ...rows(soloAppearanceResult.data)]) {
    const id = stringValue(row.profile_id);
    if (id) appearances.set(id, (appearances.get(id) ?? 0) + 1);
  }
  const actionRows = rows(actionResult.data);
  const issuerIds = unique(actionRows.map((row) => stringValue(row.issued_by)));
  const issuers = await refereesById(db, issuerIds);

  return subjects.map((subject) => {
    const subjectId = String(subject.subject_id);
    const subjectType = String(subject.subject_type);
    const activeActions = actionRows
      .filter((action) =>
        action.subject_type === subjectType &&
        (action.subject_profile_id === subjectId || action.subject_clan_id === subjectId))
      .map((action) => ({
        id: String(action.id),
        actionType: String(action.action_type),
        restrictionScope: String(action.restriction_scope),
        reasonCode: String(action.reason_code),
        userMessage: String(action.user_message),
        startsAt: stringValue(action.starts_at),
        endsAt: stringValue(action.ends_at),
        issuedBy: displayName(
          issuers.get(String(action.issued_by ?? "")),
          "Field admin",
        ),
      }));
    const matchesPlayed = appearances.get(subjectId) ?? 0;
    const lifetimeReports = numberValue(subject.total_reports);

    return {
      subjectType,
      subjectId,
      name: stringValue(subject.display_name) ?? "Unknown",
      username: stringValue(subject.secondary_label),
      avatarUrl: stringValue(subject.avatar_or_emblem),
      openReports: numberValue(subject.open_reports),
      highPriorityReports: numberValue(subject.high_priority_open_reports),
      reports30d: numberValue(subject.reports_30d),
      distinctReporters30d: numberValue(subject.distinct_reporters_30d),
      lifetimeReports,
      actionedReports: numberValue(subject.actioned_reports),
      dismissedReports: numberValue(subject.dismissed_reports),
      refereeReports: numberValue(subject.referee_reports),
      appearances: matchesPlayed,
      reportsPerTenAppearances: matchesPlayed > 0
        ? (lifetimeReports / matchesPlayed) * 10
        : null,
      activeAction: stringValue(subject.active_action_type) ?? activeActions[0]?.actionType ?? null,
      activeActionScope: stringValue(subject.active_action_scope) ?? activeActions[0]?.restrictionScope ?? null,
      activeActionEndsAt: stringValue(subject.active_action_ends_at) ?? activeActions[0]?.endsAt ?? null,
      activeActions,
      lastReportedAt: stringValue(subject.last_reported_at),
      attentionScore: numberValue(subject.attention_score),
    };
  });
}

export { OPEN_REPORT_STATUSES };
