import type { RefereeFixture } from "./types";

const DEFAULT_MATCH_SECONDS = 3600;
const MIN_CLOCK_SECONDS = 600;
const MAX_CLOCK_SECONDS = 10800;

/** The saved solo slot is the default, not a browser-supplied estimate. */
export function soloScheduledDurationSeconds(startsAt: unknown, endsAt: unknown): number {
  if (typeof startsAt !== "string" || typeof endsAt !== "string") {
    return DEFAULT_MATCH_SECONDS;
  }
  const seconds = Math.round((Date.parse(endsAt) - Date.parse(startsAt)) / 1000);
  return Number.isFinite(seconds) && seconds >= MIN_CLOCK_SECONDS && seconds <= MAX_CLOCK_SECONDS
    ? seconds
    : DEFAULT_MATCH_SECONDS;
}

/** Keep the existing explicit referee override contract, now up to 180 minutes. */
export function soloStartDurationSeconds(
  startsAt: unknown,
  endsAt: unknown,
  requestedSeconds?: unknown,
): number {
  if (requestedSeconds === undefined || requestedSeconds === null) {
    return soloScheduledDurationSeconds(startsAt, endsAt);
  }
  if (typeof requestedSeconds !== "number" || !Number.isFinite(requestedSeconds)) {
    throw new Error("Match duration must be a finite number of seconds.");
  }
  return Math.max(MIN_CLOCK_SECONDS, Math.min(MAX_CLOCK_SECONDS, Math.round(requestedSeconds)));
}

/** Older API responses and the unchanged clan game format retain one hour. */
export function plannedMatchDurationSeconds(
  fixture: Pick<RefereeFixture, "matchKind" | "scheduledDurationSeconds">,
): number {
  const duration = fixture.scheduledDurationSeconds;
  return fixture.matchKind === "SOLO" && typeof duration === "number" &&
      Number.isFinite(duration) && duration >= MIN_CLOCK_SECONDS && duration <= MAX_CLOCK_SECONDS
    ? duration
    : DEFAULT_MATCH_SECONDS;
}
