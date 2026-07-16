import { useNavigate, useSearchParams } from 'react-router';
import { motion } from 'motion/react';
import { PageHeader } from '@/app/components/layout/PageHeader';
import {
  roleLabel,
  availabilityFor,
  matchGames,
  resolveBackups,
  type Availability,
  type BackupMatch,
} from '@/app/lib/openQueue';
import type { QueueRole, QueueMatch } from '@/app/lib/types';
import { MapPin, Users, Zap, Pencil, Rocket, ChevronRight } from 'lucide-react';

const AVAIL: Record<Availability, { badge: string; label: (r: QueueRole) => string; strong?: boolean }> = {
  neededNow: { badge: 'bg-emerald-100 text-emerald-700', label: r => `${roleLabel(r)} needed`, strong: true },
  available: { badge: 'bg-blue-50 text-blue-700', label: r => `Available as ${roleLabel(r).toLowerCase()}` },
  lastSpot: { badge: 'bg-amber-100 text-amber-700', label: () => 'Last spot' },
  full: { badge: 'bg-gray-100 text-gray-400', label: () => 'Position full' },
};

export default function QueueGames() {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const main = (params.get('main') as QueueRole) || null;
  const rawBackups = (params.get('backup')?.split(',').filter(Boolean) ?? []) as (QueueRole | 'ANY')[];

  if (!main) {
    return (
      <div className="min-h-screen bg-gray-50">
        <PageHeader title="Games for you" showBack />
        <div className="p-8 text-center text-gray-500">
          No position selected.
          <button onClick={() => navigate('/queue')} className="block mx-auto mt-4 text-emerald-600 font-bold">
            Choose a position
          </button>
        </div>
      </div>
    );
  }

  const backups = resolveBackups(main, rawBackups);
  const { primary, backupMatches } = matchGames(main, backups);

  // "Fastest way to play" banner: main has no instant game but a backup does.
  const mainHasInstant = primary.some(m => availabilityFor(m, main) === 'neededNow');
  const backupInstant = backupMatches.find(b => b.availability === 'neededNow');
  const showFastBanner = !mainHasInstant && !!backupInstant;

  const editPositions = () => {
    const q = new URLSearchParams({ main });
    if (rawBackups.length) q.set('backup', rawBackups.join(','));
    navigate(`/queue?${q.toString()}`);
  };

  const join = (match: QueueMatch, role: QueueRole) =>
    navigate(`/queue/review/${match.id}?role=${role}`);

  return (
    <div className="min-h-screen bg-gray-50 pb-8">
      <PageHeader title="Games for you" showBack />

      <div className="p-4 space-y-6">
        {/* Selected positions header */}
        <div className="flex items-center justify-between rounded-2xl bg-white border border-gray-100 shadow-sm px-4 py-3">
          <div className="flex items-center gap-3 min-w-0">
            <div>
              <div className="text-sm font-black text-gray-900">{roleLabel(main)}</div>
              <div className="text-[10px] font-bold uppercase tracking-wider text-emerald-600">
                Main position
              </div>
            </div>
            {backups.length > 0 && (
              <>
                <span className="h-8 w-px bg-gray-200" />
                <div className="min-w-0">
                  <div className="text-sm font-bold text-gray-700 truncate">
                    {rawBackups.includes('ANY') ? 'Anywhere' : backups.map(b => roleLabel(b)).join(', ')}
                  </div>
                  <div className="text-[10px] font-bold uppercase tracking-wider text-gray-400">
                    Backup
                  </div>
                </div>
              </>
            )}
          </div>
          <button
            onClick={editPositions}
            className="shrink-0 flex items-center gap-1 text-xs font-bold text-gray-500 rounded-full border border-gray-200 px-3 py-1.5 active:scale-95 transition-transform"
          >
            <Pencil size={12} /> Edit
          </button>
        </div>

        {/* Fastest way to play */}
        {showFastBanner && backupInstant && (
          <motion.button
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            whileTap={{ scale: 0.98 }}
            onClick={() => join(backupInstant.match, backupInstant.role)}
            className="w-full text-left rounded-3xl bg-gray-900 text-white p-5"
          >
            <div className="flex items-center gap-2 text-emerald-400">
              <Rocket size={15} />
              <span className="text-[10px] font-black uppercase tracking-[0.2em]">
                Fastest way to play
              </span>
            </div>
            <p className="mt-2 text-sm font-semibold">
              A {roleLabel(backupInstant.role)} spot is open{' '}
              {backupInstant.match.dateGroup === 'TODAY' ? 'today' : backupInstant.match.dateGroup.toLowerCase()} at{' '}
              {backupInstant.match.startTime}. No {roleLabel(main).toLowerCase()} spot is instantly available.
            </p>
            <span className="mt-3 inline-flex items-center gap-1 text-xs font-bold text-emerald-300">
              View {roleLabel(backupInstant.role).toLowerCase()} match <ChevronRight size={14} />
            </span>
          </motion.button>
        )}

        {/* BEST MATCHES (primary) */}
        <div className="space-y-3">
          <div>
            <h2 className="text-xs font-black uppercase tracking-widest text-gray-500">
              Best matches for you
            </h2>
            <p className="text-xs text-gray-400 mt-0.5">Playing as {roleLabel(main).toLowerCase()}</p>
          </div>

          {primary.length > 0 ? (
            primary.map(match => (
              <GameCard
                key={match.id}
                match={match}
                role={main}
                onJoin={() => join(match, main)}
              />
            ))
          ) : (
            <div className="rounded-2xl bg-white border border-gray-100 shadow-sm px-4 py-4 text-sm text-gray-600">
              No {roleLabel(main).toLowerCase()} spot is available in the next four games.
              {backupMatches.length > 0 && (
                <span className="block mt-1 text-gray-400">
                  But {backupMatches.length} game{backupMatches.length === 1 ? '' : 's'} can confirm you in a backup position.
                </span>
              )}
            </div>
          )}
        </div>

        {/* MORE GAMES (backup) */}
        {backupMatches.length > 0 && (
          <div className="space-y-3">
            <div className="flex items-center gap-3">
              <span className="h-px flex-1 bg-gray-200" />
              <span className="text-[11px] font-black uppercase tracking-widest text-gray-400">
                More games you can join
              </span>
              <span className="h-px flex-1 bg-gray-200" />
            </div>
            <p className="text-xs text-gray-400 -mt-1 text-center">Using your backup positions</p>

            {backupMatches.map(bm => (
              <GameCard
                key={bm.match.id}
                match={bm.match}
                role={bm.role}
                backup
                onJoin={() => join(bm.match, bm.role)}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function GameCard({
  match,
  role,
  backup = false,
  onJoin,
}: {
  match: QueueMatch;
  role: QueueRole;
  backup?: boolean;
  onJoin: () => void;
}) {
  const availability = availabilityFor(match, role);
  const meta = AVAIL[availability];

  return (
    <motion.div
      layout
      className={`rounded-3xl border p-4 bg-white ${
        meta.strong ? 'border-emerald-300 shadow-sm ring-1 ring-emerald-200' : 'border-gray-100 shadow-sm'
      }`}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-[10px] font-black uppercase tracking-widest text-gray-400">
            {match.dateGroup}
          </div>
          <div className="text-base font-black text-gray-900">{match.timeLabel}</div>
          <div className="mt-0.5 flex items-center gap-1 text-xs text-gray-500">
            <MapPin size={12} />
            <span className="truncate">{match.venue}</span>
          </div>
        </div>
        <span className={`shrink-0 px-2.5 py-1 rounded-full text-[11px] font-black ${meta.badge}`}>
          {meta.label(role)}
        </span>
      </div>

      {availability === 'neededNow' && (
        <p className="mt-2 text-xs font-semibold text-emerald-700">Your place can be confirmed now.</p>
      )}

      <div className="mt-3 flex items-center gap-2 text-xs text-gray-400">
        <Users size={12} />
        <span>{match.confirmed} of {match.capacity} players</span>
        <span className="text-gray-300">·</span>
        <span>{match.ageLabel}</span>
      </div>

      <div className="mt-3 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="text-[10px] font-black uppercase tracking-wider text-blue-600 bg-blue-50 px-2 py-0.5 rounded-full">
            Ranked
          </span>
          <span className="text-sm font-black text-gray-900">{match.price} BHD</span>
        </div>
        <motion.button
          whileTap={{ scale: 0.96 }}
          onClick={onJoin}
          className={`px-5 h-10 rounded-2xl font-black text-sm flex items-center gap-1 ${
            meta.strong ? 'bg-emerald-500 text-white shadow-lg shadow-emerald-500/30' : 'bg-gray-900 text-white'
          }`}
        >
          {backup ? `Join as ${roleLabel(role)}` : 'Join'}
          <Zap size={14} fill="currentColor" />
        </motion.button>
      </div>
    </motion.div>
  );
}
