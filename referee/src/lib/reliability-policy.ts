export const RELIABILITY_POLICY_SCHEMA_VERSION = 1;
export const RELIABILITY_POLICY_TIME_ZONE = "Asia/Bahrain";

export const RELIABILITY_APPEAL_CATEGORIES = [
  "FIELD_OR_VENUE_ERROR",
  "VENUE_ACCESS_BLOCKED",
  "VERIFIED_MEDICAL_EMERGENCY",
  "SERIOUS_ACCIDENT_OR_EMERGENCY",
  "WRONG_PLAYER_CHECKED_IN",
  "APP_OR_OPERATOR_ERROR",
  "OTHER",
] as const;

export const RELIABILITY_FORFEIT_OUTCOMES = [
  "LATE",
  "CANCELLED_LATE",
  "CANCELLED_VERY_LATE",
  "NO_SHOW",
] as const;

export const RELIABILITY_CLAN_DEPOSIT_FORFEIT_OUTCOMES = [
  "PARTIAL_LATE",
  "FORFEIT",
  "ENTIRE_CLAN_NO_SHOW",
  "CANCELLED_EARLY",
  "CANCELLED_LATE",
  "CANCELLED_VERY_LATE",
  "NO_SHOW",
] as const;

export const RELIABILITY_REPLACEMENT_ORDER = [
  "EMERGENCY_NOTIFICATION",
  "ON_FIELD_RESERVE",
  "PLAY_SHORTHANDED",
] as const;

export type ReliabilityAppealCategory =
  (typeof RELIABILITY_APPEAL_CATEGORIES)[number];
export type ReliabilityForfeitOutcome =
  (typeof RELIABILITY_FORFEIT_OUTCOMES)[number];
export type ReliabilityClanDepositForfeitOutcome =
  (typeof RELIABILITY_CLAN_DEPOSIT_FORFEIT_OUTCOMES)[number];
export type ReliabilityReplacementStep =
  (typeof RELIABILITY_REPLACEMENT_ORDER)[number];

export type ReliabilityOutcomeRule = {
  strikes: number;
  refundBps: number;
};

export type ReliabilitySoloCancellationRule = ReliabilityOutcomeRule & {
  minimumHoursBeforeKickoff?: number;
  advertise?: boolean;
  discountBps?: number;
  notify?: boolean;
};

export type ReliabilitySanctionKind =
  | "WARNING"
  | "BOOKING_RESTRICTION"
  | "PARTICIPATION_SUSPENSION"
  | "INDEFINITE_SUSPENSION";

export type ReliabilityPolicyConfig = {
  schemaVersion: 1;
  timezone: "Asia/Bahrain";
  attendance: {
    checkInOpenLeadMinutes: number;
    checkInLeadMinutes: number;
    noShowGraceMinutes: number;
    strikeLifetimeDays: number;
    appealWindowHours: number;
    hostCheckInRequired: boolean;
    cancellationAfterKickoffOutcome: "NO_SHOW";
  };
  solo: {
    playersPerSide: number;
    cancellations: {
      early: Required<ReliabilitySoloCancellationRule>;
      late: Required<ReliabilitySoloCancellationRule>;
      veryLate: Omit<Required<ReliabilitySoloCancellationRule>, "minimumHoursBeforeKickoff">;
      afterKickoff: ReliabilityOutcomeRule;
    };
    outcomes: {
      onTime: ReliabilityOutcomeRule;
      late: ReliabilityOutcomeRule;
      noShow: ReliabilityOutcomeRule;
      fieldCancelled: ReliabilityOutcomeRule;
    };
    reliabilityDeposit: {
      activeStrikeThreshold: number;
      depositBps: number;
      onTimeReturnDestination: "FIELD_WALLET";
      forfeitOutcomes: ReliabilityForfeitOutcome[];
    };
    sanctions: Array<{
      threshold: number;
      kind: ReliabilitySanctionKind;
      durationDays: number | null;
      releaseFutureBookings: boolean;
    }>;
    highestCrossedOnly: boolean;
    releaseFutureBookingsRefundBps: number;
    teamAssignmentLeadMinutes: number;
    partyLockLeadMinutes: number;
  };
  replacement: {
    lateCancellationDiscountBps: number;
    notifyEligiblePlayersOnLateCancellation: boolean;
    postCheckInDeadlineMarketplaceEnabled: boolean;
    reserveActivationMinutesAfterKickoff: number;
    originalPlayerReclaimUntilMinutesAfterKickoff: number;
    order: ReliabilityReplacementStep[];
    maxPartySize: number;
  };
  sr: {
    latePositiveMultiplierBps: number;
    lateNegativeMultiplierBps: number;
    shorthandedQualifyingActualMinutes: number;
    protectedLosingOnTimeMultiplierBps: number;
    protectedWinnerMultiplierBps: number;
    disadvantagedWinnerMultiplierBps: number;
    latePlayerGetsTeamProtection: boolean;
  };
  injury: {
    strikeDelta: number;
    requiresRefereeVerification: boolean;
    halfMatchThresholdBps: number;
    completedLossMultiplierBps: number;
    incompleteLosingMultiplierBps: number;
    incompleteWinningMultiplierBps: number;
    incompleteRefundBps: number;
  };
  clan: {
    playersPerSide: number;
    minimumOnTimeWithoutClanStrike: number;
    minimumAtKickoffWithoutForfeit: number;
    partialAttendanceStrikes: number;
    forfeitStrikes: number;
    entireClanNoShowStrikes: number;
    forfeitScore: number;
    cancellations: {
      early: ReliabilityOutcomeRule & { minimumHoursBeforeKickoff: number };
      late: ReliabilityOutcomeRule & { minimumHoursBeforeKickoff: number };
      veryLate: ReliabilityOutcomeRule;
      afterKickoff: ReliabilityOutcomeRule & { forfeit: boolean };
    };
    reliabilityDeposit: {
      activeStrikeThreshold: number;
      depositBps: number;
      forfeitOutcomes: ReliabilityClanDepositForfeitOutcome[];
    };
    sanctions: Array<{
      threshold: number;
      kind: ReliabilitySanctionKind;
      durationDays: number | null;
    }>;
  };
  appeals: {
    allowedCategories: ReliabilityAppealCategory[];
    routineTrafficAutomaticallyExcused: boolean;
  };
  wallet: {
    refundDestination: "FIELD_WALLET";
    currency: "BHD";
  };
};

export type ReliabilityPolicyState = "DRAFT" | "PUBLISHED";

export type ReliabilityPolicyVersion = {
  id: string;
  version: number;
  state: ReliabilityPolicyState;
  schemaVersion: number;
  effectiveFrom: string;
  config: ReliabilityPolicyConfig;
  summary: string;
  createdBy: string | null;
  createdByName: string | null;
  createdAt: string;
  updatedAt: string;
  publishedBy: string | null;
  publishedByName: string | null;
  publishedAt: string | null;
  supersedesId: string | null;
};

export type ReliabilityPolicyValidationIssue = {
  path: string;
  message: string;
};

export type ReliabilityPolicyDiff = {
  path: string;
  label: string;
  before: string;
  after: string;
};

export const reliabilityPolicyDefaults: ReliabilityPolicyConfig = {
  schemaVersion: 1,
  timezone: "Asia/Bahrain",
  attendance: {
    checkInOpenLeadMinutes: 120,
    checkInLeadMinutes: 15,
    noShowGraceMinutes: 10,
    strikeLifetimeDays: 90,
    appealWindowHours: 48,
    hostCheckInRequired: true,
    cancellationAfterKickoffOutcome: "NO_SHOW",
  },
  solo: {
    playersPerSide: 6,
    cancellations: {
      early: {
        minimumHoursBeforeKickoff: 24,
        strikes: 0,
        refundBps: 10_000,
        advertise: false,
        discountBps: 0,
        notify: false,
      },
      late: {
        minimumHoursBeforeKickoff: 10,
        strikes: 1,
        refundBps: 5_000,
        advertise: true,
        discountBps: 5_000,
        notify: true,
      },
      veryLate: {
        strikes: 1,
        refundBps: 0,
        advertise: false,
        discountBps: 0,
        notify: false,
      },
      afterKickoff: { strikes: 2, refundBps: 0 },
    },
    outcomes: {
      onTime: { strikes: 0, refundBps: 0 },
      late: { strikes: 1, refundBps: 0 },
      noShow: { strikes: 2, refundBps: 0 },
      fieldCancelled: { strikes: 0, refundBps: 10_000 },
    },
    reliabilityDeposit: {
      activeStrikeThreshold: 2,
      depositBps: 2_000,
      onTimeReturnDestination: "FIELD_WALLET",
      forfeitOutcomes: [
        "LATE",
        "CANCELLED_LATE",
        "CANCELLED_VERY_LATE",
        "NO_SHOW",
      ],
    },
    sanctions: [
      { threshold: 1, kind: "WARNING", durationDays: 0, releaseFutureBookings: false },
      { threshold: 3, kind: "BOOKING_RESTRICTION", durationDays: 7, releaseFutureBookings: false },
      { threshold: 4, kind: "BOOKING_RESTRICTION", durationDays: 14, releaseFutureBookings: false },
      { threshold: 5, kind: "PARTICIPATION_SUSPENSION", durationDays: 30, releaseFutureBookings: true },
      { threshold: 6, kind: "INDEFINITE_SUSPENSION", durationDays: null, releaseFutureBookings: true },
    ],
    highestCrossedOnly: true,
    releaseFutureBookingsRefundBps: 10_000,
    teamAssignmentLeadMinutes: 180,
    partyLockLeadMinutes: 180,
  },
  replacement: {
    lateCancellationDiscountBps: 5_000,
    notifyEligiblePlayersOnLateCancellation: true,
    postCheckInDeadlineMarketplaceEnabled: false,
    reserveActivationMinutesAfterKickoff: 10,
    originalPlayerReclaimUntilMinutesAfterKickoff: 10,
    order: ["EMERGENCY_NOTIFICATION", "ON_FIELD_RESERVE", "PLAY_SHORTHANDED"],
    maxPartySize: 4,
  },
  sr: {
    latePositiveMultiplierBps: 8_000,
    lateNegativeMultiplierBps: 12_000,
    shorthandedQualifyingActualMinutes: 10,
    protectedLosingOnTimeMultiplierBps: 0,
    protectedWinnerMultiplierBps: 8_000,
    disadvantagedWinnerMultiplierBps: 10_000,
    latePlayerGetsTeamProtection: false,
  },
  injury: {
    strikeDelta: 0,
    requiresRefereeVerification: true,
    halfMatchThresholdBps: 5_000,
    completedLossMultiplierBps: 8_000,
    incompleteLosingMultiplierBps: 0,
    incompleteWinningMultiplierBps: 10_000,
    incompleteRefundBps: 10_000,
  },
  clan: {
    playersPerSide: 7,
    minimumOnTimeWithoutClanStrike: 6,
    minimumAtKickoffWithoutForfeit: 6,
    partialAttendanceStrikes: 1,
    forfeitStrikes: 2,
    entireClanNoShowStrikes: 2,
    forfeitScore: 3,
    cancellations: {
      early: { minimumHoursBeforeKickoff: 24, strikes: 0, refundBps: 10_000 },
      late: { minimumHoursBeforeKickoff: 10, strikes: 1, refundBps: 5_000 },
      veryLate: { strikes: 2, refundBps: 0 },
      afterKickoff: { strikes: 2, refundBps: 0, forfeit: true },
    },
    reliabilityDeposit: {
      activeStrikeThreshold: 2,
      depositBps: 2_000,
      forfeitOutcomes: [
        "PARTIAL_LATE",
        "FORFEIT",
        "ENTIRE_CLAN_NO_SHOW",
        "CANCELLED_LATE",
        "CANCELLED_VERY_LATE",
        "NO_SHOW",
      ],
    },
    sanctions: [
      { threshold: 1, kind: "WARNING", durationDays: 0 },
      { threshold: 3, kind: "BOOKING_RESTRICTION", durationDays: 14 },
      { threshold: 4, kind: "PARTICIPATION_SUSPENSION", durationDays: 30 },
      { threshold: 5, kind: "INDEFINITE_SUSPENSION", durationDays: null },
    ],
  },
  appeals: {
    allowedCategories: [...RELIABILITY_APPEAL_CATEGORIES],
    routineTrafficAutomaticallyExcused: false,
  },
  wallet: { refundDestination: "FIELD_WALLET", currency: "BHD" },
};

const FIELD_LABELS: Record<string, string> = {
  "attendance.checkInOpenLeadMinutes": "Arrival reminder time",
  "attendance.checkInLeadMinutes": "Check-in deadline",
  "attendance.noShowGraceMinutes": "No-show grace period",
  "attendance.strikeLifetimeDays": "Strike lifetime",
  "attendance.appealWindowHours": "Appeal window",
  "solo.cancellations.early.minimumHoursBeforeKickoff": "Full-refund cutoff",
  "solo.cancellations.late.minimumHoursBeforeKickoff": "Partial-refund cutoff",
  "solo.reliabilityDeposit.depositBps": "Player reliability deposit",
  "solo.teamAssignmentLeadMinutes": "Team and kit assignment lead time",
  "solo.partyLockLeadMinutes": "Party lock lead time",
  "replacement.lateCancellationDiscountBps": "Replacement discount",
  "replacement.reserveActivationMinutesAfterKickoff": "Reserve activation time",
  "replacement.originalPlayerReclaimUntilMinutesAfterKickoff": "Original player reclaim cutoff",
  "replacement.order": "Host reserve sequence",
  "sr.latePositiveMultiplierBps": "Late positive SR multiplier",
  "sr.lateNegativeMultiplierBps": "Late negative SR multiplier",
  "clan.playersPerSide": "Clan players per side",
  "clan.minimumAtKickoffWithoutForfeit": "Clan minimum at kickoff",
  "clan.reliabilityDeposit.depositBps": "Clan reliability deposit",
};

const OBJECT_KEYS: Record<string, readonly string[]> = {
  "": ["schemaVersion", "timezone", "attendance", "solo", "replacement", "sr", "injury", "clan", "appeals", "wallet"],
  attendance: ["checkInOpenLeadMinutes", "checkInLeadMinutes", "noShowGraceMinutes", "strikeLifetimeDays", "appealWindowHours", "hostCheckInRequired", "cancellationAfterKickoffOutcome"],
  solo: ["playersPerSide", "cancellations", "outcomes", "reliabilityDeposit", "sanctions", "highestCrossedOnly", "releaseFutureBookingsRefundBps", "teamAssignmentLeadMinutes", "partyLockLeadMinutes"],
  "solo.cancellations": ["early", "late", "veryLate", "afterKickoff"],
  "solo.cancellations.early": ["minimumHoursBeforeKickoff", "strikes", "refundBps", "advertise", "discountBps", "notify"],
  "solo.cancellations.late": ["minimumHoursBeforeKickoff", "strikes", "refundBps", "advertise", "discountBps", "notify"],
  "solo.cancellations.veryLate": ["strikes", "refundBps", "advertise", "discountBps", "notify"],
  "solo.cancellations.afterKickoff": ["strikes", "refundBps"],
  "solo.outcomes": ["onTime", "late", "noShow", "fieldCancelled"],
  "solo.outcomes.onTime": ["strikes", "refundBps"],
  "solo.outcomes.late": ["strikes", "refundBps"],
  "solo.outcomes.noShow": ["strikes", "refundBps"],
  "solo.outcomes.fieldCancelled": ["strikes", "refundBps"],
  "solo.reliabilityDeposit": ["activeStrikeThreshold", "depositBps", "onTimeReturnDestination", "forfeitOutcomes"],
  replacement: ["lateCancellationDiscountBps", "notifyEligiblePlayersOnLateCancellation", "postCheckInDeadlineMarketplaceEnabled", "reserveActivationMinutesAfterKickoff", "originalPlayerReclaimUntilMinutesAfterKickoff", "order", "maxPartySize"],
  sr: ["latePositiveMultiplierBps", "lateNegativeMultiplierBps", "shorthandedQualifyingActualMinutes", "protectedLosingOnTimeMultiplierBps", "protectedWinnerMultiplierBps", "disadvantagedWinnerMultiplierBps", "latePlayerGetsTeamProtection"],
  injury: ["strikeDelta", "requiresRefereeVerification", "halfMatchThresholdBps", "completedLossMultiplierBps", "incompleteLosingMultiplierBps", "incompleteWinningMultiplierBps", "incompleteRefundBps"],
  clan: ["playersPerSide", "minimumOnTimeWithoutClanStrike", "minimumAtKickoffWithoutForfeit", "partialAttendanceStrikes", "forfeitStrikes", "entireClanNoShowStrikes", "forfeitScore", "cancellations", "reliabilityDeposit", "sanctions"],
  "clan.cancellations": ["early", "late", "veryLate", "afterKickoff"],
  "clan.cancellations.early": ["minimumHoursBeforeKickoff", "strikes", "refundBps"],
  "clan.cancellations.late": ["minimumHoursBeforeKickoff", "strikes", "refundBps"],
  "clan.cancellations.veryLate": ["strikes", "refundBps"],
  "clan.cancellations.afterKickoff": ["strikes", "refundBps", "forfeit"],
  "clan.reliabilityDeposit": ["activeStrikeThreshold", "depositBps", "forfeitOutcomes"],
  appeals: ["allowedCategories", "routineTrafficAutomaticallyExcused"],
  wallet: ["refundDestination", "currency"],
};

export function cloneReliabilityPolicyConfig(
  config: ReliabilityPolicyConfig,
): ReliabilityPolicyConfig {
  return JSON.parse(JSON.stringify(config)) as ReliabilityPolicyConfig;
}

export function validateReliabilityPolicyConfig(
  value: unknown,
): ReliabilityPolicyValidationIssue[] {
  const issues: ReliabilityPolicyValidationIssue[] = [];
  if (!isRecord(value)) {
    return [{ path: "config", message: "Policy settings must be an object." }];
  }

  for (const [path, keys] of Object.entries(OBJECT_KEYS)) {
    validateObjectShape(value, path, keys, issues);
  }
  for (const path of ["solo.sanctions", "clan.sanctions"]) {
    if (!Array.isArray(valueAtPath(value, path))) {
      issues.push({ path, message: "Add at least one consequence rule." });
    }
  }
  if (issues.some((issue) => issue.message.includes("required"))) return issues;

  requireLiteral(value, "schemaVersion", 1, issues);
  requireLiteral(value, "timezone", RELIABILITY_POLICY_TIME_ZONE, issues);
  requireLiteral(value, "attendance.hostCheckInRequired", true, issues);
  requireLiteral(value, "attendance.cancellationAfterKickoffOutcome", "NO_SHOW", issues);
  requireLiteral(value, "solo.reliabilityDeposit.onTimeReturnDestination", "FIELD_WALLET", issues);
  requireLiteral(value, "solo.playersPerSide", 6, issues);
  requireLiteral(value, "clan.playersPerSide", 7, issues);
  requireLiteral(value, "solo.outcomes.fieldCancelled.strikes", 0, issues);
  requireLiteral(value, "injury.strikeDelta", 0, issues);
  requireLiteral(value, "injury.requiresRefereeVerification", true, issues);
  requireLiteral(value, "appeals.routineTrafficAutomaticallyExcused", false, issues);
  requireLiteral(value, "wallet.refundDestination", "FIELD_WALLET", issues);
  requireLiteral(value, "wallet.currency", "BHD", issues);

  for (const [path, minimum, maximum] of integerRules()) {
    requireNumber(value, path, minimum, maximum, issues, true);
  }
  for (const [path, maximum] of bpsRules()) {
    requireNumber(value, path, 0, maximum, issues, true);
  }
  for (const path of outcomeRulePaths()) {
    requireNumber(value, `${path}.strikes`, 0, 20, issues, true);
    requireNumber(value, `${path}.refundBps`, 0, 10_000, issues, true);
  }
  for (const path of booleanPaths()) requireBoolean(value, path, issues);

  validateEnumArray(
    valueAtPath(value, "solo.reliabilityDeposit.forfeitOutcomes"),
    "solo.reliabilityDeposit.forfeitOutcomes",
    RELIABILITY_FORFEIT_OUTCOMES,
    issues,
  );
  validateEnumArray(
    valueAtPath(value, "replacement.order"),
    "replacement.order",
    RELIABILITY_REPLACEMENT_ORDER,
    issues,
    true,
  );
  validateEnumArray(
    valueAtPath(value, "clan.reliabilityDeposit.forfeitOutcomes"),
    "clan.reliabilityDeposit.forfeitOutcomes",
    RELIABILITY_CLAN_DEPOSIT_FORFEIT_OUTCOMES,
    issues,
  );
  validateEnumArray(
    valueAtPath(value, "appeals.allowedCategories"),
    "appeals.allowedCategories",
    RELIABILITY_APPEAL_CATEGORIES,
    issues,
  );

  validateSanctions(valueAtPath(value, "solo.sanctions"), "solo.sanctions", true, issues);
  validateSanctions(valueAtPath(value, "clan.sanctions"), "clan.sanctions", false, issues);

  compareGreater(value, "attendance.checkInOpenLeadMinutes", "attendance.checkInLeadMinutes", "The arrival reminder must begin before the hard deadline.", issues);
  compareGreater(value, "solo.cancellations.early.minimumHoursBeforeKickoff", "solo.cancellations.late.minimumHoursBeforeKickoff", "The full-refund cutoff must be earlier than the partial-refund cutoff.", issues);
  compareGreater(value, "clan.cancellations.early.minimumHoursBeforeKickoff", "clan.cancellations.late.minimumHoursBeforeKickoff", "The clan full-refund cutoff must be earlier than the partial-refund cutoff.", issues);

  const teamAssignmentLead = numberAtPath(value, "solo.teamAssignmentLeadMinutes");
  const partyLockLead = numberAtPath(value, "solo.partyLockLeadMinutes");
  if (teamAssignmentLead !== null && partyLockLead !== null && partyLockLead < teamAssignmentLead) {
    issues.push({
      path: "solo.partyLockLeadMinutes",
      message: "Parties must lock at or before teams and kits are revealed.",
    });
  }

  if (numberAtPath(value, "solo.cancellations.late.discountBps") !==
      numberAtPath(value, "replacement.lateCancellationDiscountBps")) {
    issues.push({
      path: "solo.cancellations.late.discountBps",
      message: "The late-cancellation spot discount must match the emergency replacement discount.",
    });
  }
  if (valueAtPath(value, "solo.cancellations.late.notify") !==
      valueAtPath(value, "replacement.notifyEligiblePlayersOnLateCancellation")) {
    issues.push({
      path: "solo.cancellations.late.notify",
      message: "Late-cancellation notifications must match the replacement notification setting.",
    });
  }

  const soloPlayers = numberAtPath(value, "solo.playersPerSide");
  const maxPartySize = numberAtPath(value, "replacement.maxPartySize");
  if (soloPlayers !== null && maxPartySize !== null && maxPartySize > soloPlayers) {
    issues.push({ path: "replacement.maxPartySize", message: "A party cannot exceed one solo side." });
  }
  const clanPlayers = numberAtPath(value, "clan.playersPerSide");
  for (const path of ["clan.minimumOnTimeWithoutClanStrike", "clan.minimumAtKickoffWithoutForfeit"]) {
    const minimum = numberAtPath(value, path);
    if (clanPlayers !== null && minimum !== null && minimum > clanPlayers) {
      issues.push({ path, message: "This minimum cannot exceed the clan side size." });
    }
  }
  const reserveAt = numberAtPath(value, "replacement.reserveActivationMinutesAfterKickoff");
  const reclaimUntil = numberAtPath(value, "replacement.originalPlayerReclaimUntilMinutesAfterKickoff");
  if (reserveAt !== null && reclaimUntil !== null && reclaimUntil > reserveAt) {
    issues.push({
      path: "replacement.originalPlayerReclaimUntilMinutesAfterKickoff",
      message: "A player cannot reclaim the place after the reserve becomes final.",
    });
  }
  return issues;
}

export function parseReliabilityPolicyConfig(value: unknown): ReliabilityPolicyConfig {
  const issues = validateReliabilityPolicyConfig(value);
  if (issues.length > 0) {
    const error = new Error(issues.map((issue) => `${issue.path}: ${issue.message}`).join(" "));
    error.name = "ReliabilityPolicyValidationError";
    throw error;
  }
  return cloneReliabilityPolicyConfig(value as ReliabilityPolicyConfig);
}

export function diffReliabilityPolicyConfigs(
  before: ReliabilityPolicyConfig,
  after: ReliabilityPolicyConfig,
): ReliabilityPolicyDiff[] {
  const left = flatten(before);
  const right = flatten(after);
  return [...new Set([...Object.keys(left), ...Object.keys(right)])]
    .sort()
    .filter((path) => JSON.stringify(left[path]) !== JSON.stringify(right[path]))
    .map((path) => ({
      path,
      label: FIELD_LABELS[path] ?? humanizePath(path),
      before: formatDiffValue(left[path], path),
      after: formatDiffValue(right[path], path),
    }));
}

export function resolveReliabilityPolicyAt(
  versions: ReliabilityPolicyVersion[],
  at: string | Date,
): ReliabilityPolicyVersion | null {
  const timestamp = at instanceof Date ? at.getTime() : Date.parse(at);
  if (!Number.isFinite(timestamp)) return null;
  return versions
    .filter((version) =>
      version.state === "PUBLISHED" && Date.parse(version.effectiveFrom) <= timestamp)
    .sort((left, right) =>
      Date.parse(right.effectiveFrom) - Date.parse(left.effectiveFrom) ||
      right.version - left.version)
    [0] ?? null;
}

export function reliabilityTimelineForKickoff(
  config: ReliabilityPolicyConfig,
  kickoff: string | Date,
) {
  const kickoffDate = kickoff instanceof Date ? new Date(kickoff) : new Date(kickoff);
  if (!Number.isFinite(kickoffDate.getTime())) throw new Error("Choose a valid kickoff time.");
  return {
    checkInOpensAt: new Date(
      kickoffDate.getTime() - config.attendance.checkInOpenLeadMinutes * 60_000,
    ),
    checkInDeadline: new Date(
      kickoffDate.getTime() - config.attendance.checkInLeadMinutes * 60_000,
    ),
    kickoff: kickoffDate,
    noShowCutoff: new Date(
      kickoffDate.getTime() + config.attendance.noShowGraceMinutes * 60_000,
    ),
  };
}

export function bpsToPercent(value: number) {
  return value / 100;
}

export function percentToBps(value: number) {
  return Math.round(value * 100);
}

function integerRules(): Array<[string, number, number]> {
  return [
    ["attendance.checkInOpenLeadMinutes", 0, 10_080],
    ["attendance.checkInLeadMinutes", 0, 1_440],
    ["attendance.noShowGraceMinutes", 0, 180],
    ["attendance.strikeLifetimeDays", 1, 3_650],
    ["attendance.appealWindowHours", 1, 720],
    ["solo.playersPerSide", 1, 20],
    ["solo.cancellations.early.minimumHoursBeforeKickoff", 0, 8_760],
    ["solo.cancellations.late.minimumHoursBeforeKickoff", 0, 8_760],
    ["solo.reliabilityDeposit.activeStrikeThreshold", 1, 20],
    ["solo.teamAssignmentLeadMinutes", 0, 10_080],
    ["solo.partyLockLeadMinutes", 0, 10_080],
    ["replacement.reserveActivationMinutesAfterKickoff", 0, 180],
    ["replacement.originalPlayerReclaimUntilMinutesAfterKickoff", 0, 180],
    ["replacement.maxPartySize", 1, 4],
    ["sr.shorthandedQualifyingActualMinutes", 0, 180],
    ["injury.strikeDelta", 0, 20],
    ["clan.playersPerSide", 1, 20],
    ["clan.minimumOnTimeWithoutClanStrike", 1, 20],
    ["clan.minimumAtKickoffWithoutForfeit", 1, 20],
    ["clan.partialAttendanceStrikes", 0, 20],
    ["clan.forfeitStrikes", 0, 20],
    ["clan.entireClanNoShowStrikes", 0, 20],
    ["clan.forfeitScore", 0, 99],
    ["clan.cancellations.early.minimumHoursBeforeKickoff", 0, 8_760],
    ["clan.cancellations.late.minimumHoursBeforeKickoff", 0, 8_760],
    ["clan.reliabilityDeposit.activeStrikeThreshold", 1, 20],
  ];
}

function bpsRules(): Array<[string, number]> {
  return [
    ["solo.cancellations.early.discountBps", 10_000],
    ["solo.cancellations.late.discountBps", 10_000],
    ["solo.cancellations.veryLate.discountBps", 10_000],
    ["solo.reliabilityDeposit.depositBps", 10_000],
    ["solo.releaseFutureBookingsRefundBps", 10_000],
    ["replacement.lateCancellationDiscountBps", 10_000],
    ["sr.latePositiveMultiplierBps", 20_000],
    ["sr.lateNegativeMultiplierBps", 20_000],
    ["sr.protectedLosingOnTimeMultiplierBps", 20_000],
    ["sr.protectedWinnerMultiplierBps", 20_000],
    ["sr.disadvantagedWinnerMultiplierBps", 20_000],
    ["injury.halfMatchThresholdBps", 10_000],
    ["injury.completedLossMultiplierBps", 20_000],
    ["injury.incompleteLosingMultiplierBps", 20_000],
    ["injury.incompleteWinningMultiplierBps", 20_000],
    ["injury.incompleteRefundBps", 10_000],
    ["clan.reliabilityDeposit.depositBps", 10_000],
  ];
}

function outcomeRulePaths() {
  return [
    "solo.cancellations.early",
    "solo.cancellations.late",
    "solo.cancellations.veryLate",
    "solo.cancellations.afterKickoff",
    "solo.outcomes.onTime",
    "solo.outcomes.late",
    "solo.outcomes.noShow",
    "solo.outcomes.fieldCancelled",
    "clan.cancellations.early",
    "clan.cancellations.late",
    "clan.cancellations.veryLate",
    "clan.cancellations.afterKickoff",
  ];
}

function booleanPaths() {
  return [
    "attendance.hostCheckInRequired",
    "solo.cancellations.early.advertise",
    "solo.cancellations.early.notify",
    "solo.cancellations.late.advertise",
    "solo.cancellations.late.notify",
    "solo.cancellations.veryLate.advertise",
    "solo.cancellations.veryLate.notify",
    "solo.highestCrossedOnly",
    "replacement.notifyEligiblePlayersOnLateCancellation",
    "replacement.postCheckInDeadlineMarketplaceEnabled",
    "sr.latePlayerGetsTeamProtection",
    "injury.requiresRefereeVerification",
    "clan.cancellations.afterKickoff.forfeit",
    "appeals.routineTrafficAutomaticallyExcused",
  ];
}

function validateObjectShape(
  root: Record<string, unknown>,
  path: string,
  expectedKeys: readonly string[],
  issues: ReliabilityPolicyValidationIssue[],
) {
  const value = path ? valueAtPath(root, path) : root;
  if (!isRecord(value)) {
    issues.push({ path: path || "config", message: "This group of settings is required." });
    return;
  }
  for (const key of expectedKeys) {
    if (!(key in value)) {
      issues.push({ path: path ? `${path}.${key}` : key, message: "This setting is required." });
    }
  }
  for (const key of Object.keys(value)) {
    if (!expectedKeys.includes(key)) {
      issues.push({ path: path ? `${path}.${key}` : key, message: "Unknown policy setting." });
    }
  }
}

function validateSanctions(
  value: unknown,
  path: string,
  includesRelease: boolean,
  issues: ReliabilityPolicyValidationIssue[],
) {
  if (!Array.isArray(value) || value.length === 0) {
    issues.push({ path, message: "Add at least one ordered consequence step." });
    return;
  }
  let previousThreshold = 0;
  const allowedKinds: ReliabilitySanctionKind[] = [
    "WARNING",
    "BOOKING_RESTRICTION",
    "PARTICIPATION_SUSPENSION",
    "INDEFINITE_SUSPENSION",
  ];
  value.forEach((item, index) => {
    const itemPath = `${path}.${index}`;
    if (!isRecord(item)) {
      issues.push({ path: itemPath, message: "This consequence rule is invalid." });
      return;
    }
    const expectedKeys = includesRelease
      ? ["threshold", "kind", "durationDays", "releaseFutureBookings"]
      : ["threshold", "kind", "durationDays"];
    const unknown = Object.keys(item).filter((key) => !expectedKeys.includes(key));
    if (unknown.length > 0 || expectedKeys.some((key) => !(key in item))) {
      issues.push({ path: itemPath, message: "This consequence rule has missing or unknown settings." });
    }
    if (!Number.isInteger(item.threshold) || Number(item.threshold) < 1 || Number(item.threshold) > 20) {
      issues.push({ path: `${itemPath}.threshold`, message: "Use a strike threshold from 1 to 20." });
    } else if (Number(item.threshold) <= previousThreshold) {
      issues.push({ path, message: "Consequence thresholds must increase in order." });
    } else previousThreshold = Number(item.threshold);
    if (!allowedKinds.includes(item.kind as ReliabilitySanctionKind)) {
      issues.push({ path: `${itemPath}.kind`, message: "Choose a supported consequence." });
    }
    if (item.kind === "WARNING") {
      if (item.durationDays !== 0) {
        issues.push({
          path: `${itemPath}.durationDays`,
          message: "Warnings keep a permanent history marker and must use 0 days.",
        });
      }
    } else if (item.kind === "INDEFINITE_SUSPENSION") {
      if (item.durationDays !== null) {
        issues.push({ path: `${itemPath}.durationDays`, message: "Indefinite review cannot have an end date." });
      }
    } else if (
      item.kind === "BOOKING_RESTRICTION" ||
      item.kind === "PARTICIPATION_SUSPENSION"
    ) {
      if (!Number.isInteger(item.durationDays) || Number(item.durationDays) < 1 || Number(item.durationDays) > 3_650) {
        issues.push({ path: `${itemPath}.durationDays`, message: "Use a duration from 1 to 3,650 days." });
      }
    }
    if (includesRelease && typeof item.releaseFutureBookings !== "boolean") {
      issues.push({ path: `${itemPath}.releaseFutureBookings`, message: "Choose whether future bookings are released." });
    }
  });
}

function validateEnumArray<T extends string>(
  value: unknown,
  path: string,
  allowed: readonly T[],
  issues: ReliabilityPolicyValidationIssue[],
  requireEveryAllowed = false,
) {
  if (!Array.isArray(value) || value.length === 0 || value.some((item) => !allowed.includes(item as T))) {
    issues.push({ path, message: "Choose supported values only." });
    return;
  }
  if (new Set(value).size !== value.length) {
    issues.push({ path, message: "Values cannot be repeated." });
  }
  if (requireEveryAllowed && value.length !== allowed.length) {
    issues.push({ path, message: "Keep each replacement step once, in the preferred order." });
  }
}

function compareGreater(
  root: Record<string, unknown>,
  greaterPath: string,
  lesserPath: string,
  message: string,
  issues: ReliabilityPolicyValidationIssue[],
) {
  const greater = numberAtPath(root, greaterPath);
  const lesser = numberAtPath(root, lesserPath);
  if (greater !== null && lesser !== null && greater <= lesser) {
    issues.push({ path: greaterPath, message });
  }
}

function requireLiteral(
  root: Record<string, unknown>,
  path: string,
  expected: unknown,
  issues: ReliabilityPolicyValidationIssue[],
) {
  if (valueAtPath(root, path) !== expected) {
    issues.push({ path, message: `This must remain ${String(expected)}.` });
  }
}

function requireBoolean(
  root: Record<string, unknown>,
  path: string,
  issues: ReliabilityPolicyValidationIssue[],
) {
  if (typeof valueAtPath(root, path) !== "boolean") {
    issues.push({ path, message: "Choose enabled or disabled." });
  }
}

function requireNumber(
  root: Record<string, unknown>,
  path: string,
  minimum: number,
  maximum: number,
  issues: ReliabilityPolicyValidationIssue[],
  integer: boolean,
) {
  const value = valueAtPath(root, path);
  if (typeof value !== "number" || !Number.isFinite(value)) {
    issues.push({ path, message: "Enter a number." });
    return;
  }
  if ((integer && !Number.isInteger(value)) || value < minimum || value > maximum) {
    issues.push({
      path,
      message: `${integer ? "Enter a whole number" : "Enter a number"} from ${minimum} to ${maximum}.`,
    });
  }
}

function numberAtPath(root: Record<string, unknown>, path: string) {
  const value = valueAtPath(root, path);
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function valueAtPath(root: Record<string, unknown>, path: string): unknown {
  return path.split(".").reduce<unknown>((current, key) =>
    isRecord(current) ? current[key] : undefined, root);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function flatten(value: unknown, prefix = "", output: Record<string, unknown> = {}) {
  if (Array.isArray(value)) {
    value.forEach((child, index) => flatten(child, `${prefix}.${index}`, output));
    if (value.length === 0) output[prefix] = [];
    return output;
  }
  if (!isRecord(value)) {
    output[prefix] = value;
    return output;
  }
  for (const [key, child] of Object.entries(value)) {
    flatten(child, prefix ? `${prefix}.${key}` : key, output);
  }
  return output;
}

function humanizePath(path: string) {
  const parts = path.split(".");
  const leaf = parts.at(-1) ?? path;
  const parent = parts.length > 1 && /^\d+$/.test(parts.at(-2) ?? "")
    ? `Consequence ${Number(parts.at(-2)) + 1} · `
    : "";
  return parent + leaf
    .replace(/Bps$/, "")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/^./, (letter) => letter.toUpperCase());
}

function formatDiffValue(value: unknown, path: string) {
  if (typeof value === "boolean") return value ? "Enabled" : "Disabled";
  if (typeof value === "number") {
    if (path.endsWith("Bps")) return `${bpsToPercent(value)}%`;
    return String(value);
  }
  if (value === undefined) return "Not set";
  if (value === null) return path.endsWith("durationDays") ? "No end date" : "None";
  return String(value).replaceAll("_", " ");
}
