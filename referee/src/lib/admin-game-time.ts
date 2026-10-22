import type { RefereeFixture } from "./types";

export function adminGameStartTimestamp(fixture: RefereeFixture) {
  if (fixture.startsAt) {
    const absoluteStart = Date.parse(fixture.startsAt);
    if (Number.isFinite(absoluteStart)) return absoluteStart;
  }
  const dateMatch = fixture.matchDate.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  const timeMatch = fixture.timeSlot.match(/(\d{1,2}):(\d{2})\s*(AM|PM)/i);
  if (dateMatch && timeMatch) {
    const [, year, month, day] = dateMatch;
    const rawHour = Number(timeMatch[1]);
    const minute = Number(timeMatch[2]);
    const period = timeMatch[3].toUpperCase();
    const hour = rawHour % 12 + (period === "PM" ? 12 : 0);
    const timestamp = Date.parse(
      `${year}-${month}-${day}T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:00+03:00`,
    );
    if (Number.isFinite(timestamp)) return timestamp;
  }

  const fallback = Date.parse(`${fixture.matchDate}T12:00:00+03:00`);
  return Number.isFinite(fallback) ? fallback : 0;
}

/** Match-specific notifications use the saved venue timezone, with an explicit label. */
export function formatVenueDateTime(value: string, timezone: unknown): string {
  let zone = typeof timezone === "string" && timezone ? timezone : "Asia/Bahrain";
  try { new Intl.DateTimeFormat("en-US", { timeZone: zone }).format(); }
  catch { zone = "Asia/Bahrain"; }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "Time unavailable";
  return `${new Intl.DateTimeFormat("en-US", {
    timeZone: zone, year: "numeric", month: "short", day: "numeric",
    hour: "numeric", minute: "2-digit", timeZoneName: "short",
  }).format(date)} (${zone})`;
}
