import { MOCK_PLAYERS } from './data/mockData';
import { getSession } from './auth';
import type { Player } from './types';

/** The logged-in user maps to the first mock player for V1. */
export const CURRENT_PLAYER_ID = '1';

const FOLLOWING_KEY = 'field:following';

/**
 * The current player, with name overridden by the authenticated session so the
 * rest of the app reflects the logged-in user.
 */
export function getCurrentPlayer(): Player {
  const base = MOCK_PLAYERS.find(p => p.id === CURRENT_PLAYER_ID) ?? MOCK_PLAYERS[0];
  const session = getSession();
  return session?.name ? { ...base, name: session.name } : base;
}

/** IDs the current user follows, seeded from mock data on first run. */
export function getFollowingIds(): string[] {
  try {
    const raw = localStorage.getItem(FOLLOWING_KEY);
    if (raw) return JSON.parse(raw) as string[];
  } catch {
    /* fall through to seed */
  }
  const seed = getCurrentPlayer().followingIds ?? [];
  localStorage.setItem(FOLLOWING_KEY, JSON.stringify(seed));
  return seed;
}

export function isFollowing(id: string): boolean {
  return getFollowingIds().includes(id);
}

/** Toggle follow state for a player and return the updated list of IDs. */
export function toggleFollow(id: string): string[] {
  const current = getFollowingIds();
  const next = current.includes(id)
    ? current.filter(x => x !== id)
    : [...current, id];
  localStorage.setItem(FOLLOWING_KEY, JSON.stringify(next));
  return next;
}

/** People who follow the current user (static mock: any player listing us as a fan). */
export function getFanIds(): string[] {
  return MOCK_PLAYERS.filter(p => p.fanIds?.includes(CURRENT_PLAYER_ID)).map(p => p.id);
}
