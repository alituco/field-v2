export const REPORT_SUBJECT_TYPES = ["PLAYER", "CLAN", "MATCH"] as const;

export const REPORT_CATEGORIES = [
  "HARASSMENT",
  "THREATS_OR_VIOLENCE",
  "DISCRIMINATION",
  "DANGEROUS_PLAY",
  "CHEATING",
  "NO_SHOW_OR_MATCH_MANIPULATION",
  "INAPPROPRIATE_CONTENT",
  "SAFETY_OR_VENUE",
  "SCORE_OR_RESULT",
  "REFEREE_ABUSE",
  "OTHER",
] as const;

export const REPORT_PRIORITIES = ["LOW", "NORMAL", "HIGH", "URGENT"] as const;

export const STOP_MODES = ["TEMPORARY", "ABANDON"] as const;

export const STOP_REASON_CODES = [
  "MEDICAL_EMERGENCY",
  "SERIOUS_INJURY",
  "FIGHTING_OR_VIOLENCE",
  "THREAT_TO_REFEREE",
  "UNSAFE_VENUE_OR_WEATHER",
  "CROWD_OR_SECURITY",
  "EQUIPMENT_OR_TECHNICAL_FAILURE",
  "INSUFFICIENT_PLAYERS",
  "TEAM_WALKOUT",
  "REFEREE_UNABLE_TO_CONTINUE",
  "OTHER",
] as const;

// Only team-attributable reasons can turn an abandonment into a provisional
// 3-0 forfeit. Venue, weather, medical, and technical incidents still use the
// ordinary neutral stoppage workflow.
export const FORFEIT_STOP_REASON_CODES = [
  "FIGHTING_OR_VIOLENCE",
  "THREAT_TO_REFEREE",
  "CROWD_OR_SECURITY",
  "INSUFFICIENT_PLAYERS",
  "TEAM_WALKOUT",
  "OTHER",
] as const;

export const FORFEIT_REVIEW_ACTIONS = ["CONFIRM", "OVERTURN"] as const;

export const CANCELLATION_REASON_CODES = [
  "WEATHER_OR_VENUE",
  "SAFETY",
  "NO_REFEREE",
  "INSUFFICIENT_PLAYERS",
  "TECHNICAL",
  "ADMIN_DECISION",
  "OTHER",
] as const;

export const SHORTHANDED_REASONS = [
  "LATE_ARRIVAL",
  "NO_SHOW",
  "INJURY",
  "OTHER",
] as const;

export const CHECK_IN_REMOVAL_REASON_CODES = [
  "WRONG_PLAYER",
  "PLAYER_NOT_PRESENT",
  "OPERATOR_ERROR",
  "OTHER",
] as const;

export const CHECK_IN_TIMINGS = [
  "EARLY",
  "LATE",
  "AFTER_KICKOFF",
] as const;

export const SOLO_RELIABILITY_SIDES = ["WHITE", "BLACK"] as const;
export const CLAN_RELIABILITY_SIDES = ["HOME", "AWAY"] as const;

export type MatchKind = "CLAN" | "SOLO";
export type ReportSubjectType = (typeof REPORT_SUBJECT_TYPES)[number];
export type ReportCategory = (typeof REPORT_CATEGORIES)[number];
export type ReportPriority = (typeof REPORT_PRIORITIES)[number];
export type StopMode = (typeof STOP_MODES)[number];
export type StopReasonCode = (typeof STOP_REASON_CODES)[number];
export type ForfeitStopReasonCode = (typeof FORFEIT_STOP_REASON_CODES)[number];
export type ForfeitReviewAction = (typeof FORFEIT_REVIEW_ACTIONS)[number];
export type ShorthandedReason = (typeof SHORTHANDED_REASONS)[number];

type InputRecord = Record<string, unknown>;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function parseRefereeReportInput(
  body: InputRecord,
  matchKind: MatchKind,
  matchId: string,
) {
  const subjectType = enumValue(
    body.subjectType,
    REPORT_SUBJECT_TYPES,
    "Choose whether you are reporting a player, clan, or match.",
  );
  const subjectId = uuidValue(body.subjectId, "Choose who or what you are reporting.");
  const category = enumValue(
    body.category,
    REPORT_CATEGORIES,
    "Choose a report reason.",
  );
  const priority = body.priority == null || body.priority === ""
    ? "HIGH"
    : enumValue(body.priority, REPORT_PRIORITIES, "Choose a valid priority.");
  const details = boundedText(
    body.details,
    "Briefly explain what happened.",
    5,
    2000,
  );

  if (subjectType === "CLAN" && matchKind === "SOLO") {
    throw new Error("A solo team is not a clan. Report the match or a player instead.");
  }
  if (subjectType === "MATCH" && subjectId !== matchId) {
    throw new Error("The reported match does not match this fixture.");
  }

  const replayOffsetSeconds = optionalInteger(
    body.replayOffsetSeconds,
    "Replay time must be between 0:00 and 180:00.",
    0,
    10_800,
  );

  return {
    subjectType,
    subjectId,
    category,
    priority,
    details,
    replayOffsetSeconds,
  };
}

export function parseMatchStoppageInput(body: InputRecord) {
  const mode = enumValue(
    body.mode,
    STOP_MODES,
    "Choose a temporary safety stop or abandon the match.",
  );
  const reasonCode = enumValue(
    body.reasonCode,
    STOP_REASON_CODES,
    "Choose why the match is being stopped.",
  );
  const note = optionalBoundedText(body.note ?? body.reason, 2000);

  if (reasonCode === "OTHER" && note.length < 10) {
    throw new Error("Add a short explanation for the safety stoppage.");
  }

  return { mode, reasonCode, note };
}

export function parseRefereeClanForfeitInput(body: InputRecord) {
  const reportedClanId = uuidValue(
    body.reportedClanId ?? body.subjectId,
    "Choose the team responsible for ending the match.",
  );
  const category = enumValue(
    body.category,
    REPORT_CATEGORIES,
    "Choose a report reason.",
  );
  const details = boundedText(
    body.details,
    "Explain why this team caused the match to be abandoned.",
    10,
    2000,
  );
  const reasonCode = enumValue(
    body.reasonCode,
    FORFEIT_STOP_REASON_CODES,
    "Choose a team-related reason for the forfeit.",
  );
  const note = optionalBoundedText(body.note ?? body.reason, 2000);
  if (reasonCode === "OTHER" && note.length < 10) {
    throw new Error("Add a short explanation for the forfeit.");
  }
  const replayOffsetSeconds = optionalInteger(
    body.replayOffsetSeconds,
    "Replay time must be between 0:00 and 180:00.",
    0,
    10_800,
  );

  return {
    reportedClanId,
    category,
    details,
    reasonCode,
    note,
    replayOffsetSeconds,
  };
}

export function parseAdminForfeitReviewInput(body: InputRecord) {
  const decisionId = uuidValue(
    body.decisionId,
    "Choose the provisional forfeit to review.",
  );
  const action = enumValue(
    body.action,
    FORFEIT_REVIEW_ACTIONS,
    "Choose whether to confirm or overturn the provisional forfeit.",
  );
  const note = boundedText(
    body.note ?? body.reason,
    "Add a clear review note.",
    10,
    2000,
  );
  return { decisionId, action, note };
}

export function parseAdminCancellationInput(body: InputRecord) {
  const reasonCode = body.reasonCode == null || body.reasonCode === ""
    ? "ADMIN_DECISION"
    : enumValue(
        body.reasonCode,
        CANCELLATION_REASON_CODES,
        "Choose a cancellation reason.",
      );
  const reason = boundedText(
    body.reason,
    "Add a clear cancellation reason.",
    5,
    1000,
  );
  return { reasonCode, reason };
}

export function parseAdminScoreOverrideInput(body: InputRecord) {
  const homeScore = requiredInteger(
    body.homeScore,
    "Home score must be between 0 and 99.",
    0,
    99,
  );
  const awayScore = requiredInteger(
    body.awayScore,
    "Away score must be between 0 and 99.",
    0,
    99,
  );
  const reason = boundedText(
    body.reason,
    "Explain why the official score is changing.",
    10,
    2000,
  );
  return { homeScore, awayScore, reason };
}

export function parseRefereeCheckInInput(body: InputRecord) {
  return {
    profileId: uuidValue(
      body.profileId,
      "Choose a player from this match to check in.",
    ),
    timing: enumValue(
      body.checkInTiming,
      CHECK_IN_TIMINGS,
      "Choose whether the player arrived early, late, or after kickoff.",
    ),
  };
}

export function parseRefereeRemoveCheckInInput(body: InputRecord) {
  const reasonCode = enumValue(
    body.reasonCode,
    CHECK_IN_REMOVAL_REASON_CODES,
    "Choose why this check-in is being removed.",
  );
  const note = optionalBoundedText(body.note ?? body.reason, 500);
  if (reasonCode === "OTHER" && note.length < 5) {
    throw new Error("Add a short note explaining this attendance correction.");
  }

  return {
    profileId: uuidValue(
      body.profileId,
      "Choose a checked-in player from this match.",
    ),
    expectedRevision: requiredInteger(
      body.expectedRevision,
      "Refresh the player list before removing this check-in.",
      0,
      10_000,
    ),
    reasonCode,
    note,
  };
}

export function parseRefereeBulkCheckInInput(body: InputRecord) {
  if (!Array.isArray(body.profileIds)) {
    throw new Error("Choose at least one player from this match to check in.");
  }
  const profileIds = [
    ...new Set(
      body.profileIds.map((profileId) =>
        uuidValue(profileId, "Every check-in must belong to a valid player."),
      ),
    ),
  ];
  if (profileIds.length === 0 || profileIds.length > 50) {
    throw new Error("Choose between 1 and 50 players to check in.");
  }
  return { profileIds };
}

export function parseRefereeVerifiedInjuryInput(body: InputRecord) {
  return {
    profileId: uuidValue(
      body.profileId,
      "Choose a checked-in player from this match.",
    ),
    unableToContinue: booleanValue(
      body.unableToContinue,
      "Confirm whether the player was unable to continue.",
    ),
    replacementAvailable: booleanValue(
      body.replacementAvailable,
      "Confirm whether a replacement was available.",
    ),
    matchContinued: booleanValue(
      body.matchContinued,
      "Confirm whether the match continued.",
    ),
    note: optionalBoundedText(body.note, 1000),
  };
}

export function parseRefereeStartShorthandedInput(
  body: InputRecord,
  matchKind: MatchKind,
) {
  const allowedSides = matchKind === "SOLO"
    ? SOLO_RELIABILITY_SIDES
    : CLAN_RELIABILITY_SIDES;
  const side = enumValue(
    body.side,
    allowedSides,
    "Choose a team from this match.",
  );
  const reason = enumValue(
    body.reason,
    SHORTHANDED_REASONS,
    "Choose why this team is playing short.",
  );
  const note = optionalBoundedText(body.note, 1000);
  if (reason === "OTHER" && note.length < 5) {
    throw new Error("Add a concise factual note for the other reason.");
  }

  return {
    side,
    reason,
    causedByProfileId: optionalUuidValue(
      body.causedByProfileId,
      "Choose a player from this team or leave it blank.",
    ),
    note,
  };
}

export function parseRefereeEndShorthandedInput(body: InputRecord) {
  return {
    periodId: uuidValue(
      body.periodId,
      "Choose an active shorthanded period.",
    ),
    replacementProfileId: optionalUuidValue(
      body.replacementProfileId,
      "Choose a replacement from this match or leave it blank.",
    ),
    note: optionalBoundedText(body.note, 1000),
  };
}

function enumValue<const T extends readonly string[]>(
  value: unknown,
  allowed: T,
  message: string,
): T[number] {
  const normalized = String(value ?? "").trim().toUpperCase();
  if (!allowed.includes(normalized)) throw new Error(message);
  return normalized as T[number];
}

function uuidValue(value: unknown, message: string) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (!UUID_PATTERN.test(normalized)) throw new Error(message);
  return normalized;
}

function optionalUuidValue(value: unknown, message: string) {
  if (value == null || String(value).trim() === "") return null;
  return uuidValue(value, message);
}

function booleanValue(value: unknown, message: string) {
  if (typeof value !== "boolean") throw new Error(message);
  return value;
}

function boundedText(
  value: unknown,
  message: string,
  minimumLength: number,
  maximumLength: number,
) {
  const normalized = String(value ?? "").trim();
  if (
    normalized.length < minimumLength ||
    normalized.length > maximumLength
  ) {
    throw new Error(message);
  }
  return normalized;
}

function optionalBoundedText(value: unknown, maximumLength: number) {
  const normalized = String(value ?? "").trim();
  if (normalized.length > maximumLength) {
    throw new Error(`Notes must be ${maximumLength.toLocaleString()} characters or fewer.`);
  }
  return normalized;
}

function optionalInteger(
  value: unknown,
  message: string,
  minimum: number,
  maximum: number,
) {
  if (value == null || value === "") return null;
  return requiredInteger(value, message, minimum, maximum);
}

function requiredInteger(
  value: unknown,
  message: string,
  minimum: number,
  maximum: number,
) {
  const number = typeof value === "number" ? value : Number(value);
  if (!Number.isInteger(number) || number < minimum || number > maximum) {
    throw new Error(message);
  }
  return number;
}
