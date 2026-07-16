import { type QueueRole } from '@/app/lib/types';
import { motion } from 'motion/react';
import { Check } from 'lucide-react';

/**
 * Interactive 1-2-2-1 pitch. Tapping a position sets it as the MAIN position
 * (tap again to clear). The whole line for the main role fills solid; backup
 * lines (driven by the buttons below) show as outlines. Labels make the role
 * of each line explicit without asking the user to pick left/right.
 */

interface PitchNode {
  role: QueueRole;
  x: number;
  y: number;
}

const NODES: PitchNode[] = [
  { role: 'ATT', x: 50, y: 16 },
  { role: 'MID', x: 27, y: 43 },
  { role: 'MID', x: 73, y: 43 },
  { role: 'DEF', x: 27, y: 69 },
  { role: 'DEF', x: 73, y: 69 },
  { role: 'GK', x: 50, y: 90 },
];

const ROLE_FULL: Record<QueueRole, string> = {
  ATT: 'Attacker',
  MID: 'Midfielder',
  DEF: 'Defender',
  GK: 'Goalkeeper',
};

interface PitchFormationProps {
  main: QueueRole | null;
  backups: QueueRole[];
  onPick: (role: QueueRole) => void;
}

export function PitchFormation({ main, backups, onPick }: PitchFormationProps) {
  return (
    <div className="relative mx-auto aspect-[3/4] w-full max-w-[300px] overflow-hidden rounded-[2rem] bg-[linear-gradient(160deg,#0d9668_0%,#059669_40%,#065f46_100%)] shadow-xl shadow-emerald-600/40">
      {/* Mowed grass stripes */}
      <div className="absolute inset-0 opacity-[0.14]">
        {[0, 1, 2, 3, 4, 5].map(i => (
          <div
            key={i}
            className={i % 2 === 0 ? 'bg-white' : 'bg-transparent'}
            style={{ position: 'absolute', top: `${i * 16.66}%`, left: 0, right: 0, height: '16.66%' }}
          />
        ))}
      </div>

      {/* Pitch markings */}
      <svg viewBox="0 0 300 400" className="absolute inset-0 h-full w-full" preserveAspectRatio="none" aria-hidden>
        <rect x="12" y="12" width="276" height="376" fill="none" stroke="rgba(255,255,255,0.35)" strokeWidth="2" rx="10" />
        <line x1="12" y1="200" x2="288" y2="200" stroke="rgba(255,255,255,0.35)" strokeWidth="2" />
        <circle cx="150" cy="200" r="46" fill="none" stroke="rgba(255,255,255,0.35)" strokeWidth="2" />
        <circle cx="150" cy="200" r="3" fill="rgba(255,255,255,0.5)" />
        <rect x="92" y="12" width="116" height="44" fill="none" stroke="rgba(255,255,255,0.35)" strokeWidth="2" />
        <rect x="92" y="344" width="116" height="44" fill="none" stroke="rgba(255,255,255,0.35)" strokeWidth="2" />
      </svg>

      {/* Position markers */}
      {NODES.map((node, i) => {
        const isMain = main === node.role;
        const isBackup = backups.includes(node.role);

        return (
          <button
            key={`${node.role}-${i}`}
            onClick={() => onPick(node.role)}
            className="absolute -translate-x-1/2 -translate-y-1/2 p-1.5"
            style={{ left: `${node.x}%`, top: `${node.y}%` }}
            aria-label={`Select ${ROLE_FULL[node.role]}`}
          >
            {isMain && (
              <motion.span
                className="absolute inset-0 m-auto h-14 w-14 rounded-full bg-lime-300 blur-md"
                animate={{ opacity: [0.5, 0.85, 0.5], scale: [1, 1.15, 1] }}
                transition={{ duration: 2, repeat: Infinity, ease: 'easeInOut' }}
              />
            )}
            <motion.span
              animate={isMain ? { scale: [1, 1.14, 1] } : { scale: 1 }}
              transition={{ duration: 0.3 }}
              className={`relative flex h-14 w-14 flex-col items-center justify-center rounded-full border-2 text-[11px] font-black leading-none transition-colors ${
                isMain
                  ? 'border-white bg-white text-emerald-700 shadow-lg shadow-black/25'
                  : isBackup
                  ? 'border-white bg-white/25 text-white backdrop-blur-sm ring-2 ring-white'
                  : 'border-white/50 bg-white/10 text-white/85 backdrop-blur-sm'
              }`}
            >
              {isMain ? <Check size={22} strokeWidth={3.5} /> : <span>{node.role}</span>}
            </motion.span>
            {(isMain || isBackup) && (
              <span className="absolute left-1/2 top-full mt-1 -translate-x-1/2 whitespace-nowrap rounded-full bg-black/40 px-2 py-0.5 text-[8px] font-black uppercase tracking-wider text-white backdrop-blur-sm">
                {isMain ? 'Main' : 'Backup'}
              </span>
            )}
          </button>
        );
      })}

      {!main && (
        <motion.div
          initial={{ opacity: 0, y: 6 }}
          animate={{ opacity: 1, y: 0 }}
          className="absolute bottom-3 left-1/2 -translate-x-1/2 rounded-full bg-black/35 px-3 py-1.5 text-[11px] font-bold text-white backdrop-blur-sm"
        >
          Tap your main position
        </motion.div>
      )}
    </div>
  );
}
