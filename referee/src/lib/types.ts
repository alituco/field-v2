export type FixtureStatus = "OPEN" | "SCHEDULED" | "LIVE" | "FINAL" | "CANCELLED";

export type ClockStatus = "NOT_STARTED" | "RUNNING" | "PAUSED" | "ENDED";

export type FixtureEventType =
  | "MATCH_STARTED"
  | "MATCH_PAUSED"
  | "MATCH_RESUMED"
  | "MATCH_ENDED"
  | "GOAL"
  | "BLUE_CARD"
  | "BLUE_CARD_EXPIRED"
  | "CORRECTION";

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
  fixtureId: string;
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
  lastSeenAt: string | null;
  errorMessage: string | null;
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

export type RefereeFixture = {
  id: string;
  status: FixtureStatus;
  venue: string;
  day: string;
  timeSlot: string;
  matchDate: string;
  cancellationCode: string | null;
  cancellationReason: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  homeClan: Clan;
  awayClan: Clan;
  players: Player[];
  clock: FixtureClock | null;
  goals: Goal[];
  events: FixtureEvent[];
  blueCards: BlueCard[];
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
