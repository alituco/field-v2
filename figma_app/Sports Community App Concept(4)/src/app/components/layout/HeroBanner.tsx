import { motion } from 'motion/react';
import { ReactNode } from 'react';

export type HeroTheme = 'pitch' | 'electric' | 'sunset' | 'gold' | 'royal';

interface HeroBannerProps {
  eyebrow?: string;
  title: string;
  subtitle?: string;
  theme?: HeroTheme;
  icon?: ReactNode;
  chips?: Array<{ label: string; value: string | number; accent?: string }>;
  children?: ReactNode;
}

const themeStyles: Record<HeroTheme, {
  bg: string;
  glow: string;
  ring: string;
  pitch: string;
  eyebrowText: string;
}> = {
  pitch: {
    bg: 'bg-[radial-gradient(120%_120%_at_0%_0%,#10b981_0%,#059669_45%,#0b3d2e_100%)]',
    glow: 'bg-emerald-400',
    ring: 'shadow-emerald-500/40',
    pitch: 'rgba(255,255,255,0.18)',
    eyebrowText: 'text-emerald-100/90',
  },
  electric: {
    bg: 'bg-[radial-gradient(120%_120%_at_100%_0%,#22d3ee_0%,#3b82f6_45%,#1e1b4b_100%)]',
    glow: 'bg-cyan-300',
    ring: 'shadow-blue-500/40',
    pitch: 'rgba(255,255,255,0.18)',
    eyebrowText: 'text-cyan-100/90',
  },
  sunset: {
    bg: 'bg-[radial-gradient(120%_120%_at_0%_100%,#f97316_0%,#db2777_45%,#3b0764_100%)]',
    glow: 'bg-orange-300',
    ring: 'shadow-orange-500/40',
    pitch: 'rgba(255,255,255,0.18)',
    eyebrowText: 'text-orange-100/90',
  },
  gold: {
    bg: 'bg-[radial-gradient(120%_120%_at_100%_100%,#facc15_0%,#f59e0b_45%,#7c2d12_100%)]',
    glow: 'bg-yellow-200',
    ring: 'shadow-amber-500/40',
    pitch: 'rgba(255,255,255,0.22)',
    eyebrowText: 'text-yellow-100/90',
  },
  royal: {
    bg: 'bg-[radial-gradient(120%_120%_at_0%_0%,#a78bfa_0%,#7c3aed_40%,#1e1b4b_100%)]',
    glow: 'bg-fuchsia-300',
    ring: 'shadow-violet-500/40',
    pitch: 'rgba(255,255,255,0.18)',
    eyebrowText: 'text-violet-100/90',
  },
};

export function HeroBanner({
  eyebrow,
  title,
  subtitle,
  theme = 'pitch',
  icon,
  chips,
  children,
}: HeroBannerProps) {
  const s = themeStyles[theme];

  return (
    <motion.div
      initial={{ opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.45, ease: 'easeOut' }}
      className={`relative overflow-hidden rounded-3xl ${s.bg} text-white shadow-2xl ${s.ring} p-6`}
    >
      {/* Pitch lines */}
      <svg
        className="absolute inset-0 w-full h-full pointer-events-none"
        viewBox="0 0 400 240"
        preserveAspectRatio="none"
        aria-hidden
      >
        <defs>
          <linearGradient id="fadePitch" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor={s.pitch} stopOpacity="0" />
            <stop offset="50%" stopColor={s.pitch} stopOpacity="1" />
            <stop offset="100%" stopColor={s.pitch} stopOpacity="0" />
          </linearGradient>
        </defs>
        {/* Halfway line */}
        <line x1="200" y1="-20" x2="200" y2="260" stroke="url(#fadePitch)" strokeWidth="1.5" />
        {/* Center circle */}
        <circle cx="200" cy="120" r="58" fill="none" stroke={s.pitch} strokeWidth="1.5" />
        <circle cx="200" cy="120" r="3" fill={s.pitch} />
        {/* Corner arc (top right) */}
        <path d="M 400 0 A 28 28 0 0 1 372 28" fill="none" stroke={s.pitch} strokeWidth="1.5" />
        {/* Corner arc (bottom left) */}
        <path d="M 0 240 A 28 28 0 0 1 28 212" fill="none" stroke={s.pitch} strokeWidth="1.5" />
      </svg>

      {/* Glowing orb */}
      <motion.div
        className={`absolute -top-16 -right-16 w-56 h-56 rounded-full ${s.glow} opacity-25 blur-3xl`}
        animate={{ scale: [1, 1.15, 1], opacity: [0.18, 0.3, 0.18] }}
        transition={{ duration: 6, repeat: Infinity, ease: 'easeInOut' }}
      />

      {/* Content */}
      <div className="relative">
        <div className="flex items-start justify-between gap-4">
          <div className="flex-1 min-w-0">
            {eyebrow && (
              <div className={`flex items-center gap-2 mb-2 ${s.eyebrowText}`}>
                <span className="block w-6 h-[2px] bg-white/70 rounded-full" />
                <span className="text-[10px] font-black uppercase tracking-[0.2em]">
                  {eyebrow}
                </span>
              </div>
            )}
            <h2 className="text-3xl font-black tracking-tight leading-[1.05] uppercase drop-shadow-sm">
              {title}
            </h2>
            {subtitle && (
              <p className="mt-2 text-sm text-white/85 max-w-xs">{subtitle}</p>
            )}
          </div>

          {icon && (
            <motion.div
              initial={{ rotate: -8, scale: 0.9 }}
              animate={{ rotate: 0, scale: 1 }}
              transition={{ type: 'spring', stiffness: 160, damping: 12 }}
              className="relative w-14 h-14 rounded-2xl bg-white/15 backdrop-blur-md border border-white/25 flex items-center justify-center shadow-lg shrink-0"
            >
              {icon}
            </motion.div>
          )}
        </div>

        {chips && chips.length > 0 && (
          <div className="mt-5 flex flex-wrap gap-2">
            {chips.map((chip, i) => (
              <motion.div
                key={chip.label}
                initial={{ opacity: 0, y: 6 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.1 + i * 0.06 }}
                className="flex items-center gap-1.5 rounded-full bg-white/15 backdrop-blur-md border border-white/20 px-3 py-1.5"
              >
                <span className={`text-sm font-black ${chip.accent ?? 'text-white'}`}>
                  {chip.value}
                </span>
                <span className="text-[10px] font-bold uppercase tracking-wider text-white/80">
                  {chip.label}
                </span>
              </motion.div>
            ))}
          </div>
        )}

        {children && <div className="mt-5">{children}</div>}
      </div>
    </motion.div>
  );
}
