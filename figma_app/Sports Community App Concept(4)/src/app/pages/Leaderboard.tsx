import { PageHeader } from '@/app/components/layout/PageHeader';
import { TierBadge } from '@/app/components/layout/TierBadge';
import { MOCK_CLANS } from '@/app/lib/data/mockData';
import { getCurrentPlayer } from '@/app/lib/social';
import { DIVISION_CONFIGS, getRankFromRating } from '@/app/lib/constants/tiers';
import { ChevronRight, Trophy } from 'lucide-react';
import { motion } from 'motion/react';
import { useNavigate } from 'react-router';

const divisions = [1, 2, 3, 4, 5] as const;

export default function Leaderboard() {
  const navigate = useNavigate();
  const currentPlayer = getCurrentPlayer();
  const myClan = MOCK_CLANS.find((clan) => clan.id === currentPlayer.clanId);
  const myDivision = myClan ? getRankFromRating(myClan.skillRating).division : null;

  return (
    <div className="min-h-screen bg-gray-50 pb-24">
      <PageHeader title="Divisions" />

      <main className="px-4 pt-4">
        {/* TEMP: preview the new FIFA-style division crest art */}
        <button
          onClick={() => navigate('/division-art')}
          className="mb-4 flex w-full items-center justify-center gap-2 rounded-2xl border border-dashed border-amber-300 bg-amber-50 py-3 text-sm font-bold text-amber-700 active:scale-[0.99]"
        >
          🎨 Preview division art (temp)
        </button>

        <section className="rounded-3xl border border-emerald-100 bg-emerald-700 px-5 py-6 text-white shadow-sm">
          <div className="flex items-start justify-between gap-4">
            <div>
              <p className="text-[11px] font-bold uppercase tracking-[0.16em] text-emerald-100">Clan ladder</p>
              <h1 className="mt-1 text-2xl font-black">Move up together.</h1>
              <p className="mt-2 max-w-[235px] text-sm leading-5 text-emerald-50">Win matches to take your clan from Division 5 to Division 1.</p>
            </div>
            <Trophy className="mt-1 text-emerald-200" size={30} strokeWidth={1.8} />
          </div>
        </section>

        {myClan ? (
          <button onClick={() => navigate(`/clans/${myClan.id}`)} className="mt-4 flex w-full items-center gap-3 rounded-2xl border border-gray-200 bg-white p-4 text-left shadow-sm active:scale-[0.99]">
            <TierBadge division={myDivision!} size="md" showLabel={false} />
            <span className="min-w-0 flex-1">
              <span className="block text-[10px] font-bold uppercase tracking-[0.14em] text-gray-400">Your clan</span>
              <span className="mt-0.5 block truncate text-base font-black text-gray-900">{myClan.emblem} {myClan.name}</span>
              <span className="block text-sm font-semibold text-emerald-700">Division {myDivision}</span>
            </span>
            <ChevronRight size={18} className="text-gray-400" />
          </button>
        ) : (
          <button onClick={() => navigate('/clans')} className="mt-4 flex w-full items-center justify-between rounded-2xl border border-gray-200 bg-white p-4 text-left shadow-sm">
            <span><span className="block font-bold text-gray-900">No clan yet</span><span className="mt-0.5 block text-sm text-gray-500">Join a clan to enter the ladder.</span></span>
            <ChevronRight size={18} className="text-gray-400" />
          </button>
        )}

        <section className="mt-7">
          <div className="mb-3 flex items-end justify-between">
            <div><h2 className="text-lg font-black text-gray-900">The divisions</h2><p className="text-sm text-gray-500">One simple path for every clan.</p></div>
            <span className="text-[10px] font-bold uppercase tracking-[0.14em] text-gray-400">Top → entry</span>
          </div>
          <div className="overflow-hidden rounded-2xl border border-gray-200 bg-white shadow-sm">
            {divisions.map((division, index) => {
              const config = DIVISION_CONFIGS[division];
              const clans = MOCK_CLANS.filter((clan) => getRankFromRating(clan.skillRating).division === division);
              return (
                <motion.button key={division} initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: index * 0.04 }} onClick={() => clans[0] && navigate(`/clans/${clans[0].id}`)} className="flex w-full items-center gap-3 px-4 py-4 text-left transition-colors hover:bg-gray-50 disabled:cursor-default border-b border-gray-100 last:border-b-0" disabled={clans.length === 0}>
                  <TierBadge division={division} size="sm" showLabel={false} />
                  <span className="flex-1"><span className="block font-bold text-gray-900">{config.label}</span><span className="block text-sm text-gray-500">{config.description}</span></span>
                  <span className="text-xs font-semibold text-gray-400">{clans.length} {clans.length === 1 ? 'clan' : 'clans'}</span>
                </motion.button>
              );
            })}
          </div>
        </section>
      </main>
    </div>
  );
}
