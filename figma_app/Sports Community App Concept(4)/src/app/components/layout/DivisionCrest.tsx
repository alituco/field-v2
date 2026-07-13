import { type Division } from '@/app/lib/types';
import { motion } from 'motion/react';

/**
 * FIFA-style division crests for Divisions 5 (entry) → 1 (top).
 * Each rank escalates the metalwork: bronze → steel → silver → gold → elite,
 * gaining wings, laurels, a crown, and radiant rays as it climbs.
 */

interface DivisionCrestConfig {
  /** Shield metal gradient stops: [top highlight, mid, deep]. */
  metal: [string, string, string];
  highlight: string;
  stroke: string;
  glow: string;
  stars: number;
  wings: boolean;
  laurel: boolean;
  crown: boolean;
  rays: boolean;
  accent: string;
}

const CRESTS: Record<Division, DivisionCrestConfig> = {
  5: {
    metal: ['#f6e2c5', '#c08a4e', '#6b3d16'],
    highlight: '#fff3df',
    stroke: '#3f2410',
    glow: 'drop-shadow-[0_6px_12px_rgba(176,115,51,0.45)]',
    stars: 1, wings: false, laurel: false, crown: false, rays: false,
    accent: '#b87333',
  },
  4: {
    metal: ['#e4ecf3', '#8695a5', '#3c4652'],
    highlight: '#f8fbff',
    stroke: '#232b34',
    glow: 'drop-shadow-[0_6px_12px_rgba(124,139,155,0.5)]',
    stars: 2, wings: true, laurel: false, crown: false, rays: false,
    accent: '#7c8b9b',
  },
  3: {
    metal: ['#f8fafc', '#9fb0c3', '#465569'],
    highlight: '#ffffff',
    stroke: '#1e293b',
    glow: 'drop-shadow-[0_6px_16px_rgba(148,163,184,0.6)]',
    stars: 3, wings: true, laurel: true, crown: false, rays: false,
    accent: '#94a3b8',
  },
  2: {
    metal: ['#fef0b8', '#f2a416', '#8a4b0c'],
    highlight: '#fff8d8',
    stroke: '#3a1d02',
    glow: 'drop-shadow-[0_6px_18px_rgba(245,158,11,0.6)]',
    stars: 4, wings: true, laurel: true, crown: true, rays: false,
    accent: '#f59e0b',
  },
  1: {
    metal: ['#e9fff6', '#34d399', '#065f46'],
    highlight: '#f0fff8',
    stroke: '#043027',
    glow: 'drop-shadow-[0_8px_26px_rgba(16,185,129,0.7)]',
    stars: 5, wings: true, laurel: true, crown: true, rays: true,
    accent: '#10b981',
  },
};

const SIZE_PX = { sm: 44, md: 72, lg: 112, xl: 168 } as const;

interface DivisionCrestProps {
  division: Division;
  size?: keyof typeof SIZE_PX;
  showLabel?: boolean;
  animated?: boolean;
}

export function DivisionCrest({ division, size = 'md', showLabel = false, animated = false }: DivisionCrestProps) {
  const cfg = CRESTS[division];
  const px = SIZE_PX[size];

  return (
    <div className="inline-flex flex-col items-center gap-2">
      <motion.div
        whileHover={animated ? { scale: 1.05, rotate: -1.5 } : undefined}
        transition={{ type: 'spring', stiffness: 240, damping: 16 }}
        className={cfg.glow}
        style={{ width: px, height: px * 1.18 }}
      >
        <CrestSvg division={division} />
      </motion.div>
      {showLabel && (
        <span className="text-[11px] font-black uppercase tracking-[0.18em] text-gray-600">
          Division {division}
        </span>
      )}
    </div>
  );
}

function CrestSvg({ division }: { division: Division }) {
  const cfg = CRESTS[division];
  const uid = `div-${division}`;
  const [m1, m2, m3] = cfg.metal;

  return (
    <svg viewBox="0 0 120 142" xmlns="http://www.w3.org/2000/svg" className="w-full h-full" aria-hidden>
      <defs>
        <linearGradient id={`${uid}-shield`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={m1} />
          <stop offset="52%" stopColor={m2} />
          <stop offset="100%" stopColor={m3} />
        </linearGradient>
        <linearGradient id={`${uid}-plate`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={m2} />
          <stop offset="100%" stopColor={m3} />
        </linearGradient>
        <linearGradient id={`${uid}-sheen`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#ffffff" stopOpacity="0.6" />
          <stop offset="55%" stopColor="#ffffff" stopOpacity="0" />
        </linearGradient>
        <radialGradient id={`${uid}-rays`} cx="0.5" cy="0.5" r="0.5">
          <stop offset="0%" stopColor={cfg.accent} stopOpacity="0.55" />
          <stop offset="100%" stopColor={cfg.accent} stopOpacity="0" />
        </radialGradient>
      </defs>

      {/* RADIANT RAYS (top division) */}
      {cfg.rays && (
        <g>
          <circle cx="60" cy="70" r="58" fill={`url(#${uid}-rays)`} />
          {Array.from({ length: 12 }).map((_, i) => {
            const a = (Math.PI / 6) * i;
            const x1 = 60 + Math.cos(a) * 44;
            const y1 = 70 + Math.sin(a) * 44;
            const x2 = 60 + Math.cos(a) * 58;
            const y2 = 70 + Math.sin(a) * 58;
            return <line key={i} x1={x1} y1={y1} x2={x2} y2={y2} stroke={cfg.accent} strokeOpacity="0.4" strokeWidth="2" strokeLinecap="round" />;
          })}
        </g>
      )}

      {/* WINGS */}
      {cfg.wings && (
        <g opacity="0.97">
          <path
            d="M 30 52 C 10 46, -2 58, 4 74 C 10 68, 18 66, 26 68 C 16 72, 10 78, 10 88 C 20 82, 32 78, 36 72 Z"
            fill={`url(#${uid}-plate)`} stroke={cfg.stroke} strokeWidth="0.7" strokeLinejoin="round"
          />
          <path
            d="M 90 52 C 110 46, 122 58, 116 74 C 110 68, 102 66, 94 68 C 104 72, 110 78, 110 88 C 100 82, 88 78, 84 72 Z"
            fill={`url(#${uid}-plate)`} stroke={cfg.stroke} strokeWidth="0.7" strokeLinejoin="round"
          />
        </g>
      )}

      {/* LAUREL */}
      {cfg.laurel && (
        <g opacity="0.9" stroke={cfg.stroke} strokeWidth="0.5">
          {[-1, 1].map(side => (
            <g key={side} transform={`translate(60 92) scale(${side} 1)`}>
              {Array.from({ length: 5 }).map((_, i) => {
                const t = i / 4;
                const x = 26 + t * 6;
                const y = 6 - t * 40;
                return <ellipse key={i} cx={x} cy={y} rx="4.6" ry="2.4" fill={`url(#${uid}-plate)`} transform={`rotate(${-40 - i * 8} ${x} ${y})`} />;
              })}
            </g>
          ))}
        </g>
      )}

      {/* CROWN */}
      {cfg.crown && (
        <g transform="translate(60 20)">
          <path
            d="M -18 6 L -11 -8 L -4 3 L 0 -11 L 4 3 L 11 -8 L 18 6 L 15 11 L -15 11 Z"
            fill={`url(#${uid}-shield)`} stroke={cfg.stroke} strokeWidth="0.7" strokeLinejoin="round"
          />
          <circle cx="-11" cy="-8" r="1.7" fill={cfg.highlight} />
          <circle cx="0" cy="-11" r="2" fill={cfg.highlight} />
          <circle cx="11" cy="-8" r="1.7" fill={cfg.highlight} />
        </g>
      )}

      {/* SHIELD BODY */}
      <path d="M 60 28 L 98 40 L 98 76 C 98 100, 82 116, 60 126 C 38 116, 22 100, 22 76 L 22 40 Z" fill={cfg.stroke} />
      <path d="M 60 31 L 95 42 L 95 76 C 95 98, 80 113, 60 122 C 40 113, 25 98, 25 76 L 25 42 Z" fill={`url(#${uid}-shield)`} />
      <path d="M 60 31 L 95 42 L 95 72 C 83 65, 71 63, 60 63 C 49 63, 37 65, 25 72 L 25 42 Z" fill={`url(#${uid}-sheen)`} />
      <path d="M 60 38 L 89 48 L 89 76 C 89 94, 76 107, 60 115 C 44 107, 31 94, 31 76 L 31 48 Z" fill="none" stroke={cfg.highlight} strokeOpacity="0.5" strokeWidth="1" />

      {/* BIG DIVISION NUMERAL */}
      <text
        x="60" y="86" textAnchor="middle" fontSize="42" fontWeight="900"
        fontFamily="system-ui, sans-serif" fill={cfg.stroke} opacity="0.28"
      >{division}</text>
      <text
        x="60" y="84" textAnchor="middle" fontSize="42" fontWeight="900"
        fontFamily="system-ui, sans-serif" fill={cfg.highlight}
      >{division}</text>

      {/* STAR RANK PIPS */}
      <g transform="translate(60 110)">
        {Array.from({ length: cfg.stars }).map((_, i) => {
          const total = cfg.stars * 9;
          const x = -total / 2 + 4.5 + i * 9;
          return <Star key={i} cx={x} cy={0} r={3.6} fill={cfg.highlight} stroke={cfg.stroke} />;
        })}
      </g>
    </svg>
  );
}

function Star({ cx, cy, r, fill, stroke }: { cx: number; cy: number; r: number; fill: string; stroke: string }) {
  const pts: string[] = [];
  for (let i = 0; i < 10; i++) {
    const angle = (Math.PI / 5) * i - Math.PI / 2;
    const radius = i % 2 === 0 ? r : r * 0.45;
    pts.push(`${cx + Math.cos(angle) * radius},${cy + Math.sin(angle) * radius}`);
  }
  return <polygon points={pts.join(' ')} fill={fill} stroke={stroke} strokeWidth="0.4" strokeLinejoin="round" />;
}
