import { useParams, useNavigate } from 'react-router';
import { PageHeader } from '@/app/components/layout/PageHeader';
import { TierBadge } from '@/app/components/layout/TierBadge';
import { MOCK_CLANS, MOCK_PLAYERS, MOCK_FIXTURES } from '@/app/lib/data/mockData';
import { useMemo } from 'react';
import { getRankFromRating, getDivisionBounds } from '@/app/lib/constants/tiers';
import { FixtureStatus } from '@/app/lib/types';
import { Users, Crown, Calendar, ChevronRight, Swords, History, TrendingUp, TrendingDown, Goal, Sparkles, Target } from 'lucide-react';
import { Button } from '@/app/components/ui/button';
import { Badge } from '@/app/components/ui/badge';
import { Avatar, AvatarFallback } from '@/app/components/ui/avatar';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/app/components/ui/tabs';
import { motion, AnimatePresence } from 'motion/react';

export default function ClanDetail() {
  const { clanId } = useParams();
  const navigate = useNavigate();

  const clan = MOCK_CLANS.find(c => c.id === clanId);

  if (!clan) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center">
        <div className="text-center">
          <p className="text-gray-500">Clan not found</p>
          <Button onClick={() => navigate('/clans')} className="mt-4">
            Back to Clans
          </Button>
        </div>
      </div>
    );
  }

  const rank = getRankFromRating(clan.skillRating);
  const { division } = rank;
  const isTopDivision = division === 1;
  const divBounds = getDivisionBounds(rank);

  const srProgress = isTopDivision
    ? 100
    : ((clan.skillRating - divBounds.min) / (divBounds.max + 1 - divBounds.min)) * 100;

  const srToNext = isTopDivision ? 0 : (divBounds.max + 1) - clan.skillRating;

  const members = MOCK_PLAYERS.filter(p => clan.memberIds.includes(p.id));
  const winRate = clan.wins + clan.losses > 0
    ? Math.round((clan.wins / (clan.wins + clan.losses)) * 100)
    : 0;

  // Gather matches
  const clanFixtures = MOCK_FIXTURES.filter(f => f.homeClanId === clan.id || f.awayClanId === clan.id);
  const upcomingFixtures = clanFixtures.filter(f => f.status === FixtureStatus.SCHEDULED || f.status === FixtureStatus.OPEN);
  const pastFixtures = clanFixtures.filter(f => f.status === FixtureStatus.FINAL);

  // Viewer context — is the current user (mock = first player) in this clan?
  const currentPlayer = MOCK_PLAYERS[0];
  const isMember = !!clan.memberIds.includes(currentPlayer.id);
  const isOwner = clan.ownerId === currentPlayer.id;

  // Form (last 5)
  const recentForm = [...pastFixtures]
    .sort((a, b) => (a.date < b.date ? 1 : -1))
    .slice(0, 5)
    .map(f => {
      const isHome = f.homeClanId === clan.id;
      const my = isHome ? f.homeScore! : f.awayScore!;
      const opp = isHome ? f.awayScore! : f.homeScore!;
      return my > opp ? 'W' : my < opp ? 'L' : 'D';
    });

  // Goals for / against
  const { goalsFor, goalsAgainst } = pastFixtures.reduce(
    (acc, f) => {
      const isHome = f.homeClanId === clan.id;
      acc.goalsFor += isHome ? (f.homeScore ?? 0) : (f.awayScore ?? 0);
      acc.goalsAgainst += isHome ? (f.awayScore ?? 0) : (f.homeScore ?? 0);
      return acc;
    },
    { goalsFor: 0, goalsAgainst: 0 }
  );
  const goalDiff = goalsFor - goalsAgainst;

  // Top scorer & assister inside the clan
  const { topScorer, topAssister } = useMemo(() => {
    const g = new Map<string, number>();
    const a = new Map<string, number>();
    for (const f of pastFixtures) {
      for (const s of f.scorers ?? []) {
        if (s.clanId === clan.id) g.set(s.playerId, (g.get(s.playerId) ?? 0) + 1);
        if (s.assistPlayerId && clan.memberIds.includes(s.assistPlayerId)) {
          a.set(s.assistPlayerId, (a.get(s.assistPlayerId) ?? 0) + 1);
        }
      }
    }
    const peak = (m: Map<string, number>) => {
      const [id, count] = [...m.entries()].sort((x, y) => y[1] - x[1])[0] ?? [];
      const player = id ? MOCK_PLAYERS.find(p => p.id === id) : undefined;
      return player ? { player, count: count! } : undefined;
    };
    return { topScorer: peak(g), topAssister: peak(a) };
  }, [pastFixtures, clan.id, clan.memberIds]);

  // Next match countdown (days until)
  const nextMatch = upcomingFixtures
    .filter(f => f.status === FixtureStatus.SCHEDULED)
    .sort((a, b) => (a.date < b.date ? -1 : 1))[0];
  const daysToNext = nextMatch
    ? Math.max(0, Math.ceil((new Date(nextMatch.date).getTime() - Date.now()) / (1000 * 60 * 60 * 24)))
    : null;

  return (
    <div className="min-h-screen bg-gray-50 pb-40">
      <PageHeader title={clan.name} showBack />

      <div className="p-4 space-y-6">
        {/* Clan Header */}
        <div className="relative overflow-hidden rounded-3xl bg-emerald-800 p-6 text-white shadow-sm">
          {/* Pitch lines watermark */}
          <svg className="absolute inset-0 w-full h-full pointer-events-none" viewBox="0 0 400 240" preserveAspectRatio="none" aria-hidden>
            <line x1="200" y1="-20" x2="200" y2="260" stroke="rgba(255,255,255,0.16)" strokeWidth="1.5" />
            <circle cx="200" cy="120" r="58" fill="none" stroke="rgba(255,255,255,0.16)" strokeWidth="1.5" />
          </svg>

          <div className="relative mb-5">
            {/* Top row: emblem + rank crest (always fits) */}
            <div className="flex items-center justify-between gap-3 mb-3">
              <div className="w-16 h-16 rounded-2xl bg-white/20 backdrop-blur-sm flex items-center justify-center text-4xl border-2 border-white/30 shadow-lg shrink-0">
                {clan.emblem || '⚽'}
              </div>
              <div className="shrink-0">
                <TierBadge division={division} size="lg" showLabel={false} animated />
              </div>
            </div>

            {/* Name — gets its own row, can wrap up to 2 lines */}
            <div className="flex items-start gap-2">
              <h2 className="text-2xl font-black tracking-tight leading-tight break-words flex-1 min-w-0">
                {clan.name}
              </h2>
              <span className="shrink-0 mt-1 text-[10px] font-black uppercase tracking-widest bg-white/20 px-1.5 py-0.5 rounded">
                {clan.tag}
              </span>
            </div>

            {/* Member count — its own line, no chance of overflow */}
            <div className="mt-1.5 inline-flex items-center gap-1.5 text-emerald-50 text-xs">
              <Users size={12} />
              <span>{clan.memberIds.length} {clan.memberIds.length === 1 ? 'member' : 'members'}</span>
            </div>
          </div>

          {/* Form pills */}
          {recentForm.length > 0 && (
            <div className="relative flex items-center gap-2 mb-4">
              <span className="text-[10px] font-black uppercase tracking-widest text-emerald-100 mr-1">Form</span>
              {recentForm.map((r, i) => (
                <span
                  key={i}
                  className={`w-6 h-6 rounded-md flex items-center justify-center text-[10px] font-black shadow ${
                    r === 'W' ? 'bg-emerald-300 text-emerald-900'
                      : r === 'L' ? 'bg-red-300 text-red-900'
                      : 'bg-white/40 text-white'
                  }`}
                >
                  {r}
                </span>
              ))}
            </div>
          )}

          {/* Stats Row */}
          <div className="relative grid grid-cols-4 gap-2">
            <HeroStat value={clan.wins} label="Wins" />
            <HeroStat value={clan.losses} label="Losses" />
            <HeroStat value={`${winRate}%`} label="Win %" />
            <HeroStat
              value={`${goalDiff >= 0 ? '+' : ''}${goalDiff}`}
              label="GD"
              accent={goalDiff > 0 ? 'text-emerald-200' : goalDiff < 0 ? 'text-red-200' : undefined}
            />
          </div>
        </div>

        <Tabs defaultValue="overview" className="w-full">
          <TabsList className="grid w-full grid-cols-2 mb-4 bg-gray-200/60 p-1 rounded-xl">
            <TabsTrigger value="overview" className="rounded-lg data-[state=active]:bg-white data-[state=active]:text-emerald-700 data-[state=active]:shadow-sm font-semibold">
              Overview
            </TabsTrigger>
            <TabsTrigger value="matches" className="rounded-lg data-[state=active]:bg-white data-[state=active]:text-emerald-700 data-[state=active]:shadow-sm font-semibold">
              Matches
            </TabsTrigger>
          </TabsList>

          <TabsContent value="overview" className="outline-none">
            <motion.div 
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              className="space-y-6"
            >
              {/* Rating Progress */}
            <div className="bg-white rounded-xl p-5 border border-gray-100 shadow-sm">
              <div className="flex items-center justify-between mb-4">
                <div>
                  <h3 className="font-bold text-gray-900 text-lg flex items-center gap-2">Division progress</h3>
                  {!isTopDivision ? (
                    <p className="text-sm font-medium text-gray-500 mt-1">
                      <span className="text-emerald-600 font-bold">{srToNext} SR</span> to next division
                    </p>
                  ) : (
                    <p className="text-sm font-medium text-amber-500 mt-1">Division 1 — Top division</p>
                  )}
                </div>
                <div className="text-right flex items-center gap-3">
                  <div className="text-3xl font-black text-gray-900 tracking-tight">{clan.skillRating}</div>
                  <TierBadge division={division} size="sm" />
                </div>
              </div>

              <div className="relative pt-2">
                <div className="flex mb-2 items-center justify-between text-xs font-bold text-gray-400">
                  <span>{divBounds.min}</span>
                  <span>{!isTopDivision ? divBounds.max + 1 : 'TOP'}</span>
                </div>
                <div className="bg-gray-100 rounded-full h-4 overflow-hidden shadow-inner">
                  <div
                    className="h-full bg-gradient-to-r from-emerald-500 to-emerald-700 transition-all duration-1000 ease-out"
                    style={{ width: `${Math.min(srProgress, 100)}%` }}
                  />
                </div>
              </div>
            </div>

            {/* Next Match Countdown */}
            {nextMatch && daysToNext !== null && (() => {
              const opponentId = nextMatch.homeClanId === clan.id ? nextMatch.awayClanId : nextMatch.homeClanId;
              const opponent = MOCK_CLANS.find(c => c.id === opponentId);
              return (
                <div
                  onClick={() => navigate(`/fixtures/${nextMatch.id}`)}
                  className="relative overflow-hidden cursor-pointer bg-gradient-to-br from-indigo-600 via-blue-600 to-cyan-500 rounded-2xl p-5 text-white shadow-lg shadow-blue-500/30 active:scale-[0.99] transition"
                >
                  <div className="absolute -top-10 -right-10 w-32 h-32 rounded-full bg-cyan-300/30 blur-2xl" />
                  <div className="relative flex items-center justify-between">
                    <div>
                      <div className="text-[10px] font-black uppercase tracking-widest text-cyan-100">
                        Next Match
                      </div>
                      <div className="mt-1 flex items-center gap-2">
                        <span className="text-2xl">{opponent?.emblem || '⚽'}</span>
                        <h4 className="font-black text-lg tracking-tight">vs {opponent?.name ?? 'TBD'}</h4>
                      </div>
                      <div className="text-xs text-cyan-100 mt-1 flex items-center gap-1.5">
                        <Calendar size={12} />
                        {nextMatch.date} · {nextMatch.timeSlot}
                      </div>
                    </div>
                    <div className="text-right">
                      <div className="text-4xl font-black leading-none tracking-tight">{daysToNext}</div>
                      <div className="text-[10px] font-black uppercase tracking-widest text-cyan-100 mt-1">
                        {daysToNext === 1 ? 'day' : 'days'}
                      </div>
                    </div>
                  </div>
                </div>
              );
            })()}

            {/* Top Performers */}
            {(topScorer || topAssister) && (
              <div className="grid grid-cols-2 gap-3">
                <TopPerformerCard
                  icon={<Goal size={14} />}
                  label="Top Scorer"
                  player={topScorer?.player.name}
                  value={topScorer ? `${topScorer.count} ${topScorer.count === 1 ? 'goal' : 'goals'}` : '—'}
                  gradient="from-orange-500 to-pink-600"
                />
                <TopPerformerCard
                  icon={<Sparkles size={14} />}
                  label="Top Assister"
                  player={topAssister?.player.name}
                  value={topAssister ? `${topAssister.count} ${topAssister.count === 1 ? 'assist' : 'assists'}` : '—'}
                  gradient="from-blue-500 to-violet-600"
                />
              </div>
            )}

            {/* Goals For / Against */}
            <div className="bg-white rounded-xl p-5 border border-gray-100 shadow-sm">
              <div className="flex items-center gap-2 mb-4">
                <div className="p-2 bg-orange-50 rounded-lg">
                  <Target size={18} className="text-orange-600" />
                </div>
                <h3 className="font-black text-gray-900 text-sm uppercase tracking-[0.18em]">Scoring</h3>
              </div>
              <div className="grid grid-cols-3 gap-3">
                <div className="text-center">
                  <div className="text-2xl font-black text-emerald-600">{goalsFor}</div>
                  <div className="text-[10px] font-bold uppercase tracking-widest text-gray-500 mt-1">For</div>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-black text-red-500">{goalsAgainst}</div>
                  <div className="text-[10px] font-bold uppercase tracking-widest text-gray-500 mt-1">Against</div>
                </div>
                <div className="text-center">
                  <div className={`text-2xl font-black ${goalDiff > 0 ? 'text-emerald-600' : goalDiff < 0 ? 'text-red-500' : 'text-gray-500'}`}>
                    {goalDiff > 0 ? '+' : ''}{goalDiff}
                  </div>
                  <div className="text-[10px] font-bold uppercase tracking-widest text-gray-500 mt-1">Diff</div>
                </div>
              </div>
            </div>

            {/* Members */}
            <div className="bg-white rounded-xl p-5 border border-gray-100 shadow-sm">
              <div className="flex items-center justify-between mb-5">
                <div className="flex items-center gap-2">
                  <div className="p-2 bg-blue-50 rounded-lg">
                    <Users size={20} className="text-blue-600" />
                  </div>
                  <h3 className="font-bold text-gray-900 text-lg">Roster</h3>
                </div>
                <Badge variant="secondary" className="bg-gray-100 text-gray-600 font-bold">
                  {members.length}
                </Badge>
              </div>

              <div className="space-y-4">
                {members.map(member => {
                  const isOwner = member.id === clan.ownerId;

                  return (
                    <div key={member.id} className="flex items-center gap-3 p-2 hover:bg-gray-50 rounded-xl transition-colors">
                      <Avatar className="h-12 w-12 border-2 border-white shadow-sm">
                        <AvatarFallback className="bg-gradient-to-br from-emerald-400 to-blue-500 text-white font-bold text-lg">
                          {member.name.split(' ').map(n => n[0]).join('')}
                        </AvatarFallback>
                      </Avatar>
                      <div className="flex-1">
                        <div className="flex items-center gap-2">
                          <span className="font-bold text-gray-900">{member.name}</span>
                          {isOwner && (
                            <Badge variant="default" className="text-[10px] uppercase tracking-wider bg-gradient-to-r from-amber-400 to-orange-500 border-0 shadow-sm px-1.5 py-0">
                              <Crown size={10} className="mr-1 inline-block -mt-0.5" />
                              Owner
                            </Badge>
                          )}
                        </div>
                        <span className="text-sm text-gray-500 font-medium">@{member.username}</span>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
            </motion.div>
          </TabsContent>

          <TabsContent value="matches" className="outline-none">
            <motion.div 
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              className="space-y-6"
            >
              {/* Upcoming Matches */}
            <div className="bg-white rounded-xl p-5 border border-gray-100 shadow-sm">
              <div className="flex items-center gap-2 mb-4">
                <div className="p-2 bg-emerald-50 rounded-lg">
                  <Swords size={20} className="text-emerald-600" />
                </div>
                <h3 className="font-bold text-gray-900 text-lg">Upcoming</h3>
              </div>

              {upcomingFixtures.length === 0 ? (
                <div className="text-center p-6 border-2 border-dashed border-gray-100 rounded-xl bg-gray-50">
                  <p className="text-gray-500 font-medium text-sm">No upcoming fixtures</p>
                </div>
              ) : (
                <div className="space-y-3">
                  {upcomingFixtures.map(fixture => {
                    const isHome = fixture.homeClanId === clan.id;
                    const opponentId = isHome ? fixture.awayClanId : fixture.homeClanId;
                    const opponent = MOCK_CLANS.find(c => c.id === opponentId);

                    return (
                      <div 
                        key={fixture.id} 
                        onClick={() => navigate(`/fixtures/${fixture.id}`)}
                        className="flex items-center gap-3 p-3 border border-gray-100 rounded-xl bg-gray-50 hover:border-emerald-200 transition-colors cursor-pointer group"
                      >
                        <div className="h-10 w-10 bg-white rounded-full flex items-center justify-center text-xl shadow-sm border border-gray-100">
                          {opponent?.emblem || '⚽'}
                        </div>
                        <div className="flex-1">
                          <div className="flex items-center justify-between">
                            <span className="font-bold text-gray-900 text-sm">vs {opponent?.name || 'TBD'}</span>
                            <span className="text-xs font-bold text-emerald-600 bg-emerald-50 px-2 py-1 rounded-md">
                              {fixture.day.substring(0, 3)}
                            </span>
                          </div>
                          <div className="text-xs text-gray-500 font-medium mt-1 flex items-center gap-1">
                            <Calendar size={12} />
                            {fixture.date} • {fixture.timeSlot}
                          </div>
                        </div>
                        <ChevronRight size={18} className="text-gray-400 group-hover:text-emerald-500 transition-colors" />
                      </div>
                    );
                  })}
                </div>
              )}
            </div>

            {/* Previous Matches */}
            <div className="bg-white rounded-xl p-5 border border-gray-100 shadow-sm">
              <div className="flex items-center gap-2 mb-4">
                <div className="p-2 bg-blue-50 rounded-lg">
                  <History size={20} className="text-blue-600" />
                </div>
                <h3 className="font-bold text-gray-900 text-lg">History</h3>
              </div>

              {pastFixtures.length === 0 ? (
                <div className="text-center p-6 border-2 border-dashed border-gray-100 rounded-xl bg-gray-50">
                  <p className="text-gray-500 font-medium text-sm">No past matches yet</p>
                </div>
              ) : (
                <div className="space-y-3">
                  {pastFixtures.map(fixture => {
                    const isHome = fixture.homeClanId === clan.id;
                    const opponentId = isHome ? fixture.awayClanId : fixture.homeClanId;
                    const opponent = MOCK_CLANS.find(c => c.id === opponentId);
                    
                    const myScore = isHome ? fixture.homeScore : fixture.awayScore;
                    const opponentScore = isHome ? fixture.awayScore : fixture.homeScore;
                    
                    const isWin = myScore !== undefined && opponentScore !== undefined && myScore > opponentScore;
                    const isDraw = myScore !== undefined && opponentScore !== undefined && myScore === opponentScore;
                    
                    const srChange = isHome ? fixture.homeSrChange : fixture.awaySrChange;
                    const isPositiveSr = srChange && srChange > 0;

                    return (
                      <div 
                        key={fixture.id} 
                        onClick={() => navigate(`/fixtures/${fixture.id}`)}
                        className="flex flex-col p-3 border border-gray-100 rounded-xl hover:shadow-md transition-shadow bg-white cursor-pointer group"
                      >
                        <div className="flex items-center justify-between mb-2">
                          <span className="text-xs font-bold text-gray-400">{fixture.date}</span>
                          <Badge variant="outline" className={`text-[10px] uppercase font-bold border-0 ${
                            isWin ? 'bg-emerald-50 text-emerald-600' : 
                            isDraw ? 'bg-gray-100 text-gray-600' : 'bg-red-50 text-red-600'
                          }`}>
                            {isWin ? 'Victory' : isDraw ? 'Draw' : 'Defeat'}
                          </Badge>
                        </div>
                        
                        <div className="flex items-center justify-between">
                          <div className="flex items-center gap-2">
                            <div className="h-8 w-8 bg-gray-50 rounded-full flex items-center justify-center text-lg border border-gray-100">
                              {clan.emblem}
                            </div>
                            <span className={`font-black text-lg ${isWin ? 'text-gray-900' : 'text-gray-500'}`}>
                              {myScore}
                            </span>
                          </div>
                          
                          <div className="text-gray-300 font-black text-sm px-2">-</div>
                          
                          <div className="flex items-center gap-2">
                            <span className={`font-black text-lg ${!isWin && !isDraw ? 'text-gray-900' : 'text-gray-500'}`}>
                              {opponentScore}
                            </span>
                            <div className="h-8 w-8 bg-gray-50 rounded-full flex items-center justify-center text-lg border border-gray-100">
                              {opponent?.emblem || '⚽'}
                            </div>
                          </div>
                        </div>

                        {srChange !== undefined && (
                          <div className="mt-3 pt-2 border-t border-gray-50 flex items-center justify-between">
                            <span className="text-xs font-medium text-gray-500">Rating Change</span>
                            <div className={`flex items-center gap-1 text-sm font-bold ${
                              isPositiveSr ? 'text-emerald-600' : srChange === 0 ? 'text-gray-500' : 'text-red-500'
                            }`}>
                              {isPositiveSr ? <TrendingUp size={14} /> : srChange !== 0 ? <TrendingDown size={14} /> : null}
                              {isPositiveSr ? '+' : ''}{srChange} SR
                            </div>
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
            </motion.div>
          </TabsContent>
        </Tabs>
        
        {/* Actions - Sticky bottom on mobile */}
        <div className="fixed bottom-16 left-0 right-0 p-4 bg-white/80 backdrop-blur-md border-t border-gray-200 z-40">
          {isOwner ? (
            <Button
              onClick={() => navigate('/create-match')}
              className="w-full bg-gradient-to-r from-emerald-600 to-emerald-500 hover:from-emerald-700 hover:to-emerald-600 text-white font-black uppercase tracking-wider py-6 text-base shadow-lg shadow-emerald-500/30 rounded-xl flex items-center justify-center gap-2"
            >
              <Swords size={18} /> Schedule a Match
            </Button>
          ) : isMember ? (
            <Button
              variant="outline"
              className="w-full border-2 border-gray-200 text-gray-700 font-black uppercase tracking-wider py-6 text-base rounded-xl"
            >
              Leave Clan
            </Button>
          ) : (
            <Button className="w-full bg-gradient-to-r from-emerald-600 to-emerald-500 hover:from-emerald-700 hover:to-emerald-600 text-white font-black uppercase tracking-wider py-6 text-base shadow-lg shadow-emerald-500/30 rounded-xl">
              Request to Join
            </Button>
          )}
        </div>
      </div>
    </div>
  );
}

/* ---------- Helpers ---------- */

function HeroStat({ value, label, accent }: { value: React.ReactNode; label: string; accent?: string }) {
  return (
    <div className="bg-white/10 backdrop-blur-sm rounded-xl p-2.5 text-center border border-white/20">
      <div className={`text-xl font-black leading-none ${accent ?? ''}`}>{value}</div>
      <div className="text-[10px] font-bold uppercase tracking-wider text-emerald-100 mt-1">{label}</div>
    </div>
  );
}

function TopPerformerCard({
  icon, label, player, value, gradient,
}: { icon: React.ReactNode; label: string; player?: string; value: string; gradient: string }) {
  return (
    <div className="relative overflow-hidden bg-white rounded-2xl border border-gray-100 shadow-sm p-4">
      <div className={`absolute top-0 left-0 right-0 h-1 bg-gradient-to-r ${gradient}`} />
      <div className={`inline-flex items-center justify-center w-7 h-7 rounded-lg bg-gradient-to-br ${gradient} text-white shadow-sm mb-2`}>
        {icon}
      </div>
      <div className="text-[10px] font-black uppercase tracking-widest text-gray-500">{label}</div>
      <div className="font-black text-gray-900 text-sm truncate mt-0.5">{player ?? '—'}</div>
      <div className="text-xs font-bold text-gray-500 mt-0.5">{value}</div>
    </div>
  );
}
