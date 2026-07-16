import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  ModerationRiskLevel,
  ModerationRiskSignal,
  ModerationSubjectType,
  RefereeRiskContext,
} from "./types";

type Row = Record<string, unknown>;

const CLOSED_WITHOUT_SIGNAL = new Set(["DISMISSED", "DUPLICATE"]);
const OPEN_STATUSES = new Set(["OPEN", "TRIAGED", "INVESTIGATING"]);
const QUERY_CHUNK_SIZE = 80;

type SubjectAccumulator = {
  subjectType: ModerationSubjectType;
  subjectId: string;
  priorReports: number;
  recentReports: number;
  distinctRecentReporters: Set<string>;
  openReports: number;
  highPriorityOpenReports: number;
  actionedReports: number;
  priorRefereeReports: number;
  priorWarnings: number;
  priorDisciplinaryActions: number;
  activeRestriction: ModerationRiskSignal["activeRestriction"];
  lastReportedAt: string | null;
};

/**
 * Loads only aggregate, high-signal safety context. The caller is responsible
 * for first limiting the subject ids to matches assigned to the signed-in
 * referee (or to an authenticated admin scope). Raw allegations, categories,
 * notes, reporter ids and evidence never leave this module.
 */
export async function loadRefereeRiskSignals(
  db: SupabaseClient,
  profileIds: string[],
  clanIds: string[],
  now = new Date(),
): Promise<Map<string, ModerationRiskSignal>> {
  const uniqueProfiles = unique(profileIds);
  const uniqueClans = unique(clanIds);

  const [profileReports, clanReports, profileActions, clanActions] =
    await Promise.all([
      loadRowsInChunks(db, "moderation_reports", "subject_profile_id", uniqueProfiles,
        "subject_type,subject_profile_id,subject_clan_id,status,priority,reporter_profile_id,reporter_referee_id,created_at"),
      loadRowsInChunks(db, "moderation_reports", "subject_clan_id", uniqueClans,
        "subject_type,subject_profile_id,subject_clan_id,status,priority,reporter_profile_id,reporter_referee_id,created_at"),
      loadRowsInChunks(db, "moderation_actions", "subject_profile_id", uniqueProfiles,
        "subject_type,subject_profile_id,subject_clan_id,action_type,restriction_scope,starts_at,ends_at,revoked_at,created_at"),
      loadRowsInChunks(db, "moderation_actions", "subject_clan_id", uniqueClans,
        "subject_type,subject_profile_id,subject_clan_id,action_type,restriction_scope,starts_at,ends_at,revoked_at,created_at"),
    ]);

  return buildRefereeRiskSignals(
    [...profileReports, ...clanReports],
    [...profileActions, ...clanActions],
    now,
  );
}

/** Exported for focused policy tests; production callers use the loader above. */
export function buildRefereeRiskSignals(
  reportRows: Row[],
  actionRows: Row[],
  now = new Date(),
): Map<string, ModerationRiskSignal> {
  const accumulators = new Map<string, SubjectAccumulator>();
  const recentCutoff = now.getTime() - 30 * 24 * 60 * 60 * 1000;

  for (const report of reportRows) {
    const subject = subjectFromRow(report);
    const status = stringValue(report.status)?.toUpperCase();
    if (!subject || !status || CLOSED_WITHOUT_SIGNAL.has(status)) continue;

    const accumulator = getAccumulator(accumulators, subject.type, subject.id);
    const createdAt = dateValue(report.created_at);
    const isRecent = createdAt !== null && createdAt.getTime() >= recentCutoff;
    const isOpen = OPEN_STATUSES.has(status);

    accumulator.priorReports += 1;
    if (isRecent) {
      accumulator.recentReports += 1;
      const reporterKey = stringValue(report.reporter_referee_id)
        ? `REF:${String(report.reporter_referee_id)}`
        : stringValue(report.reporter_profile_id)
          ? `PLAYER:${String(report.reporter_profile_id)}`
          : null;
      if (reporterKey) accumulator.distinctRecentReporters.add(reporterKey);
    }
    if (isOpen) accumulator.openReports += 1;
    if (
      isOpen &&
      ["HIGH", "URGENT"].includes(
        stringValue(report.priority)?.toUpperCase() ?? "",
      )
    ) {
      accumulator.highPriorityOpenReports += 1;
    }
    if (status === "ACTIONED") accumulator.actionedReports += 1;
    if (stringValue(report.reporter_referee_id)) {
      accumulator.priorRefereeReports += 1;
    }
    if (
      createdAt &&
      (!accumulator.lastReportedAt ||
        createdAt.getTime() > new Date(accumulator.lastReportedAt).getTime())
    ) {
      accumulator.lastReportedAt = createdAt.toISOString();
    }
  }

  for (const action of actionRows) {
    const subject = subjectFromRow(action);
    if (!subject || action.revoked_at !== null && action.revoked_at !== undefined) {
      continue;
    }
    const actionType = stringValue(action.action_type)?.toUpperCase();
    if (!actionType) continue;

    const accumulator = getAccumulator(accumulators, subject.type, subject.id);
    if (actionType === "WARNING") accumulator.priorWarnings += 1;
    if (actionType === "SUSPENSION" || actionType === "BAN") {
      accumulator.priorDisciplinaryActions += 1;
      if (isActionActive(action, now)) {
        const restriction = {
          actionType: actionType as "SUSPENSION" | "BAN",
          scope: normalizeScope(action.restriction_scope),
          endsAt: dateValue(action.ends_at)?.toISOString() ?? null,
        };
        if (
          !accumulator.activeRestriction ||
          restriction.actionType === "BAN" ||
          (accumulator.activeRestriction.actionType !== "BAN" &&
            laterEnd(restriction.endsAt, accumulator.activeRestriction.endsAt))
        ) {
          accumulator.activeRestriction = restriction;
        }
      }
    }
  }

  const signals = new Map<string, ModerationRiskSignal>();
  for (const accumulator of accumulators.values()) {
    const labels = signalLabels(accumulator);
    // Do not prejudice a referee based on one unreviewed player-submitted
    // allegation. Only repeated, referee-originated, actioned or actively
    // restricted histories are shown.
    if (labels.length === 0) continue;

    const level = riskLevel(accumulator);
    const signal: ModerationRiskSignal = {
      subjectType: accumulator.subjectType,
      subjectId: accumulator.subjectId,
      level,
      labels,
      priorReports: accumulator.priorReports,
      recentReports: accumulator.recentReports,
      distinctRecentReporters: accumulator.distinctRecentReporters.size,
      openReports: accumulator.openReports,
      actionedReports: accumulator.actionedReports,
      priorRefereeReports: accumulator.priorRefereeReports,
      priorWarnings: accumulator.priorWarnings,
      activeRestriction: accumulator.activeRestriction,
      lastReportedAt: accumulator.lastReportedAt,
    };
    signals.set(subjectKey(signal.subjectType, signal.subjectId), signal);
  }
  return signals;
}

export function riskSignalFor(
  signals: Map<string, ModerationRiskSignal>,
  subjectType: ModerationSubjectType,
  subjectId: string,
) {
  return signals.get(subjectKey(subjectType, subjectId));
}

export function riskContextFor(
  signals: Map<string, ModerationRiskSignal>,
  teamIds: string[],
  playerIds: string[],
): RefereeRiskContext {
  return {
    teams: unique(teamIds)
      .map((id) => riskSignalFor(signals, "CLAN", id))
      .filter((signal): signal is ModerationRiskSignal => Boolean(signal)),
    players: unique(playerIds)
      .map((id) => riskSignalFor(signals, "PLAYER", id))
      .filter((signal): signal is ModerationRiskSignal => Boolean(signal))
      .sort((left, right) => riskOrder(right.level) - riskOrder(left.level)),
    guidance:
      "Use this as preparation context only. A prior flag is not proof of misconduct; judge this match on what you observe.",
  };
}

function signalLabels(accumulator: SubjectAccumulator): string[] {
  const labels: string[] = [];
  if (accumulator.activeRestriction) labels.push("Active restriction");
  if (accumulator.highPriorityOpenReports > 0) {
    labels.push("High-priority review open");
  }
  if (accumulator.actionedReports > 0) labels.push("Prior actioned report");
  if (accumulator.priorDisciplinaryActions > 0) {
    labels.push("Prior disciplinary action");
  }
  if (accumulator.priorWarnings > 0) labels.push("Previously warned");
  if (accumulator.priorRefereeReports > 0) {
    labels.push("Previously flagged by a referee");
  }
  if (accumulator.distinctRecentReporters.size >= 2) {
    labels.push("Repeated recent flags");
  }
  return labels;
}

function riskLevel(accumulator: SubjectAccumulator): ModerationRiskLevel {
  if (accumulator.activeRestriction || accumulator.highPriorityOpenReports > 0) {
    return "HIGH";
  }
  if (
    accumulator.actionedReports > 0 ||
    accumulator.priorDisciplinaryActions > 0 ||
    accumulator.priorWarnings > 0 ||
    accumulator.priorRefereeReports > 0 ||
    accumulator.distinctRecentReporters.size >= 3
  ) {
    return "ELEVATED";
  }
  return "AWARE";
}

function isActionActive(action: Row, now: Date) {
  const startsAt = dateValue(action.starts_at);
  const endsAt = dateValue(action.ends_at);
  return (!startsAt || startsAt <= now) && (!endsAt || endsAt > now);
}

function normalizeScope(
  value: unknown,
): NonNullable<ModerationRiskSignal["activeRestriction"]>["scope"] {
  const scope = stringValue(value)?.toUpperCase();
  return scope === "PLAY" || scope === "ACCOUNT" || scope === "SCHEDULING"
    ? scope
    : "NONE";
}

function riskOrder(level: ModerationRiskLevel) {
  return level === "HIGH" ? 3 : level === "ELEVATED" ? 2 : 1;
}

function laterEnd(candidate: string | null, current: string | null) {
  if (candidate === null) return true;
  if (current === null) return false;
  return new Date(candidate).getTime() > new Date(current).getTime();
}

function subjectFromRow(row: Row) {
  const type = stringValue(row.subject_type)?.toUpperCase();
  if (type === "PLAYER") {
    const id = stringValue(row.subject_profile_id);
    return id ? { type: "PLAYER" as const, id } : null;
  }
  if (type === "CLAN") {
    const id = stringValue(row.subject_clan_id);
    return id ? { type: "CLAN" as const, id } : null;
  }
  return null;
}

function getAccumulator(
  accumulators: Map<string, SubjectAccumulator>,
  subjectType: ModerationSubjectType,
  subjectId: string,
) {
  const key = subjectKey(subjectType, subjectId);
  let accumulator = accumulators.get(key);
  if (!accumulator) {
    accumulator = {
      subjectType,
      subjectId,
      priorReports: 0,
      recentReports: 0,
      distinctRecentReporters: new Set(),
      openReports: 0,
      highPriorityOpenReports: 0,
      actionedReports: 0,
      priorRefereeReports: 0,
      priorWarnings: 0,
      priorDisciplinaryActions: 0,
      activeRestriction: null,
      lastReportedAt: null,
    };
    accumulators.set(key, accumulator);
  }
  return accumulator;
}

async function loadRowsInChunks(
  db: SupabaseClient,
  table: "moderation_reports" | "moderation_actions",
  idColumn: "subject_profile_id" | "subject_clan_id",
  ids: string[],
  select: string,
): Promise<Row[]> {
  if (ids.length === 0) return [];
  const chunks = chunk(ids, QUERY_CHUNK_SIZE);
  const results = await Promise.all(
    chunks.map((idsInChunk) =>
      db.from(table).select(select).in(idColumn, idsInChunk),
    ),
  );
  const loaded: Row[] = [];
  for (const result of results) {
    if (result.error) {
      throw new Error(`Could not load referee safety context: ${result.error.message}`);
    }
    loaded.push(...((result.data ?? []) as unknown as Row[]));
  }
  return loaded;
}

function subjectKey(type: ModerationSubjectType, id: string) {
  return `${type}:${id}`;
}

function unique(values: string[]) {
  return [...new Set(values.map((value) => value.trim()).filter(Boolean))];
}

function chunk<T>(values: T[], size: number) {
  const chunks: T[][] = [];
  for (let index = 0; index < values.length; index += size) {
    chunks.push(values.slice(index, index + size));
  }
  return chunks;
}

function stringValue(value: unknown) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function dateValue(value: unknown) {
  const raw = stringValue(value);
  if (!raw) return null;
  const date = new Date(raw);
  return Number.isFinite(date.getTime()) ? date : null;
}
