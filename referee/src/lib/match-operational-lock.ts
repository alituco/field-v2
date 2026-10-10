const LOCKED_OPERATIONAL_STATES = new Set(["NO_DATA", "UNDER_REVIEW"]);

export function isMatchOperationallyLocked(state: unknown) {
  return LOCKED_OPERATIONAL_STATES.has(
    typeof state === "string" ? state.trim().toUpperCase() : "",
  );
}

export function canRefereePerformOperationalAction(
  state: unknown,
  action: unknown,
) {
  if (!isMatchOperationallyLocked(state)) return true;

  // Reports add evidence without changing the clock, score, lineup, or
  // reliability outcome. Every other match mutation must wait for an admin
  // resolution or correction.
  return typeof action === "string" && action.trim().toLowerCase() === "report";
}
