export type MatchKind = "CLAN" | "SOLO";

export type FixtureStatus =
  | "OPEN"
  | "FULL"
  | "SCHEDULED"
  | "LIVE"
  | "FINAL"
  | "CANCELLED";

export type ClockStatus = "NOT_STARTED" | "RUNNING" | "PAUSED" | "ENDED";

export type FixtureEventType =
  | "MATCH_STARTED"
  | "MATCH_PAUSED"
  | "MATCH_RESUMED"
  | "MATCH_STOPPED"
  | "MATCH_ENDED"
  | "GOAL"
  | "BLUE_CARD"
  | "BLUE_CARD_EXPIRED"
  | "CORRECTION"
  | "FORFEIT_PROVISIONAL"
  | "FORFEIT_CONFIRMED"
  | "FORFEIT_OVERTURNED";

export type BlueCardStatus = "ACTIVE" | "EXPIRED" | "CLEARED";

export type BroadcastStatus =
  | "NOT_CONFIGURED"
  | "READY"
  | "STARTING"
  | "LIVE"
  | "STOPPING"
  | "PROCESSING"
  | "REPLAY_READY"
  | "ERROR";

export type FixtureBroadcastState = {
  matchKind?: MatchKind;
  fixtureId: string;
  openQueueGameId?: string | null;
  liveInputId: string | null;
  activeVideoId: string | null;
  status: BroadcastStatus;
  hlsUrl: string | null;
  replayHlsUrl: string | null;
  streamRequestedAt: string | null;
  streamStartedAt: string | null;
  streamStoppedAt: string | null;
  recordingReadyAt: string | null;
  errorMessage: string | null;
};

export type BroadcastDeviceState = {
  deviceKey: string;
  displayName: string;
  status: "OFFLINE" | "READY" | "STREAMING" | "ERROR";
  obsConnected: boolean;
  obsStreaming: boolean;
  currentFixtureId: string | null;
  currentOpenQueueGameId?: string | null;
  lastSeenAt: string | null;
  errorMessage: string | null;
  expiresAt?: string;
  revokedAt?: string | null;
  reservationActive?: boolean;
  testCleanupPending?: boolean;
};

export type BroadcastControlResponse = {
  broadcast: FixtureBroadcastState | null;
  device: BroadcastDeviceState | null;
};

export type Clan = {
  id: string;
  name: string;
  tag: string;
  emblem: string;
  skillRating: number;
};

export type Player = {
  id: string;
  clanId: string;
  role: string;
  displayName: string;
  username: string | null;
  avatarUrl: string | null;
  ratingAtTeamAssignment: number | null;
};

export type ModerationSubjectType = "PLAYER" | "CLAN";

export type ModerationRiskLevel = "AWARE" | "ELEVATED" | "HIGH";

export type ModerationRiskSignal = {
  subjectType: ModerationSubjectType;
  subjectId: string;
  level: ModerationRiskLevel;
  /** Short, evidence-neutral labels. No allegations or reporter identities. */
  labels: string[];
  /** Excludes reports dismissed by an admin and reports marked duplicate. */
  priorReports: number;
  recentReports: number;
  distinctRecentReporters: number;
  openReports: number;
  actionedReports: number;
  priorRefereeReports: number;
  priorWarnings: number;
  activeRestriction: {
    actionType: "SUSPENSION" | "BAN";
    scope: "NONE" | "PLAY" | "ACCOUNT" | "SCHEDULING";
    endsAt: string | null;
  } | null;
  lastReportedAt: string | null;
};

export type RefereeRiskContext = {
  teams: ModerationRiskSignal[];
  players: ModerationRiskSignal[];
  /** Reminds the referee that reports are context, not a verdict. */
  guidance: string;
};

export type FixtureClock = {
  status: ClockStatus;
  startedAt: string | null;
  accumulatedSeconds: number;
  durationSeconds: number;
};

export type Goal = {
  id: string;
  fixtureId: string;
  clanId: string;
  profileId: string;
  assistProfileId: string | null;
  minute: number;
  createdAt: string;
};

export type FixtureEvent = {
  id: string;
  fixtureId: string;
  eventType: FixtureEventType;
  clanId: string | null;
  profileId: string | null;
  assistProfileId: string | null;
  blueCardId: string | null;
  minute: number;
  second: number;
  note: string;
  createdAt: string;
};

export type BlueCard = {
  id: string;
  fixtureId: string;
  clanId: string;
  profileId: string;
  startedAt: string;
  expiresAt: string;
  durationSeconds: number;
  status: BlueCardStatus;
  minute: number;
  second: number;
};

export type ReliabilityAttendanceStatus =
  | "MISSING"
  | "CHECKED_IN"
  | "ON_TIME"
  | "LATE"
  | "NO_SHOW"
  | "EXCUSED";

export type ReliabilityAttendancePlayer = {
  attendanceRecordId: string | null;
  profileId: string;
  displayName: string;
  /** Planned by the team and therefore individually liable for a no-show. */
  expectedForMatch: boolean;
  /** Server-authoritative eligibility, including the ten-player clan squad cap. */
  checkInEligible: boolean;
  teamId: string | null;
  teamName: string | null;
  side: "HOME" | "AWAY" | "WHITE" | "BLACK" | null;
  role: string | null;
  checkedInAt: string | null;
  checkInTiming: "EARLY" | "LATE" | "AFTER_KICKOFF" | null;
  outcome: string | null;
  status: ReliabilityAttendanceStatus;
  isCheckedIn: boolean;
  /** Optimistic token for check -> remove -> re-check races. */
  checkInRevision: number;
  /** Decided by the server after match/cutoff/finalization guards. */
  canRemoveCheckIn: boolean;
};

export type ReliabilityVerifiedInjury = {
  id: string;
  profileId: string;
  side: "HOME" | "AWAY" | "WHITE" | "BLACK";
  matchSecond: number;
  unableToContinue: boolean;
  replacementAvailable: boolean;
  matchContinued: boolean;
  note: string | null;
};

export type ReliabilityShorthandedPeriod = {
  id: string;
  side: "HOME" | "AWAY" | "WHITE" | "BLACK";
  reason: "LATE_ARRIVAL" | "NO_SHOW" | "INJURY" | "OTHER";
  causedByProfileId: string | null;
  replacementProfileId: string | null;
  startedMatchSecond: number;
  endedMatchSecond: number | null;
  note: string | null;
};

export type ReliabilityReplacementStep =
  | "EMERGENCY_NOTIFICATION"
  | "ON_FIELD_RESERVE"
  | "PLAY_SHORTHANDED";

export type MatchReliabilityContext = {
  serverNow: string | null;
  policyVersionId: string | null;
  kickoffAt: string | null;
  checkInDeadlineAt: string | null;
  noShowCutoffAt: string | null;
  reserveActivationMinutesAfterKickoff: number;
  reserveActivationAt: string | null;
  originalPlayerReclaimUntilMinutesAfterKickoff: number;
  originalPlayerReclaimUntilAt: string | null;
  replacementOrder: ReliabilityReplacementStep[];
  reservePlanAutomated: boolean;
  reservePlanAuthority: "FIELD_HOST" | null;
  canCheckIn: boolean;
  canFinalizeAttendance: boolean;
  attendanceFinalized: boolean;
  expectedCount: number;
  checkedInCount: number;
  onTimeCount: number;
  lateCount: number;
  missingCount: number;
  players: ReliabilityAttendancePlayer[];
  verifiedInjuries: ReliabilityVerifiedInjury[];
  openShorthandedPeriods: ReliabilityShorthandedPeriod[];
};

export type RefereeFixture = {
  /** Immutable prospective rating policy; absent on legacy fixture responses. */
  ratingPolicyId?: string;
  matchKind: MatchKind;
  id: string;
  status: FixtureStatus;
  operationalState: string | null;
  operationalStateUpdatedAt: string | null;
  venue: string;
  day: string;
  timeSlot: string;
  matchDate: string;
  /** Venue timezone snapshot; present for solo games. */
  timezone?: string;
  /** Saved solo slot length; optional for older responses and clan fixtures. */
  scheduledDurationSeconds?: number;
  cancellationCode: string | null;
  cancellationReason: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  homeScore: number | null;
  awayScore: number | null;
  whiteAverageSr: number | null;
  blackAverageSr: number | null;
  matchAverageSr: number | null;
  teamSrSpread: number | null;
  /** Solo teams stay private until the configured pre-kickoff reveal. */
  teamsAssignedAt: string | null;
  homeClan: Clan;
  awayClan: Clan;
  players: Player[];
  participantIds: string[];
  clock: FixtureClock | null;
  goals: Goal[];
  events: FixtureEvent[];
  blueCards: BlueCard[];
  riskContext: RefereeRiskContext;
  reliabilityContext: MatchReliabilityContext | null;
};

export type RefereeFixturesResponse = {
  me: {
    profileId: string;
    displayName: string;
    phone: string;
    role: "admin" | "referee";
  };
  fixtures: RefereeFixture[];
};

export type RefereeListItem = {
  profileId: string;
  displayName: string;
  phone: string;
  role: "admin" | "referee";
};

export type AssignableFixture = {
  matchKind: MatchKind;
  id: string;
  status: FixtureStatus;
  venue: string;
  matchDate: string;
  timeSlot: string;
  homeClan: Clan;
  awayClan: Clan;
  assignedRefereeId: string | null;
};

export type RefereeAssignmentsResponse = {
  referees: RefereeListItem[];
  fixtures: AssignableFixture[];
};
