import { PageHeader } from '@/app/components/layout/PageHeader';
import { MOCK_CLANS, MOCK_FIXTURES, MOCK_PLAYERS } from '@/app/lib/data/mockData';
import { FixtureStatus, type Clan, type Player } from '@/app/lib/types';
import { Crown, ChevronLeft, ChevronRight, Goal, Sparkles, Medal } from 'lucide-react';
import { useMemo, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { useNavigate } from 'react-router';

const SEASONS = [
  { id: 1, label: 'Season 1', range: 'Mar – May 2026', active: false },
  { id: 2, label: 'Season 2', range: 'Jun – Aug 2026', active: true },
  { id: 3, label: 'Season 3', range: 'Sep – Nov 2026', active: false },
];

export default function Leaderboard() {
  const [seasonIdx, setSeasonIdx] = useState(1); // start on active season
  const navigate = useNavigate();
  const currentPlayer = MOCK_PLAYERS[0];
  const myClanId = currentPlayer.clanId;

  const ranked = useMemo(() => {
    return [...MOCK_CLANS]
      .sort((a, b) => b.skillRating - a.skillRating)
      .slice(0, 10)
      .map((clan, idx) => ({ clan, rank: idx + 1 }));
  }, []);

  // Top scorers & assisters across FINAL fixtures
  const { topScorers, topAssisters } = useMemo(() => {
    const goals = new Map<string, number>();
    const assists = new Map<string, number>();
    for (const f of MOCK_FIXTURES) {
      if (f.status !== FixtureStatus.FINAL || !f.scorers) continue;
      for (const s of f.scorers) {
        goals.set(s.playerId, (goals.get(s.playerId) ?? 0) + 1);
        if (s.assistPlayerId) {
          assists.set(s.assistPlayerId, (assists.get(s.assistPlayerId) ?? 0) + 1);
        }
      }
    }
    const toList = (m: Map<string, number>) =>
      [...m.entries()]
        .sort((a, b) => b[1] - a[1])
        .slice(0, 5)
        .map(([playerId, count]) => ({
          player: MOCK_PLAYERS.find(p => p.id === playerId)!,
          count,
        }))
        .filter(e => e.player);
    return { topScorers: toList(goals), topAssisters: toList(assists) };
  }, []);

  const season = SEASONS[seasonIdx];
  const goPrev = () => setSeasonIdx(i => Math.max(0, i - 1));
  const goNext = () => setSeasonIdx(i => Math.min(SEASONS.length - 1, i + 1));

  return (
    <div className="min-h-screen bg-gray-50 pb-8">
      <PageHeader title="Leaderboards" />

      {/* SEASON SELECTOR */}
      <div className="px-4 pt-4">
        <div className="flex items-center justify-between bg-white rounded-2xl border border-gray-100 shadow-sm p-3">
          <button
            onClick={goPrev}
            disabled={seasonIdx === 0}
            className="w-9 h-9 rounded-full bg-gray-50 flex items-center justify-center text-gray-500 disabled:opacity-30 active:scale-95 transition"
          >
            <ChevronLeft size={18} />
          </button>
          <AnimatePresence mode="wait">
            <motion.div
              key={season.id}
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -6 }}
              transition={{ duration: 0.2 }}
              className="text-center"
            >
              <div className="text-base font-black tracking-tight text-gray-900 uppercase">
                {season.label}
              </div>
              <div className="text-[10px] font-bold uppercase tracking-widest text-gray-400 mt-0.5 flex items-center justify-center gap-1.5">
                {season.active && (
                  <span className="inline-flex items-center gap-1 text-emerald-600">
                    <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse" />
                    LIVE
                  </span>
                )}
                {season.active && <span className="text-gray-300">·</span>}
                <span>{season.range}</span>
              </div>
            </motion.div>
          </AnimatePresence>
          <button
            onClick={goNext}
            disabled={seasonIdx === SEASONS.length - 1}
            className="w-9 h-9 rounded-full bg-gray-50 flex items-center justify-center text-gray-500 disabled:opacity-30 active:scale-95 transition"
          >
            <ChevronRight size={18} />
          </button>
        </div>
      </div>

      {/* TOP 10 HEADER */}
      <div className="px-4 pt-6 flex items-end justify-between">
        <div className="flex items-center gap-2">
          <span className="block w-1 h-6 rounded-full bg-gradient-to-b from-emerald-500 to-blue-600" />
          <h2 className="text-xl font-black tracking-tight text-gray-900 uppercase">The Top 10</h2>
        </div>
        <div className="text-[10px] font-black uppercase tracking-widest text-gray-400">
          {ranked.length} clans
        </div>
      </div>

      {/* TOP 10 LIST */}
      <div className="px-4 pt-3 space-y-2">
        {ranked.map((entry, i) => (
          <motion.div
            key={entry.clan.id}
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.03 * i }}
          >
            <ClanRankRow
              entry={entry}
              isMe={entry.clan.id === myClanId}
              onClick={() => navigate(`/clans/${entry.clan.id}`)}
            />
          </motion.div>
        ))}
      </div>

      {/* TOP SCORERS */}
      <div className="px-4 pt-8">
        <div className="flex items-center gap-2 mb-3">
          <span className="block w-1 h-5 rounded-full bg-gradient-to-b from-emerald-500 to-blue-600" />
          <Goal size={14} className="text-emerald-600" />
          <h3 className="text-xs font-black uppercase tracking-[0.18em] text-gray-700">Top Scorers</h3>
        </div>
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm divide-y divide-gray-100">
          {topScorers.length > 0 ? (
            topScorers.map((e, i) => (
              <PlayerStatRow key={e.player.id} rank={i + 1} player={e.player} value={e.count} label="goals" />
            ))
          ) : (
            <div className="p-6 text-center text-sm text-gray-400">No goals scored yet this season.</div>
          )}
        </div>
      </div>

      {/* TOP ASSISTERS */}
      <div className="px-4 pt-6">
        <div className="flex items-center gap-2 mb-3">
          <span className="block w-1 h-5 rounded-full bg-gradient-to-b from-emerald-500 to-blue-600" />
          <Sparkles size={14} className="text-blue-600" />
          <h3 className="text-xs font-black uppercase tracking-[0.18em] text-gray-700">Top Assisters</h3>
        </div>
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm divide-y divide-gray-100">
          {topAssisters.length > 0 ? (
            topAssisters.map((e, i) => (
              <PlayerStatRow key={e.player.id} rank={i + 1} player={e.player} value={e.count} label="assists" />
            ))
          ) : (
            <div className="p-6 text-center text-sm text-gray-400">No assists recorded yet this season.</div>
          )}
        </div>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------ */

function ClanRankRow({
  entry, isMe, onClick,
}: { entry: { clan: Clan; rank: number }; isMe: boolean; onClick: () => void }) {
  const rankBadge =
    entry.rank === 1 ? (
      <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-emerald-500 to-blue-600 flex items-center justify-center shadow-md shadow-emerald-500/30">
        <Crown size={16} className="text-white" fill="currentColor" />
      </div>
    ) : entry.rank <= 3 ? (
      <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-gray-700 to-gray-900 flex items-center justify-center text-white font-black text-sm">
        {entry.rank}
      </div>
    ) : (
      <div className="w-9 h-9 rounded-xl bg-gray-100 flex items-center justify-center text-gray-700 font-black text-sm">
        {entry.rank}
      </div>
    );

  return (
    <button
      onClick={onClick}
      className={`w-full text-left rounded-2xl p-3 border transition-all active:scale-[0.99] flex items-center gap-3 ${
        isMe
          ? 'bg-emerald-50 border-emerald-200 ring-1 ring-emerald-200 shadow-sm'
          : 'bg-white border-gray-100 shadow-sm hover:border-gray-200'
      }`}
    >
      {rankBadge}

      <div className="w-11 h-11 rounded-xl bg-gray-50 border border-gray-100 flex items-center justify-center text-2xl shrink-0">
        {entry.clan.emblem || '⚽'}
      </div>

      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-1.5">
          <div className="font-black text-sm text-gray-900 truncate">{entry.clan.name}</div>
          {isMe && (
            <span className="text-[9px] font-black uppercase tracking-wider text-emerald-700 bg-emerald-100 px-1.5 py-0.5 rounded">
              You
            </span>
          )}
        </div>
        <div className="text-xs text-gray-500 mt-0.5">
          {entry.clan.wins}W <span className="text-gray-300">·</span> {entry.clan.losses}L
        </div>
      </div>

      <div className="text-right shrink-0">
        <div className="text-base font-black text-gray-900 leading-none">{entry.clan.skillRating}</div>
        <div className="text-[10px] font-bold uppercase tracking-widest text-gray-400 mt-1">SR</div>
      </div>
    </button>
  );
}

function PlayerStatRow({
  rank, player, value, label,
}: { rank: number; player: Player; value: number; label: string }) {
  const initials = player.name.split(' ').map(n => n[0]).join('').slice(0, 2);
  return (
    <div className="flex items-center gap-3 p-3">
      <div className="w-7 text-center">
        {rank === 1 ? (
          <Medal size={18} className="mx-auto text-amber-500" fill="currentColor" />
        ) : (
          <div className="text-sm font-black text-gray-400">{rank}</div>
        )}
      </div>
      <div className="w-10 h-10 rounded-full bg-gradient-to-br from-emerald-500 to-blue-600 flex items-center justify-center text-white font-black text-sm shadow-sm">
        {initials}
      </div>
      <div className="flex-1 min-w-0">
        <div className="font-bold text-sm text-gray-900 truncate">{player.name}</div>
        <div className="text-xs text-gray-500 truncate">@{player.username}</div>
      </div>
      <div className="text-right">
        <div className="text-lg font-black text-gray-900 leading-none">{value}</div>
        <div className="text-[10px] font-bold uppercase tracking-widest text-gray-400 mt-0.5">{label}</div>
      </div>
    </div>
  );
}
