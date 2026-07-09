export type FixtureStatus = "OPEN" | "SCHEDULED" | "LIVE" | "FINAL" | "CANCELLED";

export type ClockStatus = "NOT_STARTED" | "RUNNING" | "PAUSED" | "ENDED";

export type FixtureEventType =
  | "MATCH_STARTED"
  | "MATCH_PAUSED"
  | "MATCH_RESUMED"
  | "MATCH_ENDED"
  | "GOAL"
  | "BLUE_CARD"
  | "BLUE_CARD_EXPIRED";

export type BlueCardStatus = "ACTIVE" | "EXPIRED" | "CLEARED";

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
  homeClan: Clan;
  awayClan: Clan;
  players: Player[];
  clock: FixtureClock | null;
  goals: Goal[];
  events: FixtureEvent[];
  blueCards: BlueCard[];
};

export type RefereeFixturesResponse = {
  fixtures: RefereeFixture[];
};
