// Existing regression fixtures intentionally exercise historical Bahrain 6v6.
// Spell out every versioned field so new Phoenix 7v7 defaults cannot change them.
export const legacyOpenQueueFormat = {
  format_version: "LEGACY_6V6",
  currency: "BHD",
  timezone: "Asia/Bahrain",
  capacity: 12,
  goalkeeper_capacity: 2,
  defender_capacity: 4,
  midfielder_capacity: 4,
  attacker_capacity: 2,
} as const;
