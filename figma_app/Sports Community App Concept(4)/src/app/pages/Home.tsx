import { PageHeader } from '@/app/components/layout/PageHeader';
import { MOCK_CLANS, MOCK_FIXTURES } from '@/app/lib/data/mockData';
import { getCurrentPlayer } from '@/app/lib/social';
import { getRankFromRating, formatRank } from '@/app/lib/constants/tiers';
import { FixtureStatus } from '@/app/lib/types';
import {
  getBooking,
  getQueueMatch,
  playerTierLabel,
  roleLabel,
} from '@/app/lib/openQueue';
import {
  Zap,
  MapPin,
  Clock,
  Radio,
  Users,
  ChevronRight,
  Trophy,
  CheckCircle2,
  TrendingUp,
} from 'lucide-react';
import { motion } from 'motion/react';
import { useNavigate } from 'react-router';

export default function Home() {
  const navigate = useNavigate();
  const currentPlayer = getCurrentPlayer();
  const myClan = MOCK_CLANS.find(c => c.id === currentPlayer.clanId);
  const rank = myClan ? getRankFromRating(myClan.skillRating) : null;

  const firstName = currentPlayer.name.split(' ')[0];
  const playerRating = currentPlayer.playerRating ?? 1200;
  const tier = playerTierLabel(playerRating);

  const booking = getBooking();
  const bookedMatch = booking ? getQueueMatch(booking.matchId) : undefined;

  // Recruiting clans for free agents (mock: clans with a spare roster slot).
  const recruitingCount = 6;

  // Activity feed: live first, then upcoming/open, then finals.
  const feed = [...MOCK_FIXTURES]
    .sort((a, b) => {
      const order = { LIVE: 0, SCHEDULED: 1, OPEN: 2, FINAL: 3 };
      return order[a.status] - order[b.status];
    })
    .slice(0, 4);

  return (
    <div className="min-h-screen bg-gray-50">
      <PageHeader brand title="Field" />

      <div className="p-4 space-y-5">
        {/* PLAYER IDENTITY + PLAYER RATING */}
        <motion.button
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.3 }}
          whileTap={{ scale: 0.99 }}
          onClick={() => navigate('/profile')}
          className="relative w-full text-left overflow-hidden rounded-3xl bg-white border border-gray-100 shadow-sm p-5"
        >
          {/* Soft tier glow */}
          <motion.div
            className="absolute -top-10 -left-10 w-40 h-40 rounded-full bg-amber-300 opacity-20 blur-3xl"
            animate={{ opacity: [0.12, 0.24, 0.12] }}
            transition={{ duration: 5, repeat: Infinity, ease: 'easeInOut' }}
          />
          <div className="relative flex items-center gap-4">
            {/* Avatar with tier ring */}
            <div className="relative shrink-0">
              <div className="absolute -inset-1 rounded-2xl bg-gradient-to-br from-amber-400 via-yellow-300 to-amber-500 blur-[2px] opacity-70" />
              <img
                src={currentPlayer.avatar}
                alt={currentPlayer.name}
                className="relative w-14 h-14 rounded-2xl object-cover ring-2 ring-white"
              />
              <div className="absolute -bottom-1.5 -right-1.5 px-1.5 py-0.5 rounded-md bg-gray-900 text-[8px] font-black text-amber-300 uppercase tracking-wide shadow">
                {tier}
              </div>
            </div>

            <div className="min-w-0 flex-1">
              <div className="text-[10px] font-black uppercase tracking-widest text-emerald-600">
                Player Rating
              </div>
              <div className="flex items-baseline gap-2">
                <span className="text-3xl font-black text-gray-900 tabular-nums">
                  {playerRating.toLocaleString()}
                </span>
                <span className="flex items-center gap-0.5 text-[11px] font-black text-emerald-600">
                  <TrendingUp size={12} /> +18
                </span>
              </div>
              <div className="text-xs font-semibold text-gray-500 truncate">
                #{currentPlayer.regionRank} in {currentPlayer.region}
              </div>
            </div>

            <div className="flex flex-col items-center gap-1 shrink-0">
              <div className="w-10 h-10 rounded-2xl bg-gradient-to-br from-amber-400 to-orange-500 flex items-center justify-center shadow-lg shadow-amber-500/30">
                <Trophy size={18} className="text-white" />
              </div>
              <span className="text-[9px] font-bold text-gray-400 uppercase tracking-wider">
                Ranks
              </span>
            </div>
          </div>

          {/* Progress to next tier */}
          <div className="relative mt-4">
            <div className="flex items-center justify-between text-[10px] font-bold text-gray-400 mb-1">
              <span>{tier}</span>
              <span>Next tier · 72 to go</span>
            </div>
            <div className="h-1.5 rounded-full bg-gray-100 overflow-hidden">
              <motion.div
                className="h-full rounded-full bg-gradient-to-r from-amber-400 to-emerald-500"
                initial={{ width: 0 }}
                animate={{ width: '78%' }}
                transition={{ duration: 0.8, ease: 'easeOut' }}
              />
            </div>
          </div>
        </motion.button>

        {/* MATCH CONFIRMED banner (if booked) OR FIND A GAME hero */}
        {booking && bookedMatch ? (
          <motion.button
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.3, delay: 0.05 }}
            whileTap={{ scale: 0.98 }}
            onClick={() => navigate(`/queue/success/${bookedMatch.id}`)}
            className="w-full text-left relative overflow-hidden rounded-3xl bg-[radial-gradient(120%_120%_at_0%_0%,#10b981_0%,#059669_45%,#0b3d2e_100%)] text-white shadow-2xl shadow-emerald-500/40 p-6"
          >
            <div className="flex items-center gap-2 mb-3">
              <CheckCircle2 size={18} />
              <span className="text-[10px] font-black uppercase tracking-[0.2em] text-emerald-100">
                Match Confirmed
              </span>
            </div>
            <h2 className="text-2xl font-black tracking-tight uppercase leading-tight">
              {roleLabel(booking.role)} · {bookedMatch.startTime}
            </h2>
            <div className="mt-2 flex items-center gap-1.5 text-sm text-white/85">
              <MapPin size={14} />
              <span>{bookedMatch.venue}</span>
              <span className="opacity-60">·</span>
              <span>{bookedMatch.dateGroup === 'TODAY' ? 'Today' : bookedMatch.dateGroup}</span>
            </div>
            <div className="mt-4 inline-flex items-center gap-1 rounded-full bg-white/15 backdrop-blur px-3 py-1.5 text-xs font-bold">
              View booking <ChevronRight size={14} />
            </div>
          </motion.button>
        ) : (
          <motion.section
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.3, delay: 0.05 }}
            className="relative overflow-hidden rounded-3xl bg-[radial-gradient(130%_130%_at_100%_0%,#159f72_0%,#047857_45%,#07352a_100%)] p-6 text-white shadow-xl shadow-emerald-950/20"
          >
            <motion.div
              className="absolute -right-16 -top-16 h-56 w-56 rounded-full bg-emerald-300/25 blur-3xl"
              animate={{ scale: [1, 1.18, 1], opacity: [0.2, 0.38, 0.2] }}
              transition={{ duration: 6, repeat: Infinity, ease: 'easeInOut' }}
            />
            <svg className="pointer-events-none absolute inset-0 h-full w-full opacity-60" viewBox="0 0 400 260" preserveAspectRatio="none" aria-hidden>
              <line x1="200" y1="-10" x2="200" y2="270" stroke="rgba(255,255,255,0.18)" strokeWidth="1.5" />
              <circle cx="200" cy="130" r="52" fill="none" stroke="rgba(255,255,255,0.18)" strokeWidth="1.5" />
            </svg>
            <div className="relative text-center">
              <div className="mb-2 flex items-center justify-center gap-2 text-emerald-100">
                <motion.span className="h-1.5 w-1.5 rounded-full bg-lime-300" animate={{ opacity: [1, 0.35, 1] }} transition={{ duration: 1.4, repeat: Infinity }} />
                <span className="text-[10px] font-black uppercase tracking-[0.2em]">Ranked Open Queue · Live</span>
              </div>
              <h2 className="text-3xl font-black uppercase leading-[1.05]">Ready for a match?</h2>
              <p className="mx-auto mt-2 max-w-[17rem] text-sm leading-5 text-emerald-50">Choose your position, see balanced 6-a-side games, then book your spot.</p>

              <motion.button
                whileTap={{ scale: 0.97 }}
                animate={{ scale: [1, 1.025, 1] }}
                transition={{ duration: 2.2, repeat: Infinity, ease: 'easeInOut' }}
                onClick={() => navigate('/queue')}
                className="mt-6 flex h-16 w-full items-center justify-center gap-3 rounded-2xl bg-white text-base font-black uppercase tracking-[0.08em] text-emerald-800 shadow-xl shadow-emerald-950/30 ring-4 ring-white/15 transition-colors hover:bg-emerald-50"
              >
                <span className="flex h-8 w-8 items-center justify-center rounded-full bg-emerald-600 text-white"><Zap size={17} fill="currentColor" /></span>
                Find a game
                <ChevronRight size={20} strokeWidth={3} />
              </motion.button>

              <div className="mt-4 flex items-center justify-center gap-2 text-xs font-bold text-emerald-100">
                <span className="flex -space-x-1.5">{[0, 1, 2].map((n) => <span key={n} className="h-4 w-4 rounded-full bg-emerald-200 ring-2 ring-emerald-800" />)}</span>
                38 players are looking now
              </div>
            </div>
          </motion.section>
        )}

        {/* YOUR CLAN or FIND YOUR CLAN */}
        {myClan ? (
          <div>
            <h2 className="text-xs font-black uppercase tracking-widest text-gray-500 mb-3">
              Your Clan
            </h2>
            <div className="bg-white rounded-3xl border border-gray-100 shadow-sm p-5">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="w-11 h-11 rounded-2xl bg-gray-50 border border-gray-100 flex items-center justify-center text-xl">
                    {myClan.emblem}
                  </div>
                  <div>
                    <div className="font-black text-gray-900">{myClan.name}</div>
                    <div className="text-xs font-semibold text-gray-500">
                      <span className="text-[10px] font-black uppercase tracking-wider text-blue-600">
                        Clan Rating
                      </span>{' '}
                      {myClan.skillRating.toLocaleString()} · #{myClan.regionRank}{' '}
                      {myClan.region}
                    </div>
                  </div>
                </div>
                {rank && (
                  <span className="text-xs font-black text-emerald-700 bg-emerald-50 px-2.5 py-1 rounded-full">
                    {formatRank(rank)}
                  </span>
                )}
              </div>

              <div className="mt-4 flex items-center gap-2 rounded-2xl bg-gray-50 border border-gray-100 px-3 py-2.5">
                <Radio size={14} className="text-emerald-500" />
                <span className="text-xs font-semibold text-gray-600">
                  Next fixture · vs PHX · Tue 6:30 PM
                </span>
              </div>

              <button
                onClick={() => navigate(`/clans/${myClan.id}`)}
                className="mt-3 w-full h-11 rounded-2xl bg-gray-900 text-white font-bold text-sm active:scale-[0.98] transition-transform"
              >
                View Clan
              </button>
            </div>
          </div>
        ) : (
          <div>
            <h2 className="text-xs font-black uppercase tracking-widest text-gray-500 mb-3">
              Find Your Clan
            </h2>
            <button
              onClick={() => navigate('/clans')}
              className="w-full text-left bg-white rounded-3xl border border-gray-100 shadow-sm p-5 flex items-center justify-between active:scale-[0.99] transition-transform"
            >
              <div className="flex items-center gap-3">
                <div className="w-11 h-11 rounded-2xl bg-blue-50 flex items-center justify-center">
                  <Users size={20} className="text-blue-600" />
                </div>
                <div>
                  <div className="font-black text-gray-900">Join a Clan</div>
                  <div className="text-xs font-semibold text-gray-500">
                    {recruitingCount} clans are currently recruiting
                  </div>
                </div>
              </div>
              <ChevronRight size={18} className="text-gray-300" />
            </button>
          </div>
        )}

        {/* ACTIVITY FEED */}
        <div>
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-xs font-black uppercase tracking-widest text-gray-500">
              Activity
            </h2>
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
              const awayClan = fixture.awayClanId
                ? MOCK_CLANS.find(c => c.id === fixture.awayClanId)
                : undefined;
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
                  <div className="shrink-0 flex flex-col items-center gap-1 w-8">
                    {isLive ? (
                      <>
                        <motion.div
                          className="w-2 h-2 rounded-full bg-orange-500"
                          animate={{ opacity: [1, 0.2, 1] }}
                          transition={{ duration: 1.2, repeat: Infinity }}
                        />
                        <span className="text-[9px] font-black uppercase text-orange-500 tracking-wider">
                          Live
                        </span>
                      </>
                    ) : isFinal ? (
                      <>
                        <div className="w-2 h-2 rounded-full bg-gray-300" />
                        <span className="text-[9px] font-black uppercase text-gray-400 tracking-wider">
                          FT
                        </span>
                      </>
                    ) : isOpen ? (
                      <>
                        <Users size={13} className="text-blue-500" />
                        <span className="text-[9px] font-black uppercase text-blue-500 tracking-wider">
                          Open
                        </span>
                      </>
                    ) : (
                      <>
                        <Radio size={13} className="text-emerald-500" />
                        <span className="text-[9px] font-black uppercase text-emerald-600 tracking-wider">
                          Up
                        </span>
                      </>
                    )}
                  </div>

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
                      <span className="shrink-0">{fixture.timeSlot.split(' - ')[0]}</span>
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
