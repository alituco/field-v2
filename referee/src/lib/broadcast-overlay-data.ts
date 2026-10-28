export type BroadcastOverlayClock = {
  status: "NOT_STARTED" | "RUNNING" | "PAUSED" | "ENDED";
  started_at: string | null;
  accumulated_seconds: number;
  duration_seconds: number;
  updated_at: string | null;
};

export type BroadcastOverlayGoal = {
  id: string;
  createdAt: string;
  minute: number;
  scorerName: string;
  team: "HOME" | "AWAY";
};

function object(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return object(value[0]);
  return value && typeof value === "object" ? value as Record<string, unknown> : {};
}

function number(value: unknown): number | null {
  if (typeof value !== "number" && typeof value !== "string") return null;
  if (typeof value === "string" && !value.trim()) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function overlayTimestamp(value: unknown): string | null {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value)) return null;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : null;
}

export function overlayTimeZone(value: unknown): string {
  if (typeof value === "string" && value.trim()) {
    try {
      return new Intl.DateTimeFormat("en", { timeZone: value.trim() })
        .resolvedOptions().timeZone;
    } catch { /* Fall back for legacy or malformed venue snapshots. */ }
  }
  return "Asia/Bahrain";
}

export function overlayClock(value: unknown, defaultDurationSeconds = 3600): BroadcastOverlayClock {
  const clock = object(value);
  const status = String(clock.status ?? "");
  const duration = number(clock.duration_seconds);
  return {
    status: status === "RUNNING" || status === "PAUSED" || status === "ENDED" ? status : "NOT_STARTED",
    started_at: overlayTimestamp(clock.started_at),
    accumulated_seconds: Math.max(0, Math.floor(number(clock.accumulated_seconds) ?? 0)),
    duration_seconds: duration !== null && duration > 0 ? duration : defaultDurationSeconds,
    updated_at: overlayTimestamp(clock.updated_at),
  };
}

export function overlayHalftimePaused(clock: BroadcastOverlayClock, latestPause: unknown): boolean {
  if (clock.status !== "PAUSED") return false;
  const halftime = clock.duration_seconds / 2;
  if (clock.accumulated_seconds === halftime) return true;
  const pause = object(latestPause);
  if (pause.event_type !== "MATCH_PAUSED" && pause.event_type !== "PAUSE") return false;
  const pauseSeconds = (number(pause.minute) ?? -1) * 60 + (number(pause.second) ?? 0);
  return pauseSeconds === halftime ||
    (typeof pause.note === "string" && /\bhalf[\s-]?time\b/i.test(pause.note));
}

export function overlayScores({
  status,
  goals,
  sideField,
  homeSide,
  awaySide,
  homeScore,
  awayScore,
}: {
  status: unknown;
  goals: readonly unknown[];
  sideField: "team" | "clan_id";
  homeSide: unknown;
  awaySide: unknown;
  homeScore: unknown;
  awayScore: unknown;
}): { homeScore: number; awayScore: number } {
  const homeGoals = goals.filter(goal => object(goal)[sideField] === homeSide).length;
  const awayGoals = goals.filter(goal => object(goal)[sideField] === awaySide).length;
  const savedHome = number(homeScore);
  const savedAway = number(awayScore);
  const published = String(status).toUpperCase() === "FINAL";
  const validScore = (value: number | null) => value !== null && value >= 0 && Number.isInteger(value);
  return {
    homeScore: validScore(savedHome) && (published || goals.length === 0) ? savedHome! : homeGoals,
    awayScore: validScore(savedAway) && (published || goals.length === 0) ? savedAway! : awayGoals,
  };
}

/** Only actual, still-existing goal rows can announce a goal, never score edits. */
export function latestOverlayGoal(
  goals: readonly unknown[],
  sideField: "team" | "clan_id",
  homeSide: unknown,
  awaySide: unknown,
): BroadcastOverlayGoal | null {
  const candidates: BroadcastOverlayGoal[] = [];
  for (const value of goals) {
    const goal = object(value);
    const createdAt = overlayTimestamp(goal.created_at);
    const side = goal[sideField];
    if (typeof goal.id !== "string" || !goal.id.trim() || !createdAt ||
        (side !== homeSide && side !== awaySide)) continue;
    const player = object(goal.player);
    const cleanName = (name: unknown) => typeof name === "string"
      ? name.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, 80)
      : "";
    candidates.push({
      id: goal.id.trim(),
      createdAt,
      minute: Math.max(0, Math.floor(number(goal.minute) ?? 0)),
      scorerName: cleanName(player.display_name) || cleanName(player.username) || "Player",
      team: side === homeSide ? "HOME" : "AWAY",
    });
  }
  candidates.sort((left, right) => right.createdAt.localeCompare(left.createdAt) || right.id.localeCompare(left.id));
  return candidates[0] ?? null;
}
