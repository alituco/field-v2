export enum Sport {
  SOCCER = 'SOCCER'
}

export enum FixtureStatus {
  OPEN = 'OPEN',
  SCHEDULED = 'SCHEDULED',
  LIVE = 'LIVE',
  FINAL = 'FINAL'
}

export enum Tier {
  SILVER = 'SILVER',
  GOLD = 'GOLD',
  DIAMOND = 'DIAMOND',
  CHAMPION = 'CHAMPION'
}

export type Division = 3 | 2 | 1;

export interface Rank {
  tier: Tier;
  division?: Division;
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

export interface TierConfig {
  tier: Tier;
  minRating: number;
  maxRating: number;
  gradient: string;
  textColor: string;
  glowColor: string;
  icon: string;
}
