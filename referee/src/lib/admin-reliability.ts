import type { SupabaseClient } from "@supabase/supabase-js";

import {
  normalizeReliabilityPolicyDraftConfig,
  parseReliabilityPolicyConfig,
  resolveReliabilityPolicyAt,
  validReliabilityRevision,
  type ReliabilityPolicyState,
  type ReliabilityPolicyVersion,
} from "./reliability-policy";

type Row = Record<string, unknown>;

export type AdminReliabilityPolicyPayload = {
  asOf: string;
  inForce: ReliabilityPolicyVersion | null;
  scheduled: ReliabilityPolicyVersion[];
  drafts: ReliabilityPolicyVersion[];
  history: ReliabilityPolicyVersion[];
  attendanceQueue?: AdminReliabilityQueueItem[];
  appealsQueue?: AdminReliabilityAppealQueueItem[];
};

export type AdminReliabilityQueueItem = {
  id: string;
  title: string;
  detail: string;
  status: string;
  createdAt: string | null;
};

export type AdminReliabilityAppealQueueItem = AdminReliabilityQueueItem & {
  attendanceId: string;
  playerName: string;
  category: string;
  message: string;
  matchKind: string;
  outcome: string;
  strikeDelta: number;
  refundBps: number;
  depositResolution: string;
};

export async function loadAdminReliabilityPolicies(
  db: SupabaseClient,
  at: Date = new Date(),
): Promise<AdminReliabilityPolicyPayload> {
  const { data, error } = await db
    .from("reliability_policy_versions")
    .select("*")
    .order("effective_from", { ascending: false })
    .order("version", { ascending: false });
  if (error) {
    throw new Error(`Could not load reliability policies: ${error.message}`);
  }

  const policyRows = rows(data);
  const actorIds = [...new Set(policyRows.flatMap((row) => [
    nullableString(row.created_by),
    nullableString(row.published_by),
  ]).filter((id): id is string => Boolean(id)))];
  const actorResult = actorIds.length > 0
    ? await db
        .from("referee_profiles")
        .select("profile_id,display_name")
        .in("profile_id", actorIds)
    : { data: [], error: null };
  if (actorResult.error) {
    throw new Error(`Could not load reliability policy authors: ${actorResult.error.message}`);
  }
  const actors = new Map(
    rows(actorResult.data).map((row) => [
      String(row.profile_id),
      String(row.display_name ?? "Field admin"),
    ]),
  );

  const versions = policyRows.map((row) =>
    normalizeAdminReliabilityPolicyVersion(row, actors));
  const published = versions
    .filter((version) => version.state === "PUBLISHED")
    .sort((left, right) =>
      Date.parse(right.effectiveFrom) - Date.parse(left.effectiveFrom) ||
      right.version - left.version);
  const asOf = at.toISOString();
  const queues = await loadReliabilityQueues(db);
  const scheduledByEffectiveDate = new Map<string, ReliabilityPolicyVersion>();
  for (const version of published) {
    if (Date.parse(version.effectiveFrom) <= at.getTime()) continue;
    const existing = scheduledByEffectiveDate.get(version.effectiveFrom);
    if (!existing || version.version > existing.version) {
      scheduledByEffectiveDate.set(version.effectiveFrom, version);
    }
  }

  return {
    asOf,
    inForce: resolveReliabilityPolicyAt(published, at),
    scheduled: [...scheduledByEffectiveDate.values()]
      .sort((left, right) => Date.parse(left.effectiveFrom) - Date.parse(right.effectiveFrom)),
    drafts: versions
      .filter((version) => version.state === "DRAFT")
      .sort((left, right) => Date.parse(right.updatedAt) - Date.parse(left.updatedAt)),
    history: published,
    ...queues,
  };
}

async function loadReliabilityQueues(db: SupabaseClient): Promise<{
  attendanceQueue?: AdminReliabilityQueueItem[];
  appealsQueue?: AdminReliabilityAppealQueueItem[];
}> {
  const [attendanceResult, appealResult] = await Promise.all([
    db
      .from("match_attendance_records")
      .select(
        "id,profile_id,match_kind,outcome,strike_delta,refund_bps,checked_in_at,check_in_deadline_at,appeal_due_at,finalized_at,created_at",
      )
      .in("outcome", [
        "LATE",
        "NO_SHOW",
        "CANCELLED_LATE",
        "CANCELLED_VERY_LATE",
      ])
      .order("finalized_at", { ascending: false })
      .limit(40),
    db
      .from("reliability_appeals")
      .select(
        "id,attendance_id,appellant_profile_id,category,message,status,appeal_due_at,created_at",
      )
      .in("status", ["OPEN", "REVIEWING"])
      .order("created_at", { ascending: true })
      .limit(40),
  ]);

  const attendanceRows = attendanceResult.error ? [] : rows(attendanceResult.data);
  const appealRows = appealResult.error ? [] : rows(appealResult.data);
  const appealedAttendanceIds = [...new Set(appealRows
    .map((row) => nullableString(row.attendance_id))
    .filter((id): id is string => Boolean(id)))];
  const appealAttendanceResult = appealedAttendanceIds.length > 0
    ? await db
        .from("match_attendance_records")
        .select("id,match_kind,outcome,strike_delta,refund_bps,deposit_resolution")
        .in("id", appealedAttendanceIds)
    : { data: [], error: null };
  const appealedAttendance = new Map(
    rows(appealAttendanceResult.data).map((row) => [String(row.id), row]),
  );
  const profileIds = [...new Set([
    ...attendanceRows.map((row) => nullableString(row.profile_id)),
    ...appealRows.map((row) => nullableString(row.appellant_profile_id)),
  ].filter((id): id is string => Boolean(id)))];
  const profileResult = profileIds.length > 0
    ? await db.from("profiles").select("id,display_name,username").in("id", profileIds)
    : { data: [], error: null };
  const profiles = new Map(
    rows(profileResult.data).map((row) => [
      String(row.id),
      String(row.display_name ?? row.username ?? "Player"),
    ]),
  );

  const result: {
    attendanceQueue?: AdminReliabilityQueueItem[];
    appealsQueue?: AdminReliabilityAppealQueueItem[];
  } = {};
  if (!attendanceResult.error) {
    result.attendanceQueue = attendanceRows.map((row) => ({
      id: String(row.id),
      title: `${profiles.get(String(row.profile_id)) ?? "Player"} · ${humanize(String(row.outcome ?? "ATTENDANCE"))}`,
      detail: [
        String(row.match_kind ?? "MATCH"),
        `${Number(row.strike_delta ?? 0)} strike${Number(row.strike_delta ?? 0) === 1 ? "" : "s"}`,
        `${Number(row.refund_bps ?? 0) / 100}% refund`,
        row.appeal_due_at ? `appeal by ${formatBahrainDateTime(row.appeal_due_at)}` : null,
      ].filter(Boolean).join(" · "),
      status: String(row.outcome ?? "FINALIZED"),
      createdAt: nullableString(row.finalized_at) ?? nullableString(row.created_at),
    }));
  }
  if (!appealResult.error && !appealAttendanceResult.error) {
    result.appealsQueue = appealRows.flatMap((row) => {
      const attendance = appealedAttendance.get(String(row.attendance_id));
      if (!attendance) return [];
      const playerName = profiles.get(String(row.appellant_profile_id)) ?? "Player";
      const category = String(row.category ?? "APPEAL");
      const message = String(row.message ?? "");
      const matchKind = String(attendance.match_kind ?? "MATCH");
      const outcome = String(attendance.outcome ?? "ATTENDANCE");
      const strikeDelta = Number(attendance.strike_delta ?? 0);
      const refundBps = Number(attendance.refund_bps ?? 0);
      const depositResolution = String(attendance.deposit_resolution ?? "NOT_REQUIRED");
      return [{
        id: String(row.id),
        attendanceId: String(row.attendance_id),
        playerName,
        category,
        message,
        matchKind,
        outcome,
        strikeDelta,
        refundBps,
        depositResolution,
        title: `${playerName} · ${humanize(category)}`,
        detail: `${truncate(message, 110)} · due ${formatBahrainDateTime(row.appeal_due_at)}`,
        status: String(row.status ?? "OPEN"),
        createdAt: nullableString(row.created_at),
      }];
    });
  }
  return result;
}

export function normalizeAdminReliabilityPolicyVersion(
  row: Row,
  actors: Map<string, string>,
): ReliabilityPolicyVersion {
  const state = String(row.state ?? "DRAFT").toUpperCase() as ReliabilityPolicyState;
  if (!(["DRAFT", "PUBLISHED"] as const).includes(state)) {
    throw new Error(`Policy ${String(row.id)} has an unsupported state.`);
  }
  const createdBy = nullableString(row.created_by);
  const publishedBy = nullableString(row.published_by);
  const config = state === "DRAFT"
    ? normalizeReliabilityPolicyDraftConfig(row.config)
    : parseReliabilityPolicyConfig(row.config, {
      allowLegacySoloSixSide: true,
      allowLegacyClanSevenSide: true,
    });
  const effectiveFrom = requiredDate(row.effective_from, "effective date");
  const createdAt = requiredDate(row.created_at, "created date");
  const updatedAt = requiredRevision(row.updated_at);
  const publishedAt = row.published_at == null
    ? null
    : requiredDate(row.published_at, "published date");

  return {
    id: String(row.id),
    version: finiteInteger(row.version, 0),
    state,
    schemaVersion: finiteInteger(row.schema_version, config.schemaVersion),
    effectiveFrom,
    config,
    summary: String(row.summary ?? "").trim(),
    createdBy,
    createdByName: createdBy ? actors.get(createdBy) ?? "Field admin" : null,
    createdAt,
    updatedAt,
    publishedBy,
    publishedByName: publishedBy ? actors.get(publishedBy) ?? "Field admin" : null,
    publishedAt,
    supersedesId: nullableString(row.supersedes_id),
  };
}

function rows(value: unknown): Row[] {
  return Array.isArray(value)
    ? value.filter((item): item is Row => Boolean(item) && typeof item === "object")
    : [];
}

function nullableString(value: unknown) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function finiteInteger(value: unknown, fallback: number) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : fallback;
}

function requiredDate(value: unknown, label: string) {
  const parsed = Date.parse(String(value ?? ""));
  if (!Number.isFinite(parsed)) throw new Error(`Reliability policy has an invalid ${label}.`);
  return new Date(parsed).toISOString();
}

function requiredRevision(value: unknown) {
  const revision = validReliabilityRevision(value);
  if (!revision) {
    throw new Error("Reliability policy has an invalid updated date.");
  }
  return revision;
}

function humanize(value: string) {
  return value.toLowerCase().replaceAll("_", " ").replace(/^./, (letter) => letter.toUpperCase());
}

function truncate(value: string, maximum: number) {
  return value.length <= maximum ? value : `${value.slice(0, maximum - 1).trimEnd()}…`;
}

function formatBahrainDateTime(value: unknown) {
  const parsed = Date.parse(String(value ?? ""));
  if (!Number.isFinite(parsed)) return "unknown";
  return new Intl.DateTimeFormat("en-BH", {
    timeZone: "Asia/Bahrain",
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(parsed));
}
