import { PageHeader } from '@/app/components/layout/PageHeader';
import { MOCK_CLANS, MOCK_FIXTURES } from '@/app/lib/data/mockData';
import { getCurrentPlayer } from '@/app/lib/social';
import { getRankFromRating, TIER_CONFIGS } from '@/app/lib/constants/tiers';
import { FixtureStatus } from '@/app/lib/types';
import { Zap, MapPin, Clock, Radio, Users, ChevronRight, Trophy } from 'lucide-react';
import { motion } from 'motion/react';
import { useNavigate } from 'react-router';

export default function Home() {
  const navigate = useNavigate();
  const currentPlayer = getCurrentPlayer();
  const myClan = MOCK_CLANS.find(c => c.id === currentPlayer.clanId);
  const isLeader = myClan?.ownerId === currentPlayer.id;
  const rank = myClan ? getRankFromRating(myClan.skillRating) : null;
  const tierConfig = rank ? TIER_CONFIGS[rank.tier] : null;

  const firstName = currentPlayer.name.split(' ')[0];

  // Unified feed: live first, then scheduled/open, then finals — all fixtures
  const feed = [...MOCK_FIXTURES].sort((a, b) => {
    const order = { LIVE: 0, SCHEDULED: 1, OPEN: 2, FINAL: 3 };
    return order[a.status] - order[b.status];
  });

  return (
    <div className="min-h-screen bg-gray-50">
      <PageHeader brand title="Field" />

      <div className="p-4 space-y-5">

        {/* GREETING + CTA */}
        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.3 }}
          className="bg-white rounded-3xl border border-gray-100 shadow-sm p-5"
        >
          <div className="flex items-center justify-between">
            <div>
              <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider">
                {new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' })}
              </div>
              <h1 className="text-2xl font-black text-gray-900 mt-0.5">
                Hey, {firstName} 👋
              </h1>
              {myClan ? (
                <div className="mt-1 flex items-center gap-1.5 text-sm text-gray-500">
                  <span>{myClan.emblem}</span>
                  <span className="font-semibold text-gray-700">{myClan.name}</span>
                  {tierConfig && (
                    <span className={`font-black text-xs ${tierConfig.textColor}`}>
                      · {rank!.tier.charAt(0) + rank!.tier.slice(1).toLowerCase()}
                      {rank!.division ? ` ${['III','II','I'][3 - rank!.division]}` : ''}
                    </span>
                  )}
                </div>
              ) : (
                <div className="mt-1 text-sm text-gray-400">You're not in a clan yet</div>
              )}
            </div>

            {/* Quick rankings link */}
            <button
              onClick={() => navigate('/leaderboard')}
              className="flex flex-col items-center gap-1 p-3 rounded-2xl bg-gray-50 border border-gray-100 active:scale-95 transition-transform"
            >
              <Trophy size={20} className="text-amber-500" />
              <span className="text-[10px] font-bold text-gray-500 uppercase tracking-wider">Ranks</span>
            </button>
          </div>

          {/* PRIMARY ACTION */}
          <motion.button
            whileTap={{ scale: 0.98 }}
            onClick={() => isLeader ? navigate('/create-match') : navigate('/clans')}
            className="mt-4 w-full h-14 rounded-2xl bg-gradient-to-r from-emerald-500 to-blue-600 text-white font-black text-base tracking-wide flex items-center justify-center gap-2 shadow-lg shadow-emerald-500/25"
          >
            <Zap size={20} fill="white" />
            {myClan
              ? isLeader ? 'Challenge a Clan' : 'View My Clan'
              : 'Find a Clan'}
          </motion.button>

          {!isLeader && myClan && (
            <p className="mt-2 text-center text-xs text-gray-400">
              Only your clan leader can create matches
            </p>
          )}
        </motion.div>

        {/* ACTIVITY FEED */}
        <div>
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-xs font-black uppercase tracking-widest text-gray-500">Activity</h2>
            <button
              onClick={() => navigate('/fixtures')}
              className="text-xs font-bold text-emerald-600 flex items-center gap-0.5"
            >
              See all <ChevronRight size={14} />
            </button>
          </div>

          <div className="bg-white rounded-3xl border border-gray-100 shadow-sm overflow-hidden divide-y divide-gray-50">
            {feed.map((fixture, i) => {
              const homeClan = MOCK_CLANS.find(c => c.id === fixture.homeClanId);
              const awayClan = fixture.awayClanId ? MOCK_CLANS.find(c => c.id === fixture.awayClanId) : undefined;
              if (!homeClan) return null;

              const isLive = fixture.status === FixtureStatus.LIVE;
              const isFinal = fixture.status === FixtureStatus.FINAL;
              const isOpen = fixture.status === FixtureStatus.OPEN;

              return (
                <motion.button
                  key={fixture.id}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ delay: 0.04 * i }}
                  whileTap={{ backgroundColor: '#f9fafb' }}
                  onClick={() => navigate(`/fixtures/${fixture.id}`)}
                  className="w-full flex items-center gap-3 px-4 py-3.5 text-left"
                >
                  {/* Status indicator */}
                  <div className="shrink-0 flex flex-col items-center gap-1 w-8">
                    {isLive ? (
                      <>
                        <motion.div
                          className="w-2 h-2 rounded-full bg-orange-500"
                          animate={{ opacity: [1, 0.2, 1] }}
                          transition={{ duration: 1.2, repeat: Infinity }}
                        />
                        <span className="text-[9px] font-black uppercase text-orange-500 tracking-wider">Live</span>
                      </>
                    ) : isFinal ? (
                      <>
                        <div className="w-2 h-2 rounded-full bg-gray-300" />
                        <span className="text-[9px] font-black uppercase text-gray-400 tracking-wider">FT</span>
                      </>
                    ) : isOpen ? (
                      <>
                        <Users size={13} className="text-blue-500" />
                        <span className="text-[9px] font-black uppercase text-blue-500 tracking-wider">Open</span>
                      </>
                    ) : (
                      <>
                        <Radio size={13} className="text-emerald-500" />
                        <span className="text-[9px] font-black uppercase text-emerald-600 tracking-wider">Up</span>
                      </>
                    )}
                  </div>

                  {/* Match */}
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-1.5 font-bold text-sm text-gray-900">
                      <span>{homeClan.emblem}</span>
                      <span className="truncate">{homeClan.tag}</span>
                      {isFinal ? (
                        <span className="font-black text-gray-700 mx-0.5">
                          {fixture.homeScore}–{fixture.awayScore}
                        </span>
                      ) : (
                        <span className="text-gray-400 font-normal text-xs mx-0.5">vs</span>
                      )}
                      {awayClan ? (
                        <>
                          <span className="truncate">{awayClan.tag}</span>
                          <span>{awayClan.emblem}</span>
                        </>
                      ) : (
                        <span className="text-gray-400 font-normal text-xs italic">TBD</span>
                      )}
                    </div>
                    <div className="flex items-center gap-2 mt-0.5 text-xs text-gray-400">
                      <MapPin size={11} />
                      <span className="truncate">{fixture.venue}</span>
                      <Clock size={11} />
                      <span className="shrink-0">{fixture.timeSlot.split(' – ')[0]}</span>
                    </div>
                  </div>

                  <ChevronRight size={15} className="text-gray-300 shrink-0" />
                </motion.button>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}
