import { PageHeader, HeaderActionButton } from '@/app/components/layout/PageHeader';
import { TierBadge } from '@/app/components/layout/TierBadge';
import { MOCK_PLAYERS, MOCK_CLANS, MOCK_FIXTURES } from '@/app/lib/data/mockData';
import { getRankFromRating, getDivisionBounds, TIER_CONFIGS, TIER_BACKGROUNDS } from '@/app/lib/constants/tiers';
import { FixtureStatus, Tier } from '@/app/lib/types';
import {
  Settings, Share2, Flame, Trophy, Target, Goal,
  Zap, Crown, Shield, Star, Sparkles, TrendingUp,
} from 'lucide-react';
import { motion } from 'motion/react';
import { useMemo } from 'react';
import {
  AreaChart, Area, ResponsiveContainer, Tooltip, XAxis, YAxis,
} from 'recharts';

export default function Profile() {
  const currentPlayer = MOCK_PLAYERS[0];
  const myClan = MOCK_CLANS.find(c => c.id === currentPlayer.clanId);
  const rank = myClan ? getRankFromRating(myClan.skillRating) : null;
  const tier = rank?.tier ?? null;
  const division = rank?.division;
  const tierConfig = tier ? TIER_CONFIGS[tier] : null;
  const isMaxTier = tier === Tier.CHAMPION;
  const divBounds = rank ? getDivisionBounds(rank) : null;

  const srProgress = divBounds && myClan
    ? isMaxTier
      ? 100
      : ((myClan.skillRating - divBounds.min) / (divBounds.max + 1 - divBounds.min)) * 100
    : 0;
  const srToNext = divBounds && myClan && !isMaxTier ? (divBounds.max + 1) - myClan.skillRating : 0;

  // Derive recent form for this player's clan
  const myClanFixtures = MOCK_FIXTURES
    .filter(f => f.status === FixtureStatus.FINAL && (f.homeClanId === myClan?.id || f.awayClanId === myClan?.id))
    .sort((a, b) => (a.date < b.date ? 1 : -1));

  const recentForm = myClanFixtures.slice(0, 5).map(f => {
    const isHome = f.homeClanId === myClan?.id;
    const myScore = isHome ? f.homeScore! : f.awayScore!;
    const oppScore = isHome ? f.awayScore! : f.homeScore!;
    if (myScore > oppScore) return 'W';
    if (myScore < oppScore) return 'L';
    return 'D';
  });

  // Personal goals, assists, appearances across FINAL fixtures
  const finals = MOCK_FIXTURES.filter(f => f.status === FixtureStatus.FINAL);
  const goalsScored = finals
    .flatMap(f => f.scorers ?? [])
    .filter(s => s.playerId === currentPlayer.id).length;
  const assistsMade = finals
    .flatMap(f => f.scorers ?? [])
    .filter(s => s.assistPlayerId === currentPlayer.id).length;
  const appearances = finals.filter(
    f => f.homeClanId === myClan?.id || f.awayClanId === myClan?.id
  ).length;

  // Build a fake SR history series ending at current rating
  const srSeries = useMemo(() => {
    const base = myClan?.skillRating ?? 1500;
    const offsets = [-180, -120, -90, -40, -55, 10, -20, 35, 60, 0];
    return offsets.map((o, i) => ({ x: i, sr: base + o }));
  }, [myClan?.skillRating]);

  const winRate = myClan && (myClan.wins + myClan.losses) > 0
    ? Math.round((myClan.wins / (myClan.wins + myClan.losses)) * 100)
    : 0;

  const achievements = [
    { id: 'firstWin', label: 'First Win', icon: Trophy, unlocked: (myClan?.wins ?? 0) >= 1, gradient: 'from-emerald-500 to-blue-600' },
    { id: 'hatTrick', label: 'Hat-Trick', icon: Goal, unlocked: goalsScored >= 3, gradient: 'from-orange-500 to-pink-600' },
    { id: 'unstoppable', label: '5-Streak', icon: Flame, unlocked: (myClan?.wins ?? 0) >= 5, gradient: 'from-red-500 to-amber-500' },
    { id: 'climber', label: 'Top 10', icon: TrendingUp, unlocked: true, gradient: 'from-cyan-400 to-blue-600' },
    { id: 'legend', label: 'Champion', icon: Crown, unlocked: tier === Tier.CHAMPION, gradient: 'from-violet-500 to-fuchsia-600' },
    { id: 'sharpshooter', label: 'Sharpshooter', icon: Target, unlocked: goalsScored >= 1, gradient: 'from-yellow-400 to-orange-500' },
  ];

  const teammates = myClan
    ? MOCK_PLAYERS.filter(p => myClan.memberIds.includes(p.id) && p.id !== currentPlayer.id)
    : [];

  return (
    <div className="min-h-screen bg-gradient-to-b from-violet-50/70 via-white to-gray-50">
      <PageHeader
        title="Profile"
        rightAction={
          <div className="flex items-center gap-2">
            <HeaderActionButton icon={<Share2 size={16} strokeWidth={2.5} />} variant="violet" />
            <HeaderActionButton icon={<Settings size={18} strokeWidth={2.5} />} variant="violet" />
          </div>
        }
      />

      <div className="p-4 space-y-6">
        {/* IDENTITY HERO — avatar with rotating tier ring */}
        <motion.div
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.4 }}
          className={`relative overflow-hidden rounded-3xl ${tier ? TIER_BACKGROUNDS[tier] : 'bg-[radial-gradient(120%_120%_at_0%_0%,#a78bfa_0%,#7c3aed_40%,#1e1b4b_100%)]'} text-white shadow-2xl ${tierConfig?.glowColor ?? 'shadow-violet-500/40'} p-6`}
        >
          {/* Glow */}
          <motion.div
            className="absolute -top-20 -right-20 w-64 h-64 rounded-full bg-fuchsia-300 opacity-25 blur-3xl"
            animate={{ scale: [1, 1.15, 1] }}
            transition={{ duration: 6, repeat: Infinity, ease: 'easeInOut' }}
          />

          <div className="relative flex items-center gap-5">
            {/* Avatar with animated tier ring */}
            <div className="relative w-24 h-24 shrink-0">
              <motion.div
                className={`absolute inset-0 rounded-full bg-gradient-to-tr ${tierConfig?.gradient ?? 'from-emerald-400 to-blue-600'}`}
                animate={{ rotate: 360 }}
                transition={{ duration: 12, repeat: Infinity, ease: 'linear' }}
                style={{ padding: 3 }}
              >
                <div className="w-full h-full rounded-full bg-violet-900/60 backdrop-blur-sm" />
              </motion.div>
              <div className="absolute inset-[3px] rounded-full bg-gradient-to-br from-white/25 to-white/5 backdrop-blur flex items-center justify-center text-4xl font-black">
                {currentPlayer.name.split(' ').map(n => n[0]).join('').slice(0, 2)}
              </div>
              {tier && (
                <div className="absolute -bottom-1 -right-1">
                  <TierBadge tier={tier} division={division} size="sm" showLabel={false} />
                </div>
              )}
            </div>

            <div className="min-w-0 flex-1">
              <div className="text-[10px] font-black uppercase tracking-[0.2em] text-violet-200 mb-1">
                @{currentPlayer.username}
              </div>
              <h2 className="text-2xl font-black tracking-tight leading-tight">{currentPlayer.name}</h2>
              {myClan && (
                <div className="mt-1.5 inline-flex items-center gap-1.5 text-xs">
                  <span className="text-base">{myClan.emblem}</span>
                  <span className="font-bold text-violet-100">{myClan.name}</span>
                  <span className="px-1.5 py-0.5 rounded-md bg-white/15 text-[10px] font-black tracking-wider">
                    {myClan.tag}
                  </span>
                </div>
              )}
            </div>
          </div>

          {/* SR Progress to next tier */}
          {tierConfig && (
            <div className="relative mt-5">
              <div className="flex items-end justify-between mb-1.5">
                <div>
                  <div className="text-[10px] font-black uppercase tracking-widest text-violet-200">Skill Rating</div>
                  <div className="text-3xl font-black leading-none mt-0.5">{myClan!.skillRating}</div>
                </div>
                <div className="text-right">
                  {!isMaxTier ? (
                    <>
                      <div className="text-[10px] font-bold uppercase tracking-wider text-white/70">Next division</div>
                      <div className="text-sm font-black">{srToNext} SR</div>
                    </>
                  ) : (
                    <div className="inline-flex items-center gap-1 text-yellow-300 font-black">
                      <Crown size={14} /> MAX TIER
                    </div>
                  )}
                </div>
              </div>
              <div className="h-2.5 rounded-full bg-white/15 overflow-hidden">
                <motion.div
                  initial={{ width: 0 }}
                  animate={{ width: `${srProgress}%` }}
                  transition={{ duration: 0.9, ease: 'easeOut' }}
                  className={`h-full bg-gradient-to-r ${tierConfig.gradient} shadow-[0_0_12px_rgba(255,255,255,0.4)]`}
                />
              </div>
            </div>
          )}
        </motion.div>

        {/* PRIMARY STATS — career numbers */}
        <div className="grid grid-cols-3 gap-2">
          <BigStatTile icon={<Shield size={18} />} value={appearances} label="Apps" accent="from-emerald-500 to-blue-600" />
          <BigStatTile icon={<Goal size={18} />} value={goalsScored} label="Goals" accent="from-orange-500 to-pink-600" />
          <BigStatTile icon={<Sparkles size={18} />} value={assistsMade} label="Assists" accent="from-blue-500 to-violet-600" />
        </div>

        {/* SECONDARY STATS — clan record */}
        <div className="grid grid-cols-3 gap-2">
          <StatTile icon={<Trophy size={14} />} value={myClan?.wins ?? 0} label="Wins" accent="text-emerald-600" />
          <StatTile icon={<Shield size={14} />} value={myClan?.losses ?? 0} label="Losses" accent="text-red-500" />
          <StatTile icon={<Sparkles size={14} />} value={`${winRate}%`} label="Win %" accent="text-violet-600" />
        </div>

        {/* RECENT FORM */}
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm p-5">
          <div className="flex items-center justify-between mb-3">
            <SectionLabel icon={<Flame size={14} className="text-orange-500" />} label="Recent Form" />
            <span className="text-[10px] font-black uppercase tracking-wider text-gray-400">Last 5</span>
          </div>
          <div className="flex items-center gap-1.5">
            {recentForm.length > 0 ? recentForm.map((r, i) => (
              <motion.div
                key={i}
                initial={{ scale: 0, opacity: 0 }}
                animate={{ scale: 1, opacity: 1 }}
                transition={{ delay: 0.05 * i, type: 'spring', stiffness: 220, damping: 14 }}
                className={`flex-1 h-10 rounded-lg flex items-center justify-center font-black text-sm shadow-sm ${
                  r === 'W'
                    ? 'bg-gradient-to-br from-emerald-400 to-emerald-600 text-white'
                    : r === 'L'
                    ? 'bg-gradient-to-br from-red-400 to-red-600 text-white'
                    : 'bg-gradient-to-br from-gray-300 to-gray-400 text-white'
                }`}
              >
                {r}
              </motion.div>
            )) : (
              <div className="text-xs text-gray-400 italic">No matches played yet.</div>
            )}
          </div>
        </div>

        {/* SR TREND SPARKLINE */}
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm p-5">
          <div className="flex items-center justify-between mb-2">
            <SectionLabel icon={<TrendingUp size={14} className="text-blue-600" />} label="SR Trend" />
            <div className="text-[10px] font-black uppercase tracking-wider text-emerald-600">
              +{srSeries[srSeries.length - 1].sr - srSeries[0].sr} this month
            </div>
          </div>
          <div className="h-24 -mx-2">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={srSeries} margin={{ top: 4, left: 0, right: 0, bottom: 0 }}>
                <defs>
                  <linearGradient id="srFill" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#3b82f6" stopOpacity={0.45} />
                    <stop offset="100%" stopColor="#3b82f6" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <XAxis hide dataKey="x" type="number" domain={['dataMin', 'dataMax']} />
                <YAxis hide domain={['dataMin - 30', 'dataMax + 30']} />
                <Tooltip
                  cursor={{ stroke: '#3b82f6', strokeOpacity: 0.2 }}
                  contentStyle={{
                    borderRadius: 12,
                    border: 'none',
                    boxShadow: '0 10px 25px rgba(0,0,0,0.08)',
                    fontSize: 12,
                    fontWeight: 700,
                  }}
                  labelFormatter={() => ''}
                  formatter={(v: number) => [`${v} SR`, '']}
                />
                <Area
                  type="monotone"
                  dataKey="sr"
                  stroke="#3b82f6"
                  strokeWidth={2.5}
                  fill="url(#srFill)"
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        </div>

        {/* ACHIEVEMENTS */}
        <div>
          <SectionLabel icon={<Star size={14} className="text-amber-500" />} label="Achievements" />
          <div className="mt-3 grid grid-cols-3 gap-2.5">
            {achievements.map((a, i) => {
              const Icon = a.icon;
              return (
                <motion.div
                  key={a.id}
                  initial={{ opacity: 0, y: 8 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ delay: 0.04 * i }}
                  className={`relative rounded-2xl p-3 text-center border ${
                    a.unlocked
                      ? 'bg-white border-gray-100 shadow-sm'
                      : 'bg-gray-50 border-gray-100 opacity-60'
                  }`}
                >
                  <div
                    className={`mx-auto w-11 h-11 rounded-xl flex items-center justify-center mb-1.5 ${
                      a.unlocked
                        ? `bg-gradient-to-br ${a.gradient} shadow-md`
                        : 'bg-gray-200'
                    }`}
                  >
                    <Icon size={20} className={a.unlocked ? 'text-white' : 'text-gray-400'} />
                  </div>
                  <div className={`text-[10px] font-black uppercase tracking-wide ${a.unlocked ? 'text-gray-800' : 'text-gray-400'}`}>
                    {a.label}
                  </div>
                </motion.div>
              );
            })}
          </div>
        </div>

        {/* SQUAD */}
        {teammates.length > 0 && (
          <div className="bg-white rounded-2xl border border-gray-100 shadow-sm p-5">
            <SectionLabel icon={<Zap size={14} className="text-emerald-600" />} label="The Squad" />
            <div className="mt-3 space-y-2">
              {teammates.map(t => (
                <div key={t.id} className="flex items-center gap-3">
                  <div className="w-10 h-10 rounded-full bg-gradient-to-br from-emerald-400 to-blue-600 flex items-center justify-center text-white font-black text-sm shadow">
                    {t.name.split(' ').map(n => n[0]).join('').slice(0, 2)}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="font-bold text-sm text-gray-900 truncate">{t.name}</div>
                    <div className="text-xs text-gray-500 truncate">@{t.username}</div>
                  </div>
                  {myClan?.ownerId === t.id && (
                    <span className="inline-flex items-center gap-1 text-[10px] font-black uppercase tracking-wider text-amber-600 bg-amber-100 px-2 py-1 rounded-md">
                      <Crown size={10} /> Lead
                    </span>
                  )}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function BigStatTile({
  icon, value, label, accent,
}: { icon: React.ReactNode; value: string | number; label: string; accent: string }) {
  return (
    <div className="relative overflow-hidden bg-white rounded-2xl border border-gray-100 shadow-sm p-4">
      <div className={`absolute top-0 left-0 right-0 h-1 bg-gradient-to-r ${accent}`} />
      <div className={`inline-flex items-center justify-center w-8 h-8 rounded-lg bg-gradient-to-br ${accent} text-white shadow-sm mb-2`}>
        {icon}
      </div>
      <div className="text-2xl font-black text-gray-900 leading-none">{value}</div>
      <div className="text-[10px] font-black uppercase tracking-widest text-gray-500 mt-1">{label}</div>
    </div>
  );
}

function StatTile({
  icon, value, label, accent,
}: { icon: React.ReactNode; value: string | number; label: string; accent: string }) {
  return (
    <div className="bg-white rounded-2xl border border-gray-100 shadow-sm p-3 text-center">
      <div className={`flex items-center justify-center mb-1 ${accent}`}>{icon}</div>
      <div className="text-xl font-black text-gray-900 leading-none">{value}</div>
      <div className="text-[10px] font-bold uppercase tracking-wider text-gray-500 mt-1">{label}</div>
    </div>
  );
}

function SectionLabel({ icon, label }: { icon?: React.ReactNode; label: string }) {
  return (
    <div className="flex items-center gap-2">
      <span className="block w-1 h-5 rounded-full bg-gradient-to-b from-emerald-500 to-blue-600" />
      {icon}
      <h3 className="text-xs font-black uppercase tracking-[0.18em] text-gray-700">{label}</h3>
    </div>
  );
}
