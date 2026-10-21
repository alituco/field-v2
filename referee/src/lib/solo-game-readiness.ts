export const CONFIGURABLE_PARTICIPATION_RULES = "s0-configurable-v1";

export type SoloParticipationRules = {
  minimumPlayers?: number | null;
  participationRulesVersion?: string | null;
  capacity?: number | null;
  ratingPolicyId?: string | null;
};

/** Advertised minimum and maximum are separate; reaching the minimum is not FULL. */
export function soloGameReadiness(game: SoloParticipationRules, confirmedCount: number) {
  const capacity = Number.isInteger(game.capacity) && Number(game.capacity) >= 2 ? Number(game.capacity) : 14;
  const configurable = game.participationRulesVersion === CONFIGURABLE_PARTICIPATION_RULES;
  const minimumPlayers = configurable
    ? Number.isInteger(game.minimumPlayers) && Number(game.minimumPlayers) >= 2 && Number(game.minimumPlayers) <= capacity
      ? Number(game.minimumPlayers) : capacity
    : game.ratingPolicyId === "field-sr-season0-v2" ? 10 : capacity;
  return { configurable, minimumPlayers, capacity,
    minimumReached: Number.isInteger(confirmedCount) && confirmedCount >= minimumPlayers && confirmedCount <= capacity };
}

export function soloStarterLineupReady(game: SoloParticipationRules, white: number, black: number): boolean {
  if (!Number.isInteger(white) || !Number.isInteger(black) || white < 1 || black < 1 || white > 7 || black > 7) return false;
  const rules = soloGameReadiness(game, white + black);
  if (rules.configurable) return rules.minimumReached;
  return game.ratingPolicyId !== "field-sr-season0-v2" || white >= 5 && black >= 5;
}

export function soloMinimumHint(game: SoloParticipationRules): string {
  const rules = soloGameReadiness(game, 0);
  return rules.configurable
    ? `At least ${rules.minimumPlayers} actual players total, including one on each team, are needed to start or resume. Play pauses if either requirement is lost.`
    : game.ratingPolicyId === "field-sr-season0-v2"
      ? "At least five actual players on each team are needed to start or resume. Play pauses below five on either side."
      : "Check in at least one player from each team before starting.";
}
