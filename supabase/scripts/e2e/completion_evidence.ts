// Verify the normal Season 0 path, not the legacy admin-only early-test bypass.
// These are independent persisted sources: participation state, match events,
// and the stopped server clock. Never infer success from the UI alone.
export function assertCompletedSeasonZeroEvidence(
  game: { id: string; startsAt: string; endsAt: string; ratingPolicy: unknown },
  rawState: unknown,
  rawEvents: unknown,
  rawClock: unknown,
): void {
  const state = record(rawState);
  const clock = record(rawClock);
  requireEvidence(
    game.ratingPolicy === "field-sr-season0-v2",
    "wrong rating policy",
  );
  requireEvidence(
    state.game_id === game.id && state.policy_id === game.ratingPolicy &&
      state.lifecycle === "FINAL" && state.rating_status === "completed" &&
      state.settlement_status === "RATED",
    "missing exact finalized, rated participation state",
  );
  const scheduledStart = timestamp(game.startsAt);
  const scheduledEnd = timestamp(game.endsAt);
  const started = timestamp(state.started_at);
  requireEvidence(
    Math.abs(started - scheduledStart) <= 24 * 60 * 60 * 1000,
    "actual kickoff is outside the permitted ±24-hour window",
  );
  const duration = (scheduledEnd - scheduledStart) / 1000;
  requireEvidence(
    Number.isInteger(duration) && duration > 0 &&
      state.scheduled_seconds === duration && integer(state.played_seconds) &&
      state.played_seconds >= duration &&
      state.elapsed_seconds === state.played_seconds,
    "the saved match duration was not completed",
  );
  requireEvidence(
    clock.game_id === game.id && clock.status === "ENDED" &&
      clock.started_at === null && clock.duration_seconds === duration &&
      clock.accumulated_seconds === state.played_seconds,
    "the stopped server clock disagrees with participation evidence",
  );
  requireEvidence(Array.isArray(rawEvents), "missing kickoff/finish events");
  const events = rawEvents.map(record);
  requireEvidence(
    events.every((event) => event.game_id === game.id),
    "event belongs to another game",
  );
  const starts = events.filter((event) => event.event_type === "MATCH_STARTED");
  const finishes = events.filter((event) => event.event_type === "MATCH_ENDED");
  requireEvidence(
    starts.length === 1 && timestamp(starts[0].occurred_at) === started,
    "missing or inconsistent permanent MATCH_STARTED event",
  );
  requireEvidence(
    finishes.length === 1 && integer(finishes[0].minute) &&
      integer(finishes[0].second) && finishes[0].second < 60 &&
      finishes[0].minute * 60 + finishes[0].second === state.played_seconds,
    "missing or inconsistent permanent MATCH_ENDED event",
  );
}

function record(value: unknown): Record<string, unknown> {
  requireEvidence(
    value !== null && typeof value === "object" && !Array.isArray(value),
    "malformed evidence object",
  );
  return value as Record<string, unknown>;
}

function timestamp(value: unknown): number {
  requireEvidence(
    typeof value === "string" && Number.isFinite(Date.parse(value)),
    "invalid evidence timestamp",
  );
  return Date.parse(value);
}

function integer(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function requireEvidence(
  condition: boolean,
  message: string,
): asserts condition {
  if (!condition) {
    throw new Error(`Season 0 E2E completion evidence: ${message}.`);
  }
}
