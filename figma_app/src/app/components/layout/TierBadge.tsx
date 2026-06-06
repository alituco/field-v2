import { Tier, type Division } from '@/app/lib/types';
import { motion } from 'motion/react';

interface TierBadgeProps {
  tier: Tier;
  division?: Division;
  size?: 'sm' | 'md' | 'lg' | 'xl';
  showLabel?: boolean;
  animated?: boolean;
}

const SIZE_PX: Record<NonNullable<TierBadgeProps['size']>, number> = {
  sm: 32,
  md: 56,
  lg: 84,
  xl: 120,
};

const LABEL_TEXT: Record<NonNullable<TierBadgeProps['size']>, string> = {
  sm: 'text-[10px]',
  md: 'text-xs',
  lg: 'text-sm',
  xl: 'text-base',
};

const ROMAN: Record<Division, string> = { 3: 'III', 2: 'II', 1: 'I' };

/* ---------------- Per-tier configuration ---------------- */

interface RankConfig {
  shield: [string, string, string];
  highlight: string;
  stroke: string;
  glow: string;
  crown: boolean;
  wings: boolean;
  flame: boolean;
  labelText: string;
}

const RANKS: Record<Tier, RankConfig> = {
  [Tier.SILVER]: {
    shield: ['#f8fafc', '#94a3b8', '#475569'],
    highlight: '#ffffff',
    stroke: '#1e293b',
    glow: 'drop-shadow-[0_6px_12px_rgba(148,163,184,0.55)]',
    crown: false, wings: false, flame: false,
    labelText: 'text-slate-600',
  },
  [Tier.GOLD]: {
    shield: ['#fde68a', '#f59e0b', '#92400e'],
    highlight: '#fff7c8',
    stroke: '#3a1d02',
    glow: 'drop-shadow-[0_6px_14px_rgba(245,158,11,0.6)]',
    crown: false, wings: true, flame: false,
    labelText: 'text-amber-600',
  },
  [Tier.DIAMOND]: {
    shield: ['#bae6fd', '#38bdf8', '#0c4a6e'],
    highlight: '#ecfeff',
    stroke: '#082f49',
    glow: 'drop-shadow-[0_6px_18px_rgba(56,189,248,0.65)]',
    crown: false, wings: true, flame: true,
    labelText: 'text-sky-600',
  },
  [Tier.CHAMPION]: {
    shield: ['#fecaca', '#ef4444', '#7f1d1d'],
    highlight: '#fee2e2',
    stroke: '#3f0606',
    glow: 'drop-shadow-[0_8px_22px_rgba(239,68,68,0.7)]',
    crown: true, wings: true, flame: true,
    labelText: 'text-rose-600',
  },
};

/* ---------------- Public component ---------------- */

export function TierBadge({
  tier, division, size = 'md', showLabel = true, animated = false,
}: TierBadgeProps) {
  const cfg = RANKS[tier];
  const px = SIZE_PX[size];
  const effectiveDivision: Division | undefined =
    tier === Tier.CHAMPION ? undefined : (division ?? 3);
  const tierName = tier.charAt(0) + tier.slice(1).toLowerCase();
  const label = effectiveDivision ? `${tierName} ${ROMAN[effectiveDivision]}` : tierName;

  return (
    <div className="inline-flex flex-col items-center gap-1.5">
      <motion.div
        whileHover={animated ? { scale: 1.06, rotate: -2 } : undefined}
        transition={{ type: 'spring', stiffness: 250, damping: 18 }}
        className={`relative ${cfg.glow}`}
        style={{ width: px, height: px * 1.18 }}
      >
        <RankCrest tier={tier} division={effectiveDivision} />
      </motion.div>
      {showLabel && (
        <span className={`${LABEL_TEXT[size]} font-black tracking-[0.18em] ${cfg.labelText} uppercase`}>
          {label}
        </span>
      )}
    </div>
  );
}

/* ---------------- SVG crest ---------------- */

export function RankCrest({ tier, division }: { tier: Tier; division?: Division }) {
  const cfg = RANKS[tier];
  const uid = `crest-${tier}-${division ?? 'X'}`;
  const [c1, c2, c3] = cfg.shield;
  const numeral = tier === Tier.CHAMPION ? '★' : ROMAN[division ?? 3];
  const pips = tier === Tier.CHAMPION ? 5 : (division ?? 3) === 1 ? 3 : (division ?? 3) === 2 ? 2 : 1;

  return (
    <svg
      viewBox="0 0 100 118"
      xmlns="http://www.w3.org/2000/svg"
      className="w-full h-full"
      aria-hidden
    >
      <defs>
        <linearGradient id={`${uid}-shield`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={c1} />
          <stop offset="55%" stopColor={c2} />
          <stop offset="100%" stopColor={c3} />
        </linearGradient>
        <linearGradient id={`${uid}-edge`} x1="0" y1="0" x2="1" y2="0">
          <stop offset="0%" stopColor={cfg.highlight} stopOpacity="0.9" />
          <stop offset="35%" stopColor={c1} stopOpacity="0.2" />
          <stop offset="65%" stopColor={c3} stopOpacity="0.2" />
          <stop offset="100%" stopColor={cfg.stroke} stopOpacity="0.6" />
        </linearGradient>
        <linearGradient id={`${uid}-inner`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={c2} />
          <stop offset="100%" stopColor={c3} />
        </linearGradient>
        <linearGradient id={`${uid}-sheen`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#ffffff" stopOpacity="0.55" />
          <stop offset="55%" stopColor="#ffffff" stopOpacity="0" />
        </linearGradient>
        <radialGradient id={`${uid}-flame`} cx="0.5" cy="0.65" r="0.6">
          <stop offset="0%" stopColor="#fff7c8" />
          <stop offset="55%" stopColor="#fb923c" />
          <stop offset="100%" stopColor="#7c2d12" stopOpacity="0" />
        </radialGradient>
      </defs>

      {/* FLAME PLUME */}
      {cfg.flame && (
        <g opacity="0.85">
          <path
            d="M50 2 C 44 14, 38 18, 40 28 C 42 22, 46 22, 50 18 C 54 22, 58 22, 60 28 C 62 18, 56 14, 50 2 Z"
            fill={`url(#${uid}-flame)`}
          />
        </g>
      )}

      {/* CROWN */}
      {cfg.crown && (
        <g transform="translate(50 14)">
          <path
            d="M -16 4 L -10 -6 L -4 2 L 0 -8 L 4 2 L 10 -6 L 16 4 L 14 8 L -14 8 Z"
            fill={`url(#${uid}-shield)`}
            stroke={cfg.stroke}
            strokeWidth="0.6"
            strokeLinejoin="round"
          />
          <circle cx="-10" cy="-6" r="1.4" fill={cfg.highlight} />
          <circle cx="0" cy="-8" r="1.6" fill={cfg.highlight} />
          <circle cx="10" cy="-6" r="1.4" fill={cfg.highlight} />
        </g>
      )}

      {/* WINGS */}
      {cfg.wings && (
        <g opacity="0.95">
          <path
            d="M 16 38 C 4 36, -2 46, 2 58 C 6 54, 12 52, 18 52 C 12 56, 8 60, 8 66 C 14 62, 22 60, 24 56 L 20 38 Z"
            fill={`url(#${uid}-inner)`}
            stroke={cfg.stroke}
            strokeWidth="0.6"
            strokeLinejoin="round"
          />
          <path
            d="M 84 38 C 96 36, 102 46, 98 58 C 94 54, 88 52, 82 52 C 88 56, 92 60, 92 66 C 86 62, 78 60, 76 56 L 80 38 Z"
            fill={`url(#${uid}-inner)`}
            stroke={cfg.stroke}
            strokeWidth="0.6"
            strokeLinejoin="round"
          />
        </g>
      )}

      {/* SHIELD BODY */}
      <path
        d="M 50 16 L 84 26 L 84 60 C 84 80, 70 92, 50 102 C 30 92, 16 80, 16 60 L 16 26 Z"
        fill={cfg.stroke}
      />
      <path
        d="M 50 19 L 81 28 L 81 60 C 81 78, 68 89, 50 99 C 32 89, 19 78, 19 60 L 19 28 Z"
        fill={`url(#${uid}-shield)`}
      />
      <path
        d="M 50 19 L 81 28 L 81 60 C 81 78, 68 89, 50 99 C 32 89, 19 78, 19 60 L 19 28 Z"
        fill={`url(#${uid}-edge)`}
        opacity="0.45"
      />
      <path
        d="M 50 19 L 81 28 L 81 56 C 70 50, 60 48, 50 48 C 40 48, 30 50, 19 56 L 19 28 Z"
        fill={`url(#${uid}-sheen)`}
      />
      <path
        d="M 50 26 L 75 33 L 75 60 C 75 75, 65 84, 50 92 C 35 84, 25 75, 25 60 L 25 33 Z"
        fill="none"
        stroke={cfg.highlight}
        strokeOpacity="0.55"
        strokeWidth="0.8"
      />

      {/* DIVISION NUMERAL PLATE */}
      <g transform="translate(50 54)">
        <polygon
          points="0,-13 12,-4 7.5,10.5 -7.5,10.5 -12,-4"
          fill="#ffffff"
          stroke={cfg.stroke}
          strokeWidth="1.4"
          strokeLinejoin="round"
        />
        <text
          x="0"
          y="4"
          textAnchor="middle"
          fontSize={numeral.length > 2 ? 7 : 10}
          fontWeight="900"
          fontFamily="system-ui, sans-serif"
          fill={cfg.stroke}
          letterSpacing="0.3"
        >
          {numeral}
        </text>
      </g>

      {/* DIVISION PIPS */}
      <g transform="translate(50 82)">
        <rect
          x={-15} y={-3.5} width={30} height={7} rx={3.5}
          fill={cfg.stroke} opacity="0.55"
        />
        {Array.from({ length: pips }).map((_, i) => {
          const totalWidth = pips * 5;
          const x = -totalWidth / 2 + 2.5 + i * 5;
          return <Star key={i} cx={x} cy={0} r={1.8} fill={cfg.highlight} />;
        })}
      </g>
    </svg>
  );
}

function Star({ cx, cy, r, fill }: { cx: number; cy: number; r: number; fill: string }) {
  const points: string[] = [];
  for (let i = 0; i < 10; i++) {
    const angle = (Math.PI / 5) * i - Math.PI / 2;
    const radius = i % 2 === 0 ? r : r * 0.45;
    points.push(`${cx + Math.cos(angle) * radius},${cy + Math.sin(angle) * radius}`);
  }
  return <polygon points={points.join(' ')} fill={fill} />;
}
