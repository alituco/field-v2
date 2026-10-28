export type OpenQueueTeam = "WHITE" | "BLACK";
export type PlayerRatingTrack = "OUTFIELD" | "GOALKEEPER";

export function ratingTrackForBookedRole(role: unknown): PlayerRatingTrack {
  return String(role ?? "").toUpperCase() === "GK" ? "GOALKEEPER" : "OUTFIELD";
}

export function ratingTrackLabel(role: unknown): string {
  return ratingTrackForBookedRole(role) === "GOALKEEPER" ? "Keeper" : "Outfield";
}

export function persistedOpenQueueTeam(value: unknown): OpenQueueTeam | null {
  const team = typeof value === "string" ? value.toUpperCase() : "";
  return team === "WHITE" || team === "BLACK" ? team : null;
}

export function nullableSr(value: unknown): number | null {
  if ((typeof value !== "number" && typeof value !== "string") ||
      (typeof value === "string" && value.trim() === "")) return null;
  const rating = Number(value);
  return Number.isFinite(rating) ? rating : null;
}

export function formatPlayerSr(value: number | null): string {
  return value === null ? "—" : Math.round(value).toLocaleString("en-US");
}
