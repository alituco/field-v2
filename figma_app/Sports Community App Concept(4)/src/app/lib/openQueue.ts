import type { QueueRole, QueueMatch, QueueBooking } from './types';
import { formatRank, getRankFromRating } from './constants/tiers';

/* ------------------------------------------------------------------ *
 * Roles & formation
 * ------------------------------------------------------------------ */

export interface RoleMeta {
  key: QueueRole;
  label: string;
  short: string;
  /** How many of this role are on ONE team in the 6-a-side formation. */
  perTeam: number;
}

export const ROLES: RoleMeta[] = [
  { key: 'ATT', label: 'Attacker', short: 'ATT', perTeam: 1 },
  { key: 'MID', label: 'Midfielder', short: 'MID', perTeam: 2 },
  { key: 'DEF', label: 'Defender', short: 'DEF', perTeam: 2 },
  { key: 'GK', label: 'Goalkeeper', short: 'GK', perTeam: 1 },
];

export function roleLabel(role: QueueRole): string {
  return ROLES.find(r => r.key === role)?.label ?? role;
}

/* ------------------------------------------------------------------ *
 * Mock Open Queue games (chronological)
 * ------------------------------------------------------------------ */

export const MOCK_QUEUE_MATCHES: QueueMatch[] = [
  {
    id: 'oq1',
    dateGroup: 'TODAY',
    order: 1,
    timeLabel: '6:30–7:30 PM',
    startTime: '6:30 PM',
    venue: 'TFA, Saar',
    price: 3,
    ageLabel: 'Ages 16–20',
    confirmed: 10,
    capacity: 12,
    spots: { GK: 1, DEF: 2, MID: 1, ATT: 0 },
  },
  {
    id: 'oq2',
    dateGroup: 'TODAY',
    order: 2,
    timeLabel: '7:45–8:45 PM',
    startTime: '7:45 PM',
    venue: 'TFA, Saar',
    price: 3,
    ageLabel: 'Ages 18–30',
    confirmed: 12,
    capacity: 12,
    spots: { GK: 0, DEF: 0, MID: 0, ATT: 0 },
  },
  {
    id: 'oq3',
    dateGroup: 'TUE, 6 JAN',
    order: 3,
    timeLabel: '7:00–8:00 PM',
    startTime: '7:00 PM',
    venue: 'Isa Town SC',
    price: 3,
    ageLabel: 'Ages 16–24',
    confirmed: 9,
    capacity: 12,
    spots: { GK: 1, DEF: 1, MID: 1, ATT: 0 },
  },
  {
    id: 'oq4',
    dateGroup: 'THU, 8 JAN',
    order: 4,
    timeLabel: '8:30–9:30 PM',
    startTime: '8:30 PM',
    venue: 'Riffa Views',
    price: 3,
    ageLabel: 'All ages',
    confirmed: 7,
    capacity: 12,
    spots: { GK: 1, DEF: 0, MID: 0, ATT: 0 },
  },
];

export function getQueueMatch(id: string): QueueMatch | undefined {
  return MOCK_QUEUE_MATCHES.find(m => m.id === id);
}

/* ------------------------------------------------------------------ *
 * Availability logic (role → game opportunity)
 * ------------------------------------------------------------------ */

export type Availability = 'neededNow' | 'available' | 'lastSpot' | 'full';

/** Derive how a specific game looks for the player's chosen role. */
export function availabilityFor(match: QueueMatch, role: QueueRole): Availability {
  const open = match.spots[role];
  if (open <= 0) return 'full';
  // Goalkeepers are scarce, and near-full games can confirm instantly.
  if (role === 'GK' || match.confirmed >= match.capacity - 2) return 'neededNow';
  if (open === 1) return 'lastSpot';
  return 'available';
}

export const AVAILABILITY_COPY: Record<Availability, { headline: (r: QueueRole) => string; sub: string }> = {
  neededNow: {
    headline: r => `${roleLabel(r).toUpperCase()} NEEDED`,
    sub: 'Your spot can be confirmed now.',
  },
  available: {
    headline: r => `${roleLabel(r).toUpperCase()} AVAILABLE`,
    sub: 'Open spots — join now.',
  },
  lastSpot: {
    headline: r => `LAST ${roleLabel(r).toUpperCase()} SPOT`,
    sub: 'One place left for your position.',
  },
  full: {
    headline: r => `${roleLabel(r).toUpperCase()} FULL`,
    sub: 'Join the waitlist or select another role.',
  },
};

/** Aggregate spot summary for a role across all upcoming games (role buttons). */
export function roleAggregate(role: QueueRole): { total: number; label: string } {
  const total = MOCK_QUEUE_MATCHES.reduce((n, m) => n + m.spots[role], 0);
  if (total === 0) return { total, label: 'Full' };
  if (role === 'GK') return { total, label: 'Needed now' };
  return { total, label: `${total} open` };
}

/** Headline summary shown after a role is picked. */
export function roleSummary(role: QueueRole): { confirmable: number; earliest: string | null } {
  const confirmable = MOCK_QUEUE_MATCHES.filter(m => availabilityFor(m, role) !== 'full');
  const earliest = confirmable[0] ?? null;
  return {
    confirmable: confirmable.length,
    earliest: earliest ? `${earliest.dateGroup === 'TODAY' ? 'Today' : earliest.dateGroup} at ${earliest.startTime}` : null,
  };
}

/* ------------------------------------------------------------------ *
 * Two-screen matching (main + backup positions → games)
 * ------------------------------------------------------------------ */

/** Ordering: instant confirmation first, then last spots, then general availability. */
const AVAIL_RANK: Record<Availability, number> = { neededNow: 0, lastSpot: 1, available: 2, full: 3 };

export function sortByOpportunity(matches: QueueMatch[], role: QueueRole): QueueMatch[] {
  return [...matches].sort(
    (a, b) =>
      AVAIL_RANK[availabilityFor(a, role)] - AVAIL_RANK[availabilityFor(b, role)] ||
      a.order - b.order
  );
}

/** Expand backup selection ('ANY' means every role except the main one). */
export function resolveBackups(main: QueueRole, backups: (QueueRole | 'ANY')[]): QueueRole[] {
  if (backups.includes('ANY')) {
    return ROLES.map(r => r.key).filter(r => r !== main);
  }
  return backups.filter((b): b is QueueRole => b !== 'ANY' && b !== main);
}

export interface BackupMatch {
  match: QueueMatch;
  /** The best backup role this game can confirm the player as. */
  role: QueueRole;
  availability: Availability;
}

/**
 * Split the next games into primary matches (playable in the main position)
 * and unique backup matches (playable only via a backup role). A game never
 * appears in both — primary always wins.
 */
export function matchGames(main: QueueRole, backups: QueueRole[]) {
  const primary = sortByOpportunity(
    MOCK_QUEUE_MATCHES.filter(m => availabilityFor(m, main) !== 'full'),
    main
  );
  const primaryIds = new Set(primary.map(m => m.id));

  const backupMatches: BackupMatch[] = [];
  for (const match of MOCK_QUEUE_MATCHES) {
    if (primaryIds.has(match.id)) continue;
    // Pick the best backup role available for this game.
    let best: BackupMatch | null = null;
    for (const role of backups) {
      const availability = availabilityFor(match, role);
      if (availability === 'full') continue;
      if (!best || AVAIL_RANK[availability] < AVAIL_RANK[best.availability]) {
        best = { match, role, availability };
      }
    }
    if (best) backupMatches.push(best);
  }
  backupMatches.sort(
    (a, b) => AVAIL_RANK[a.availability] - AVAIL_RANK[b.availability] || a.match.order - b.match.order
  );

  return { primary, backupMatches };
}

/** For the Screen 1 availability preview (e.g. "2 need defenders"). */
export function needCount(role: QueueRole): number {
  return MOCK_QUEUE_MATCHES.filter(m => availabilityFor(m, role) !== 'full').length;
}

/* ------------------------------------------------------------------ *
 * Player Rating display — shared with the clan division ladder
 * ------------------------------------------------------------------ */

export function playerDivisionLabel(rating: number): string {
  return formatRank(getRankFromRating(rating));
}

/* ------------------------------------------------------------------ *
 * Booking store (localStorage)
 * ------------------------------------------------------------------ */

const BOOKING_KEY = 'field:oq-booking';

export function getBooking(): QueueBooking | null {
  try {
    const raw = localStorage.getItem(BOOKING_KEY);
    return raw ? (JSON.parse(raw) as QueueBooking) : null;
  } catch {
    return null;
  }
}

export function setBooking(booking: QueueBooking) {
  localStorage.setItem(BOOKING_KEY, JSON.stringify(booking));
}

export function clearBooking() {
  localStorage.removeItem(BOOKING_KEY);
}
