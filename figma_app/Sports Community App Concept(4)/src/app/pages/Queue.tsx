import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { motion, AnimatePresence } from 'motion/react';
import { PageHeader } from '@/app/components/layout/PageHeader';
import { PitchFormation } from '@/app/components/queue/PitchFormation';
import { ROLES, roleLabel, needCount } from '@/app/lib/openQueue';
import type { QueueRole } from '@/app/lib/types';
import { Check, ChevronRight, Info } from 'lucide-react';

type Backup = QueueRole | 'ANY';
const MAX_BACKUPS = 2;

export default function Queue() {
  const navigate = useNavigate();
  const [params] = useSearchParams();

  // Restore selection when arriving via "Edit positions".
  const [main, setMain] = useState<QueueRole | null>(
    (params.get('main') as QueueRole) || null
  );
  const [backups, setBackups] = useState<Backup[]>(() => {
    const raw = params.get('backup');
    if (!raw) return [];
    return raw.split(',').filter(Boolean) as Backup[];
  });

  const pickMain = (role: QueueRole) => {
    if (main === role) {
      setMain(null);
      return;
    }
    setMain(role);
    // A role can't be both main and backup.
    setBackups(prev => prev.filter(b => b !== role));
  };

  const toggleBackup = (role: Backup) => {
    setBackups(prev => {
      if (prev.includes(role)) return prev.filter(b => b !== role);
      if (role === 'ANY') return ['ANY']; // Anywhere replaces specific picks.
      const withoutAny = prev.filter(b => b !== 'ANY');
      if (withoutAny.length >= MAX_BACKUPS) return withoutAny; // cap reached
      return [...withoutAny, role];
    });
  };

  const gkSelected = main === 'GK' || backups.includes('GK');
  const backupCount = backups.filter(b => b !== 'ANY').length;
  const anyPicked = backups.includes('ANY');

  const proceed = () => {
    if (!main) return;
    const q = new URLSearchParams({ main });
    if (backups.length) q.set('backup', backups.join(','));
    navigate(`/queue/games?${q.toString()}`);
  };

  return (
    <div className="min-h-screen bg-gray-50 pb-52">
      <PageHeader title="Open Queue" showBack />

      <div className="p-4 space-y-6">
        <div>
          <h1 className="text-2xl font-black text-gray-900 uppercase tracking-tight">
            Where do you play?
          </h1>
          <p className="mt-1 text-sm text-gray-500">Choose your main position.</p>
        </div>

        <PitchFormation
          main={main}
          backups={backups.includes('ANY') ? ROLES.map(r => r.key).filter(r => r !== main) : (backups as QueueRole[])}
          onPick={pickMain}
        />

        {/* MAIN POSITION */}
        <div>
          <div className="text-[11px] font-black uppercase tracking-widest text-gray-500 mb-2">
            Main position
          </div>
          <div className="grid grid-cols-2 gap-2.5">
            {ROLES.map(role => {
              const selected = main === role.key;
              return (
                <motion.button
                  key={role.key}
                  whileTap={{ scale: 0.97 }}
                  onClick={() => pickMain(role.key)}
                  className={`flex items-center justify-between rounded-2xl border-2 px-4 py-3.5 text-left font-black transition-colors ${
                    selected
                      ? 'border-emerald-500 bg-emerald-500 text-white shadow-lg shadow-emerald-500/25'
                      : 'border-gray-200 bg-white text-gray-900'
                  }`}
                >
                  {role.label}
                  {selected ? (
                    <span className="w-6 h-6 rounded-full bg-white/25 flex items-center justify-center">
                      <Check size={15} strokeWidth={3.5} />
                    </span>
                  ) : (
                    <span className="w-6 h-6 rounded-full border-2 border-gray-200" />
                  )}
                </motion.button>
              );
            })}
          </div>
        </div>

        {/* BACKUP POSITIONS (only once a main is chosen) */}
        <AnimatePresence>
          {main && (
            <motion.div
              initial={{ opacity: 0, height: 0 }}
              animate={{ opacity: 1, height: 'auto' }}
              exit={{ opacity: 0, height: 0 }}
              className="overflow-hidden"
            >
              <div className="text-[11px] font-black uppercase tracking-widest text-gray-500 mb-1">
                Where else are you comfortable playing?
              </div>
              <p className="text-xs text-gray-400 mb-2.5">
                Optional · up to {MAX_BACKUPS} backups
              </p>
              <div className="flex flex-wrap gap-2">
                {ROLES.filter(r => r.key !== main).map(role => {
                  const on = backups.includes(role.key);
                  const disabled = !on && !anyPicked && backupCount >= MAX_BACKUPS;
                  return (
                    <button
                      key={role.key}
                      onClick={() => !disabled && !anyPicked && toggleBackup(role.key)}
                      disabled={disabled || anyPicked}
                      className={`px-4 h-11 rounded-full border-2 text-sm font-bold transition-colors ${
                        on
                          ? 'border-emerald-500 text-emerald-700 bg-emerald-50'
                          : disabled || anyPicked
                          ? 'border-gray-100 text-gray-300 bg-white'
                          : 'border-gray-200 text-gray-600 bg-white'
                      }`}
                    >
                      {on && <Check size={14} className="inline -mt-0.5 mr-1" strokeWidth={3} />}
                      {role.label}
                    </button>
                  );
                })}
                {/* Anywhere */}
                <button
                  onClick={() => toggleBackup('ANY')}
                  className={`px-4 h-11 rounded-full border-2 text-sm font-bold transition-colors ${
                    anyPicked
                      ? 'border-emerald-500 text-emerald-700 bg-emerald-50'
                      : 'border-gray-200 text-gray-600 bg-white'
                  }`}
                >
                  {anyPicked && <Check size={14} className="inline -mt-0.5 mr-1" strokeWidth={3} />}
                  Anywhere
                </button>
              </div>

              {/* Goalkeeper confirmation */}
              {gkSelected && (
                <div className="mt-3 flex items-start gap-2 rounded-2xl bg-amber-50 border border-amber-100 px-3.5 py-3">
                  <Info size={15} className="text-amber-600 shrink-0 mt-0.5" />
                  <p className="text-xs text-amber-800">
                    Only choose Goalkeeper if you're comfortable playing the full match in goal.
                  </p>
                </div>
              )}
            </motion.div>
          )}
        </AnimatePresence>

        {/* Availability preview */}
        {main && (
          <div className="rounded-2xl bg-white border border-gray-100 shadow-sm px-4 py-3">
            <div className="text-sm font-bold text-gray-900">
              {needCount(main)} upcoming game{needCount(main) === 1 ? '' : 's'} can use you as {roleLabel(main).toLowerCase()}
            </div>
            <div className="text-xs text-gray-400 mt-0.5">
              Pick the position you actually want to play — availability can change.
            </div>
          </div>
        )}
      </div>

      {/* Sticky summary + CTA */}
      <AnimatePresence>
        {main && (
          <motion.div
            initial={{ y: 80 }}
            animate={{ y: 0 }}
            exit={{ y: 80 }}
            className="fixed bottom-16 inset-x-0 z-40 border-t border-gray-200/60 bg-white/95 p-4 pb-[max(1rem,env(safe-area-inset-bottom))] shadow-[0_-10px_30px_rgba(15,23,42,0.08)] backdrop-blur-xl"
          >
            <div className="flex items-center justify-between mb-3 text-sm">
              <div className="flex items-center gap-2 min-w-0">
                <span className="px-2.5 py-1 rounded-full bg-emerald-500 text-white text-xs font-black">
                  {roleLabel(main)}
                </span>
                {(backupCount > 0 || anyPicked) && (
                  <span className="text-xs font-bold text-gray-500 truncate">
                    +{' '}
                    {anyPicked
                      ? 'Anywhere'
                      : (backups as QueueRole[]).map(b => roleLabel(b)).join(', ')}
                  </span>
                )}
              </div>
            </div>
            <motion.button
              whileTap={{ scale: 0.98 }}
              onClick={proceed}
              className="w-full h-14 rounded-2xl bg-emerald-600 hover:bg-emerald-700 text-white font-black tracking-wide flex items-center justify-center gap-2 shadow-lg shadow-emerald-500/25"
            >
              See matching games <ChevronRight size={18} />
            </motion.button>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
