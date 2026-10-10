import { type Division, type Rank } from '../types';

/**
 * Field uses one clan ladder: Division 5 is the entry point and Division 1 is the top.
 * Ratings stay internal to the prototype; players only see their clan division.
 */
export const DIVISION_CONFIGS: Record<Division, { division: Division; minRating: number; maxRating: number; label: string; description: string }> = {
  5: { division: 5, minRating: 0, maxRating: 999, label: 'Division 5', description: 'Build your record' },
  4: { division: 4, minRating: 1000, maxRating: 1299, label: 'Division 4', description: 'Find your rhythm' },
  3: { division: 3, minRating: 1300, maxRating: 1599, label: 'Division 3', description: 'Establish yourself' },
  2: { division: 2, minRating: 1600, maxRating: 1799, label: 'Division 2', description: 'One step from the top' },
  1: { division: 1, minRating: 1800, maxRating: Infinity, label: 'Division 1', description: 'The top division' },
};

export function getRankFromRating(rating: number): Rank {
  if (rating >= DIVISION_CONFIGS[1].minRating) return { division: 1 };
  if (rating >= DIVISION_CONFIGS[2].minRating) return { division: 2 };
  if (rating >= DIVISION_CONFIGS[3].minRating) return { division: 3 };
  if (rating >= DIVISION_CONFIGS[4].minRating) return { division: 4 };
  return { division: 5 };
}

export function formatRank({ division }: Rank): string {
  return `Division ${division}`;
}

export function getDivisionBounds({ division }: Rank): { min: number; max: number } {
  const config = DIVISION_CONFIGS[division];
  return { min: config.minRating, max: config.maxRating };
}
