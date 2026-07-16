export type OpenQueueTeam = "WHITE" | "BLACK";

export function persistedOpenQueueTeam(value: unknown): OpenQueueTeam | null {
  const team = typeof value === "string" ? value.toUpperCase() : "";
  return team === "WHITE" || team === "BLACK" ? team : null;
}

export function nullableSr(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const rating = Number(value);
  return Number.isFinite(rating) && rating >= 0 ? rating : null;
}

export function formatPlayerSr(value: number | null): string {
  return value === null ? "—" : Math.round(value).toLocaleString("en-US");
}
