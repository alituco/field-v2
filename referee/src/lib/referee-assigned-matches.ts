import type { RefereeFixture } from "./types";

type AssignedMatch = Pick<RefereeFixture,
  "id" | "matchKind" | "status" | "matchDate" | "timeSlot" | "timezone">;

/** Clan fixtures and solo games have separate identity spaces. */
export function refereeMatchKey(match: Pick<AssignedMatch, "matchKind" | "id">): string {
  return `${match.matchKind}:${match.id}`;
}

function localDay(match: AssignedMatch, now: Date): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: match.timezone || "Asia/Bahrain",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(now);
  return ["year", "month", "day"].map(type => parts.find(part => part.type === type)?.value).join("-");
}

function priority(match: AssignedMatch, now: Date): number {
  if (match.status === "LIVE") return 0;
  if (match.status === "FINAL" || match.status === "CANCELLED") return 3;
  return match.matchDate >= localDay(match, now) ? 1 : 2;
}

function scheduleKey(match: AssignedMatch): string {
  // Both the clan 24-hour slot and the solo localized 12-hour slot are used by
  // this API. String sorting would incorrectly put 4:30 PM before 9:00 AM.
  const time = match.timeSlot.match(/^(\d{1,2}):(\d{2})(?:\s*([AP]M))?/i);
  let minutes = 0;
  if (time) {
    const hour = Number(time[1]);
    const period = time[3]?.toUpperCase();
    minutes = (period ? hour % 12 + (period === "PM" ? 12 : 0) : hour) * 60 + Number(time[2]);
  }
  return `${match.matchDate}:${String(minutes).padStart(4, "0")}`;
}

/** Visibility is assignment-based; relevance changes order, never membership. */
export function sortAssignedRefereeMatches<T extends AssignedMatch>(
  matches: readonly T[], now = new Date(),
): T[] {
  return [...matches].sort((left, right) => {
    const leftPriority = priority(left, now);
    const rightPriority = priority(right, now);
    if (leftPriority !== rightPriority) return leftPriority - rightPriority;
    const schedule = scheduleKey(left).localeCompare(scheduleKey(right));
    // Live/upcoming: earliest first. Overdue/history: most recent first.
    if (schedule !== 0) return leftPriority < 2 ? schedule : -schedule;
    return refereeMatchKey(left).localeCompare(refereeMatchKey(right));
  });
}
