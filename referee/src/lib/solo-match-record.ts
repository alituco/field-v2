import type { SupabaseClient } from "@supabase/supabase-js";
import type { SeasonZeroMatchState } from "./season-zero-actions";

export type MatchRecordArrival = {
  profile_id: string;
  arrived_at: string | null;
  attendance_outcome?: string | null;
  strikes?: number;
};
export type MatchRecordState = Omit<SeasonZeroMatchState, "events" | "arrivals"> & {
  started_at: string;
  ended_at: string | null;
  white_score: number | null;
  black_score: number | null;
  can_correct_record: boolean;
  arrivals: MatchRecordArrival[];
  events: MatchRecordEvent[];
  goals: MatchRecordGoal[];
  record_revisions?: { revision: number; reason: string; recorded_at: string; actor_id: string; action: string }[];
};
export type MatchRecordEvent = {
  id: string; type: string; second: number; player_id: string | null; recorded_at: string; note?: string;
};
export type MatchRecordGoal = { id?: string; team: "WHITE" | "BLACK"; profile_id: string; assist_profile_id: string | null; second: number };
export type MatchRecordInput = {
  reason: string;
  arrivals?: { profile_id: string; arrived_at: string | null }[];
  events?: MatchRecordEvent[];
  goals?: MatchRecordGoal[];
  played_seconds?: number;
  white_score?: number;
  black_score?: number;
};
export type MatchRecordRequest = {
  expectedRevision: number;
  requestId: string;
  record: MatchRecordInput;
  preview: boolean;
  previewToken?: string;
};
export type MatchRecordImpactValue = {
  sr?: number | null; matches?: number | null; game_sr_delta?: number | null; arrived_at?: string | null; attendance_outcome?: string | null; strikes?: number | null;
};
export type MatchAttendanceImpact = {
  profile_id: string; changed: boolean;
  before?: { active_strikes: number; can_book: boolean };
  after?: { active_strikes: number; can_book: boolean };
};
export type MatchRecordResult = {
  state: MatchRecordState;
  preview: boolean;
  record_input: MatchRecordInput;
  preview_token?: string;
  impact: { attendance: MatchAttendanceImpact[]; players: { profile_id: string; display_name?: string; rating_track?: string; before: MatchRecordImpactValue; after: MatchRecordImpactValue }[]; dependent_players_changed?: number; dependent_matches_changed?: number };
};
const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const eventActions = new Set([ "EXCUSED_LEAVE", "RETURN", "QUIT", "RED_CARD", "BLUE_CARD", "BLUE_RETURN", "PAUSE", "RESUME"]);

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function whole(value: unknown, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= max;
}
function timestamp(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(value) && Number.isFinite(Date.parse(value));
}

/** Validate the fields the editor actually renders before accepting a server response. */
export function assertMatchRecordState(value: unknown, gameId: string): asserts value is MatchRecordState {
  if (!object(value) || value.game_id !== gameId || !whole(value.revision, Number.MAX_SAFE_INTEGER) || value.revision < 1 ||
      !["LIVE", "FINAL", "REVIEW"].includes(String(value.lifecycle)) || !timestamp(value.started_at) ||
      (value.ended_at !== null && !timestamp(value.ended_at)) || typeof value.can_correct_record !== "boolean" ||
      !whole(value.elapsed_seconds, 10800) || (value.white_score !== null && !whole(value.white_score, 999)) ||
      (value.black_score !== null && !whole(value.black_score, 999)) ||
      !Array.isArray(value.observed_roster) || value.observed_roster.some(player => !object(player) || typeof player.id !== "string" || !uuid.test(player.id) ||
        !["A", "B"].includes(String(player.team)) || typeof player.booked_role !== "string") ||
      !Array.isArray(value.arrivals) || value.arrivals.some(arrival => !object(arrival) || typeof arrival.profile_id !== "string" || !uuid.test(arrival.profile_id) ||
        (arrival.arrived_at !== null && !timestamp(arrival.arrived_at))) ||
      !Array.isArray(value.events) || value.events.some(event => !object(event) || typeof event.id !== "string" || !event.id ||
        typeof event.type !== "string" || ![...eventActions, "JOIN"].includes(event.type) || !whole(event.second, 10800) ||
        (event.player_id !== null && (typeof event.player_id !== "string" || !uuid.test(event.player_id))) || !timestamp(event.recorded_at)) ||
      !Array.isArray(value.goals) || value.goals.some(goal => !object(goal) || typeof goal.id !== "string" || !uuid.test(goal.id) ||
        !["WHITE", "BLACK"].includes(String(goal.team)) || typeof goal.profile_id !== "string" || !uuid.test(goal.profile_id) ||
        (goal.assist_profile_id !== null && (typeof goal.assist_profile_id !== "string" || !uuid.test(goal.assist_profile_id))) || !whole(goal.second, 10800)) ||
      (value.record_revisions !== undefined && (!Array.isArray(value.record_revisions) || value.record_revisions.some(revision =>
        !object(revision) || !whole(revision.revision, Number.MAX_SAFE_INTEGER) || typeof revision.reason !== "string" ||
        typeof revision.actor_id !== "string" || !uuid.test(revision.actor_id) || !timestamp(revision.recorded_at)))) ) {
    throw new Error("The match record was incomplete. Refresh before recording another change.");
  }
}
function validImpact(value: unknown): boolean {
  if (!object(value)) return false;
  for (const field of ["sr", "matches", "strikes"]) if (value[field] != null && !whole(value[field], Number.MAX_SAFE_INTEGER)) return false;
  if (value.game_sr_delta != null && (typeof value.game_sr_delta !== "number" || !Number.isSafeInteger(value.game_sr_delta))) return false;
  if (value.arrived_at != null && !timestamp(value.arrived_at)) return false;
  if (value.attendance_outcome != null && typeof value.attendance_outcome !== "string") return false;
  return true;
}

/** Only match facts may cross this boundary. Actor, SR, teams and role remain server-owned. */
export function parseMatchRecordRequest(body: unknown): MatchRecordRequest {
  if (!object(body) || Object.keys(body).some(key => !["expectedRevision", "requestId", "record", "preview", "previewToken"].includes(key)) ||
      !whole(body.expectedRevision, Number.MAX_SAFE_INTEGER) || body.expectedRevision < 1 ||
      typeof body.requestId !== "string" || !uuid.test(body.requestId) || typeof body.preview !== "boolean" || !object(body.record)) {
    throw new Error("Refresh the match before recording this change.");
  }
  const input = body.record;
  if (Object.keys(input).some(key => !["reason", "arrivals", "events", "goals", "played_seconds", "white_score", "black_score"].includes(key)) ||
      typeof input.reason !== "string" || input.reason.length > 2000) {
    throw new Error("Provide match facts and a reason only. Player ratings cannot be edited.");
  }
  const record: MatchRecordInput = { reason: input.reason.trim() };
  if (input.arrivals !== undefined) {
    if (!Array.isArray(input.arrivals) || input.arrivals.length < 1 || input.arrivals.length > 14) throw new Error("Choose the booked players whose arrival needs recording.");
    const seen = new Set<string>();
    record.arrivals = input.arrivals.map(arrival => {
      if (!object(arrival) || Object.keys(arrival).some(key => !["profile_id", "arrived_at"].includes(key)) ||
          typeof arrival.profile_id !== "string" || !uuid.test(arrival.profile_id) || seen.has(arrival.profile_id) ||
          (arrival.arrived_at !== null && arrival.arrived_at !== "now" && !timestamp(arrival.arrived_at))) {
        throw new Error("Record one valid arrival per booked player.");
      }
      seen.add(arrival.profile_id);
      return { profile_id: arrival.profile_id, arrived_at: arrival.arrived_at as string | null };
    });
  }
  for (const key of ["played_seconds", "white_score", "black_score"] as const) {
    if (input[key] !== undefined) {
      if (!whole(input[key], key === "played_seconds" ? 10800 : 999)) throw new Error("Use valid whole-number playing times and scores.");
      record[key] = input[key];
    }
  }
  if ((record.white_score === undefined) !== (record.black_score === undefined)) throw new Error("Provide both team scores.");
  if (input.goals !== undefined) {
    if (!Array.isArray(input.goals) || input.goals.length > 200) throw new Error("Provide a valid list of goals.");
    const seen = new Set<string>();
    record.goals = input.goals.map(goal => {
      if (!object(goal) || Object.keys(goal).some(key => !["id", "team", "profile_id", "assist_profile_id", "second"].includes(key)) ||
          (goal.id !== undefined && (typeof goal.id !== "string" || !uuid.test(goal.id) || seen.has(goal.id))) ||
          !["WHITE", "BLACK"].includes(String(goal.team)) || typeof goal.profile_id !== "string" || !uuid.test(goal.profile_id) ||
          (goal.assist_profile_id !== null && (typeof goal.assist_profile_id !== "string" || !uuid.test(goal.assist_profile_id))) ||
          goal.profile_id === goal.assist_profile_id || !whole(goal.second, 10800)) {
        throw new Error("Choose valid booked scorers, assists and goal times.");
      }
      if (goal.id) seen.add(String(goal.id));
      return { ...(goal.id ? { id: String(goal.id) } : {}), team: goal.team as "WHITE" | "BLACK", profile_id: goal.profile_id,
        assist_profile_id: goal.assist_profile_id as string | null, second: goal.second };
    });
  }
  if (record.white_score !== undefined && !record.goals) throw new Error("Correct the recorded goals to change the score.");
  if (input.events !== undefined) {
    if (!Array.isArray(input.events) || input.events.length > 500) throw new Error("Provide a valid participation timeline.");
    const seen = new Set<string>();
    record.events = input.events.map(event => {
      if (!object(event) || Object.keys(event).some(key => !["id", "type", "second", "player_id", "recorded_at", "note"].includes(key)) ||
          typeof event.id !== "string" || event.id.length < 1 || event.id.length > 200 || seen.has(event.id) ||
          typeof event.type !== "string" || !eventActions.has(event.type) || !whole(event.second, 10800) ||
          !timestamp(event.recorded_at) || (event.note !== undefined && (typeof event.note !== "string" || event.note.length > 500))) {
        throw new Error("Provide valid participation events only.");
      }
      const clock = ["PAUSE", "RESUME"].includes(event.type);
      if (clock ? event.player_id !== null : typeof event.player_id !== "string" || !uuid.test(event.player_id)) {
        throw new Error("Choose the booked player for each participation event.");
      }
      seen.add(event.id);
      return { id: event.id, type: event.type, second: event.second, player_id: event.player_id as string | null,
        recorded_at: event.recorded_at, note: String(event.note ?? "").trim() };
    });
  }
  if (Object.keys(record).length < 2) throw new Error("Choose a match fact to record or correct.");
  if ((record.events !== undefined || record.goals !== undefined || record.played_seconds !== undefined || record.white_score !== undefined ||
      record.arrivals?.some(arrival => arrival.arrived_at !== "now")) && record.reason.length < 10 && !body.previewToken) {
    throw new Error("Explain the correction in at least 10 characters.");
  }
  if (body.previewToken !== undefined && (typeof body.previewToken !== "string" || body.previewToken.length > 512)) throw new Error("Review the correction again before saving.");
  return { expectedRevision: body.expectedRevision, requestId: body.requestId, preview: body.preview, record,
    ...(body.previewToken ? { previewToken: String(body.previewToken) } : {}) };
}

export function assertMatchRecordResult(value: unknown, gameId: string, preview: boolean): asserts value is MatchRecordResult {
  try {
    if (!object(value) || value.preview !== preview || !object(value.impact) || !Array.isArray(value.impact.players) ||
        value.impact.players.some(player => !object(player) || typeof player.profile_id !== "string" || !uuid.test(player.profile_id) ||
          !validImpact(player.before) || !validImpact(player.after) ||
          (player.display_name != null && typeof player.display_name !== "string") || (player.rating_track != null && typeof player.rating_track !== "string")) ||
        !Array.isArray(value.impact.attendance) || value.impact.attendance.some(attendance => !object(attendance) ||
          typeof attendance.profile_id !== "string" || !uuid.test(attendance.profile_id) || typeof attendance.changed !== "boolean" ||
          (attendance.changed && (!object(attendance.before) || !object(attendance.after) ||
            !whole(attendance.before.active_strikes, Number.MAX_SAFE_INTEGER) || !whole(attendance.after.active_strikes, Number.MAX_SAFE_INTEGER) ||
            typeof attendance.before.can_book !== "boolean" || typeof attendance.after.can_book !== "boolean"))) ||
        !object(value.record_input) || (preview && (typeof value.preview_token !== "string" || !value.preview_token || value.preview_token.length > 512))) {
      throw new Error("Incomplete acknowledgement.");
    }
    assertMatchRecordState(value.state, gameId);
  } catch {
    throw Object.assign(new Error("The change was not acknowledged. Retry the same request before making another change."), { code: "MATCH_RECORD_ACK_UNKNOWN" });
  }
}

export async function saveMatchRecord(db: SupabaseClient, actorId: string, gameId: string, body: unknown): Promise<MatchRecordResult> {
  const request = parseMatchRecordRequest(body);
  let rpcResult;
  try { rpcResult = await db.rpc("referee_save_solo_match_record", {
    actor_referee_id: actorId, game_id_to_use: gameId, request_id_to_use: request.requestId,
    expected_revision: request.expectedRevision, record_input: request.record, preview_only: request.preview,
    preview_token_to_use: request.previewToken ?? null,
  }); } catch {
    throw Object.assign(new Error("Could not confirm the match record. Retry the same save."), { code: "MATCH_RECORD_ACK_UNKNOWN" });
  }
  const { data, error } = rpcResult;
  if (error) {
    const code = /^(?:[0-9A-Z]{5}|PGRST\d+)$/.test(error.code ?? "") ? error.code : "MATCH_RECORD_ACK_UNKNOWN";
    throw Object.assign(new Error(code === "MATCH_RECORD_ACK_UNKNOWN" ? "Could not confirm the match record. Retry the same save." : error.message), { code });
  }
  assertMatchRecordResult(data, gameId, request.preview);
  return data;
}

/** This offset measures wall time, not the paused match clock. The server maps arrival to playing time. */
export function arrivalAtOffset(startedAt: string, minutes: string): string {
  if (!/^-?\d+(?:\.\d{1,2})?$/.test(minutes.trim())) throw new Error("Enter how many minutes before or after kickoff the player arrived.");
  const offset = Number(minutes);
  const start = Date.parse(startedAt);
  if (!Number.isFinite(start) || !Number.isFinite(offset) || offset < -1440 || !Number.isFinite(new Date(start + offset * 60000).getTime())) throw new Error("Enter a valid arrival relative to actual kickoff.");
  return new Date(start + Math.round(offset * 60) * 1000).toISOString();
}

export function arrivalOffset(startedAt: string, arrivedAt: string): string {
  const seconds = (Date.parse(arrivedAt) - Date.parse(startedAt)) / 1000;
  return Number.isFinite(seconds) ? String(Math.round(seconds / 60 * 100) / 100) : "";
}
