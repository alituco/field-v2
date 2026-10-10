import type { MatchResolutionType } from "./match-action-input";

const NO_SR_CHANGE_RESOLUTIONS = new Set<MatchResolutionType>([
  "FIELD_OR_VENUE_CANCELLATION",
  "MUTUAL_CANCELLATION",
  "ADMINISTRATIVE_VOID",
]);

export function hasGuaranteedNoSrChange(
  resolutionType: MatchResolutionType | "",
) {
  return resolutionType !== "" && NO_SR_CHANGE_RESOLUTIONS.has(resolutionType);
}

export function playerSrConsequenceLabel(
  resolutionType: MatchResolutionType | "",
) {
  return hasGuaranteedNoSrChange(resolutionType)
    ? "No change"
    : "Calculated per player";
}
