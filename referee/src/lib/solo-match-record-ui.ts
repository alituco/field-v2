import { arrivalAtOffset, arrivalOffset, type MatchRecordInput, type MatchRecordState } from "./solo-match-record.ts";

export const matchRecordEventLabels: Record<string, string> = {
  JOIN: "Arrival / joined play", EXCUSED_LEAVE: "Injury / excused leave", RETURN: "Return from injury",
  QUIT: "Intentional abandonment", RED_CARD: "Permanent send-off", BLUE_CARD: "Blue card",
  BLUE_RETURN: "Returned after blue card", PAUSE: "Pause clock", RESUME: "Resume clock",
};
export type ArrivalDraft = { profileId: string; change: boolean; mode: "NOW" | "AT" | "ABSENT"; minutes: string; originalAt: string | null; originalMinutes: string };
export type RecordEventDraft = { id: string; type: string; playerId: string; clock: string; wallMinutes: string; originalAt?: string; originalMinutes?: string; note: string };
export type RecordGoalDraft = { key: string; id?: string; team: "WHITE" | "BLACK"; playerId: string; assistId: string; clock: string };
export type RecordDraft = {
  profileId: string | null; reason: string; arrivals: ArrivalDraft[];
  correctGoals: boolean; goals: RecordGoalDraft[];
  correctTimeline: boolean; clock: string; events: RecordEventDraft[];
};
export function recordOutcomeLabel(value: string | null | undefined): string {
  if (!value) return "Pending";
  const labels: Record<string, string> = { ON_TIME: "On time", LATE: "Late", NO_SHOW: "No-show", OUTFIELD: "Outfield", GOALKEEPER: "Goalkeeper", GK: "Goalkeeper" };
  return labels[value] ?? value.toLowerCase().replaceAll("_", " ").replace(/^./, first => first.toUpperCase());
}
export function clockText(seconds: number) { return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`; }
export function clockSeconds(value: string, label: string): number {
  const match = /^(\d{1,3}):([0-5]\d)$/.exec(value.trim());
  if (!match) throw new Error(`${label}: use minutes:seconds, for example 30:00.`);
  const seconds = Number(match[1]) * 60 + Number(match[2]);
  if (seconds > 10800) throw new Error(`${label} must be within three hours of playing time.`);
  return seconds;
}
export function createRecordDraft(state: MatchRecordState, profileId: string | null = null): RecordDraft {
  return {
    profileId, reason: "",
    arrivals: state.observed_roster.map(player => {
      const originalAt = state.arrivals.find(arrival => arrival.profile_id === player.id)?.arrived_at ?? null;
      const minutes = originalAt ? arrivalOffset(state.started_at, originalAt) : "";
      return { profileId: player.id, change: player.id === profileId,
        mode: originalAt || state.lifecycle === "FINAL" ? "AT" : "NOW", minutes,
        originalAt, originalMinutes: minutes };
    }),
    correctGoals: false,
    goals: (state.goals ?? []).map(goal => ({ key: goal.id ?? crypto.randomUUID(), id: goal.id, team: goal.team,
      playerId: goal.profile_id, assistId: goal.assist_profile_id ?? "", clock: clockText(goal.second) })),
    correctTimeline: false, clock: clockText(state.elapsed_seconds),
    events: state.events.map(event => ({ id: event.id, type: event.type, playerId: event.player_id ?? "",
      clock: clockText(event.second), wallMinutes: arrivalOffset(state.started_at, event.recorded_at),
      originalAt: event.recorded_at, originalMinutes: arrivalOffset(state.started_at, event.recorded_at), note: event.note ?? "" })),
  };
}
function eventWallTime(state: MatchRecordState, event: RecordEventDraft): string {
  return event.originalAt && event.wallMinutes === event.originalMinutes
    ? event.originalAt : arrivalAtOffset(state.started_at, event.wallMinutes);
}

export function automaticFinishRecordEventId(state: MatchRecordState, events: RecordEventDraft[]): string | undefined {
  if (state.lifecycle !== "FINAL") return undefined;
  const ended = Date.parse(state.ended_at ?? "");
  return [...events].reverse().find(event => event.type === "PAUSE" && event.note === "Referee ended the match." &&
    Math.abs(Date.parse(event.originalAt ?? "") - ended) <= 1000)?.id;
}

/** The referee supplies one actual time. Playing seconds follow the corrected pause history. */
export function recordEventPlayingSecond(state: MatchRecordState, events: RecordEventDraft[], target: RecordEventDraft): number {
  const kickoff = Date.parse(state.started_at);
  const targetWall = Date.parse(eventWallTime(state, target));
  if (!Number.isFinite(kickoff) || !Number.isFinite(targetWall) || targetWall < kickoff) {
    throw new Error("Playing events must occur at or after actual kickoff.");
  }
  const automaticFinish = automaticFinishRecordEventId(state, events);
  const clocks = events.map((event, index) => ({ event, index }))
    .filter(row => ["PAUSE", "RESUME"].includes(row.event.type) && row.event.id !== automaticFinish)
    .map(row => ({ ...row, wall: Date.parse(eventWallTime(state, row.event)) }))
    .sort((left, right) => left.wall - right.wall || left.index - right.index);
  let anchor = kickoff;
  let elapsed = 0;
  let running = true;
  for (const { event, wall } of clocks) {
    if (!Number.isFinite(wall) || wall < kickoff) throw new Error("Clock events must occur at or after actual kickoff.");
    if (wall > targetWall) break;
    if ((event.type === "PAUSE" && !running) || (event.type === "RESUME" && running)) {
      throw new Error("Keep pause and resume events in their actual order. Each pause needs a resume before another pause.");
    }
    elapsed += running ? Math.floor((wall - anchor) / 1000) : 0;
    anchor = wall;
    running = event.type === "RESUME";
    // Equal-time pause/resume events retain their existing order. Their elapsed
    // seconds are identical; later clock transitions cannot change this event.
    if (event.id === target.id) return elapsed;
  }
  return elapsed + (running ? Math.floor((targetWall - anchor) / 1000) : 0);
}

export function recordEventClockText(state: MatchRecordState, events: RecordEventDraft[], target: RecordEventDraft): string {
  try { return clockText(recordEventPlayingSecond(state, events, target)); }
  catch { return "Enter the actual event time"; }
}

export function arrivalNeedsReason(state: MatchRecordState, draft: RecordDraft) {
  return state.lifecycle === "FINAL" || draft.correctGoals || draft.correctTimeline ||
    draft.arrivals.some(arrival => arrival.change && (arrival.mode !== "NOW" || arrival.originalAt !== null));
}
export function buildMatchRecord(state: MatchRecordState, draft: RecordDraft): MatchRecordInput {
  const reason = draft.reason.trim();
  if (reason.length > 2000 || (arrivalNeedsReason(state, draft) && reason.length < 10)) throw new Error("Explain the correction in 10–2000 characters.");
  const result: MatchRecordInput = { reason };
  const players = new Set(state.observed_roster.map(player => player.id));
  const arrivals = draft.arrivals.filter(arrival => arrival.change).map(arrival => {
    if (!players.has(arrival.profileId)) throw new Error("Choose an originally booked player.");
    const arrived_at = arrival.mode === "ABSENT" ? null : arrival.mode === "NOW" ? "now"
      : arrival.originalAt && arrival.minutes === arrival.originalMinutes ? arrival.originalAt : arrivalAtOffset(state.started_at, arrival.minutes);
    if (state.lifecycle !== "LIVE" && arrived_at === "now") throw new Error("For a finished game, record when the player actually arrived before full time.");
    return { profile_id: arrival.profileId, arrived_at };
  });
  if (arrivals.length) result.arrivals = arrivals;
  if (draft.correctGoals) {
    result.goals = draft.goals.map(goal => {
      const scorer = state.observed_roster.find(player => player.id === goal.playerId);
      const side = goal.team === "WHITE" ? "A" : "B";
      const assist = goal.assistId ? state.observed_roster.find(player => player.id === goal.assistId) : null;
      if (!scorer || scorer.team !== side || (goal.assistId && (!assist || assist.team !== side || goal.assistId === goal.playerId))) {
        throw new Error("Choose a scorer and optional different teammate for each goal.");
      }
      return { ...(goal.id ? { id: goal.id } : {}), team: goal.team, profile_id: goal.playerId,
        assist_profile_id: goal.assistId || null, second: clockSeconds(goal.clock, "Goal time") };
    });
  }
  if (draft.correctTimeline) {
    const played = state.lifecycle === "FINAL" ? clockSeconds(draft.clock, "Played time") : 10800;
    // A running clock advances while the referee edits. Let the server derive
    // its current total from actual pause history instead of sending a stale read.
    if (state.lifecycle === "FINAL") result.played_seconds = played;
    // JOIN IDs are derived server keys (request UUID + player UUID), not editable
    // event UUIDs. The backend preserves/rederives them from saved arrivals.
    const automaticFinish = automaticFinishRecordEventId(state, draft.events);
    result.events = draft.events.filter(event => event.type !== "JOIN" && event.id !== automaticFinish).map(event => {
      if (!Object.hasOwn(matchRecordEventLabels, event.type)) throw new Error("Choose a valid participation action.");
      const clock = event.type === "PAUSE" || event.type === "RESUME";
      if (!clock && !players.has(event.playerId)) throw new Error("Choose an originally booked player for each event.");
      const second = recordEventPlayingSecond(state, draft.events, event);
      if (second > played) throw new Error("An event cannot be later than the corrected played time. Check its actual time, the pauses and the total played time.");
      if (event.note.length > 500) throw new Error("Keep each event note within 500 characters.");
      return { id: event.id, type: event.type, player_id: clock ? null : event.playerId, second,
        recorded_at: eventWallTime(state, event), note: event.note.trim() };
    });
  }
  if (Object.keys(result).length === 1) throw new Error("Choose a record to correct.");
  return result;
}
