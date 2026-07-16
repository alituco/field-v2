export enum Sport {
  SOCCER = 'SOCCER'
}

export enum FixtureStatus {
  OPEN = 'OPEN',
  SCHEDULED = 'SCHEDULED',
  LIVE = 'LIVE',
  FINAL = 'FINAL'
}

export type Division = 5 | 4 | 3 | 2 | 1;

export interface Rank {
  division: Division;
}

export enum DayOfWeek {
  TUESDAY = 'TUESDAY',
  THURSDAY = 'THURSDAY'
}

export enum TimeSlot {
  EARLY = '7:00 PM - 8:00 PM',
  LATE = '8:30 PM - 9:30 PM'
}

export interface Player {
  id: string;
  username: string;
  name: string;
  avatar?: string;
  clanId?: string;
  position?: string;
  bio?: string;
  /** Player IDs this player follows. */
  followingIds?: string[];
  /** Player IDs following this player (their fans). */
  fanIds?: string[];
  highlights?: Highlight[];
  career?: CareerEntry[];
  /** Independent individual rating used to balance Open Queue matches. */
  playerRating?: number;
  regionRank?: number;
  region?: string;
}

/** A short video clip / reel on a player's profile. */
export interface Highlight {
  id: string;
  title: string;
  thumbnail: string;
  duration: string;
  views: number;
  clanTag?: string;
}

/** A stint at a previous (or current) team in a player's career. */
export interface CareerEntry {
  id: string;
  clanName: string;
  tag: string;
  emblem: string;
  period: string;
  apps: number;
  goals: number;
  current?: boolean;
}

export interface Clan {
  id: string;
  name: string;
  tag: string;
  sport: Sport;
  emblem?: string;
  ownerId: string;
  memberIds: string[];
  skillRating: number;
  wins: number;
  losses: number;
  regionRank?: number;
  region?: string;
}

/** Open Queue roles in the 6-a-side formation (1 GK, 2 DEF, 2 MID, 1 ATT). */
export type QueueRole = 'GK' | 'DEF' | 'MID' | 'ATT';

/** A bookable Open Queue 6-a-side game. */
export interface QueueMatch {
  id: string;
  /** Human date group heading, e.g. "TODAY", "TUE, 6 JAN". */
  dateGroup: string;
  /** Chronological sort key. */
  order: number;
  /** e.g. "6:30–7:30 PM". */
  timeLabel: string;
  /** e.g. "7:00 PM". */
  startTime: string;
  venue: string;
  price: number;
  ageLabel: string;
  confirmed: number;
  capacity: number;
  /** Open spots remaining per role across the match. */
  spots: Record<QueueRole, number>;
}

/** A player's reserved Open Queue place, persisted to localStorage. */
export interface QueueBooking {
  matchId: string;
  role: QueueRole;
  bookedAt: string;
}

export interface Scorer {
  playerId: string;
  minute: number;
  clanId: string;
  assistPlayerId?: string;
}

export interface Fixture {
  id: string;
  status: FixtureStatus;
  homeClanId: string;
  awayClanId?: string;
  venue: string;
  day: DayOfWeek;
  timeSlot: TimeSlot;
  date: string;
  homeScore?: number;
  awayScore?: number;
  winnerId?: string;
  homeSrChange?: number;
  awaySrChange?: number;
  videoUrl?: string;
  scorers?: Scorer[];
}

