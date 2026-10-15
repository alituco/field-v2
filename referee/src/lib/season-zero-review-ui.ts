import type { SeasonZeroMatchState } from "./season-zero-actions";

export const reviewEventLabels: Record<string, string> = {
  JOIN: "Join play", EXCUSED_LEAVE: "Injury / excused leave", RETURN: "Return from injury",
  QUIT: "Intentional abandonment", RED_CARD: "Permanent send-off", BLUE_CARD: "Blue card",
  BLUE_RETURN: "Actual blue-card return", PAUSE: "Pause clock", RESUME: "Resume clock",
};
export const resolutionLabels: Record<string, string> = {
  completed: "Completed match", forfeit_confirmed: "Confirmed conduct forfeit",
  no_contest: "No contest (rating only)", cancelled: "Cancel game (policy refunds)", unranked: "Not rated (rating only)", pending_review: "Keep under review",
};
export const resolutionExplanations: Record<string, string> = {
  completed: "Settle the verified final score and participation under the rating policy. Review payment and refund controls separately.",
  forfeit_confirmed: "Settle the verified conduct forfeit without inventing a score. Review payment and refund controls separately.",
  no_contest: "No SR or counted-match credit. This rating-only decision does not automatically refund payments or change attendance. Review payment and refund controls separately.",
  cancelled: "Cancel the game using the existing cancellation policy, including its applicable refund workflow. Review the payment and refund controls for the resulting refund status.",
  unranked: "No SR or counted-match credit. This rating-only decision does not automatically refund payments or change attendance. Review payment and refund controls separately.",
  pending_review: "Hold rating settlement while evidence is unresolved. Review payment and refund controls separately.",
};
export type ReviewEvent = { id: string; type: string; player_id: string | null; second: number; recorded_at: string; note?: string };
export type ReviewState = Omit<SeasonZeroMatchState, "events"> & {
  events: ReviewEvent[]; played_seconds?: number; winner?: "A" | "B" | null;
  adjudication_reason?: string | null;
};
export type EventDraft = { id: string; type: string; playerId: string; second: string; wallTime: string; note: string; originalRecordedAt?: string; originalWallTime?: string };
export type ReviewDraft = {
  status: string; winner: string; whiteScore: string; blackScore: string; reason: string;
  correctTimeline: boolean; playedSeconds: string; events: EventDraft[];
};

export function toEventDraft(event: ReviewEvent): EventDraft {
  const date = new Date(event.recorded_at);
  const wallTime = Number.isNaN(date.getTime()) ? "" : date.toISOString().slice(0, 19);
  return { id: event.id, type: event.type, playerId: event.player_id ?? "", second: String(event.second),
    wallTime, note: event.note ?? "", originalRecordedAt: event.recorded_at, originalWallTime: wallTime };
}

function wholeNumber(value: string, label: string, max: number) {
  if (!/^\d+$/.test(value.trim())) throw new Error(`${label} must be a whole number.`);
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result < 0 || result > max) throw new Error(`${label} must be between 0 and ${max}.`);
  return result;
}

/** Allowlisted evidence only: no client-provided SR, seeds, counters or actor. */
export function buildReviewResolution(state: ReviewState, draft: ReviewDraft) {
  if (!Object.hasOwn(resolutionLabels, draft.status)) throw new Error("Choose a rating outcome.");
  if (draft.status === "cancelled" && state.lifecycle === "FINAL") throw new Error("A finalized game cannot be cancelled here. Use the existing manual refund review for payment decisions.");
  if (draft.reason.trim().length < 10 || draft.reason.trim().length > 2000) throw new Error("Explain the correction in 10–2000 characters.");
  const resolution: Record<string, unknown> = { status: draft.status, winner: null, reason: draft.reason.trim() };
  if (draft.status === "completed") {
    const white = wholeNumber(draft.whiteScore, "White score", 999);
    const black = wholeNumber(draft.blackScore, "Black score", 999);
    Object.assign(resolution, { white_score: white, black_score: black, winner: white > black ? "A" : black > white ? "B" : null });
  } else if (draft.status === "forfeit_confirmed") {
    if (!["A", "B"].includes(draft.winner)) throw new Error("Choose the actual winning team for the forfeit.");
    resolution.winner = draft.winner;
  }
  if (draft.correctTimeline) {
    if (draft.events.length > 500) throw new Error("A corrected timeline can contain at most 500 events.");
    const played = wholeNumber(draft.playedSeconds, "Played clock seconds", 10800);
    const ids = new Set<string>();
    const players = new Set(state.observed_roster.map(player => player.id));
    let previousSecond = 0;
    let previousWall = -Infinity;
    resolution.played_seconds = played;
    resolution.events = draft.events.map((event, index) => {
      const label = `Event ${index + 1}`;
      if (!event.id || ids.has(event.id)) throw new Error(`${label} needs a unique event ID.`);
      ids.add(event.id);
      if (!Object.hasOwn(reviewEventLabels, event.type)) throw new Error(`${label} has an unsupported action.`);
      const second = wholeNumber(event.second, `${label} clock second`, played);
      const recordedAt = event.originalRecordedAt && event.wallTime === event.originalWallTime
        ? event.originalRecordedAt : `${event.wallTime}Z`;
      const wall = Date.parse(recordedAt);
      if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?$/.test(event.wallTime) || !Number.isFinite(wall)) throw new Error(`${label} needs a valid UTC wall timestamp.`);
      if (second < previousSecond || wall < previousWall) throw new Error("Keep events in chronological sequence. Use the move buttons to change their order.");
      previousSecond = second; previousWall = wall;
      const clock = ["PAUSE", "RESUME"].includes(event.type);
      if (!clock && !players.has(event.playerId)) throw new Error(`${label} must select an originally booked player.`);
      if (event.note.length > 500) throw new Error(`${label} note must be at most 500 characters.`);
      return { id: event.id, type: event.type, player_id: clock ? null : event.playerId,
        second, recorded_at: event.originalRecordedAt && event.wallTime === event.originalWallTime ? event.originalRecordedAt : new Date(wall).toISOString(), note: event.note.trim() };
    });
  }
  return resolution;
}
