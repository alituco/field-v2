import { Tier, type TierConfig, type Rank, type Division } from '../types';

export const TIER_CONFIGS: Record<Tier, TierConfig> = {
  [Tier.SILVER]: {
    tier: Tier.SILVER,
    minRating: 0,
    maxRating: 899,
    gradient: 'from-slate-300 via-gray-400 to-slate-500',
    textColor: 'text-slate-600',
    glowColor: 'shadow-slate-400/50',
    icon: 'Shield'
  },
  [Tier.GOLD]: {
    tier: Tier.GOLD,
    minRating: 900,
    maxRating: 1799,
    gradient: 'from-yellow-300 via-amber-500 to-orange-600',
    textColor: 'text-amber-600',
    glowColor: 'shadow-amber-500/50',
    icon: 'ShieldCheck'
  },
  [Tier.DIAMOND]: {
    tier: Tier.DIAMOND,
    minRating: 1800,
    maxRating: 2699,
    gradient: 'from-cyan-300 via-sky-400 to-blue-600',
    textColor: 'text-sky-600',
    glowColor: 'shadow-sky-500/50',
    icon: 'ShieldPlus'
  },
  [Tier.CHAMPION]: {
    tier: Tier.CHAMPION,
    minRating: 2700,
    maxRating: Infinity,
    gradient: 'from-fuchsia-500 via-rose-500 to-amber-400',
    textColor: 'text-rose-600',
    glowColor: 'shadow-rose-500/50',
    icon: 'Crown'
  }
};

/** Tier-themed full background gradients for hero surfaces. */
export const TIER_BACKGROUNDS: Record<Tier, string> = {
  [Tier.SILVER]:
    'bg-[radial-gradient(120%_120%_at_0%_0%,#f1f5f9_0%,#94a3b8_45%,#334155_100%)]',
  [Tier.GOLD]:
    'bg-[radial-gradient(120%_120%_at_0%_0%,#fef3c7_0%,#f59e0b_45%,#7c2d12_100%)]',
  [Tier.DIAMOND]:
    'bg-[radial-gradient(120%_120%_at_0%_0%,#cffafe_0%,#0ea5e9_45%,#0c2d6b_100%)]',
  [Tier.CHAMPION]:
    'bg-[radial-gradient(120%_120%_at_0%_0%,#fde68a_0%,#ef4444_40%,#581c87_100%)]'
};

/** A division spans 1/3 of a tier's rating window. Division 3 = lowest, 1 = highest. */
export function getRankFromRating(rating: number): Rank {
  if (rating >= TIER_CONFIGS[Tier.CHAMPION].minRating) {
    return { tier: Tier.CHAMPION };
  }
  const tier =
    rating < TIER_CONFIGS[Tier.SILVER].maxRating + 1 ? Tier.SILVER :
    rating < TIER_CONFIGS[Tier.GOLD].maxRating + 1 ? Tier.GOLD :
    Tier.DIAMOND;
  const cfg = TIER_CONFIGS[tier];
  const span = (cfg.maxRating + 1 - cfg.minRating) / 3;
  const idx = Math.min(2, Math.floor((rating - cfg.minRating) / span));
  const division = (3 - idx) as Division; // idx 0 → III, 1 → II, 2 → I
  return { tier, division };
}

export function getTierFromRating(rating: number): Tier {
  return getRankFromRating(rating).tier;
}

const ROMAN: Record<Division, string> = { 3: 'III', 2: 'II', 1: 'I' };

export function formatRank({ tier, division }: Rank): string {
  const name = tier.charAt(0) + tier.slice(1).toLowerCase();
  return division ? `${name} ${ROMAN[division]}` : name;
}

/** Numeric SR bounds for a specific {tier, division} cell. */
export function getDivisionBounds({ tier, division }: Rank): { min: number; max: number } {
  const cfg = TIER_CONFIGS[tier];
  if (!division) return { min: cfg.minRating, max: cfg.maxRating };
  const span = (cfg.maxRating + 1 - cfg.minRating) / 3;
  const idx = 3 - division; // III → 0, II → 1, I → 2
  const min = Math.round(cfg.minRating + idx * span);
  const max = Math.round(cfg.minRating + (idx + 1) * span - 1);
  return { min, max };
}
