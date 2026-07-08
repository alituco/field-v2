import { useParams, useNavigate } from 'react-router';
import { PageHeader } from '@/app/components/layout/PageHeader';
import { TierBadge } from '@/app/components/layout/TierBadge';
import { MOCK_CLANS, MOCK_PLAYERS, MOCK_FIXTURES } from '@/app/lib/data/mockData';
import { getRankFromRating } from '@/app/lib/constants/tiers';
import { FixtureStatus } from '@/app/lib/types';
import { Calendar, MapPin, PlayCircle, Trophy, TrendingUp, TrendingDown, Clock, ShieldAlert } from 'lucide-react';
import { Button } from '@/app/components/ui/button';
import { Badge } from '@/app/components/ui/badge';
import { motion } from 'motion/react';

export default function FixtureDetail() {
  const { fixtureId } = useParams();
  const navigate = useNavigate();

  const fixture = MOCK_FIXTURES.find(f => f.id === fixtureId);

  if (!fixture) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center">
        <div className="text-center">
          <p className="text-gray-500">Match not found</p>
          <Button onClick={() => navigate(-1)} className="mt-4">
            Go Back
          </Button>
        </div>
      </div>
    );
  }

  const homeClan = MOCK_CLANS.find(c => c.id === fixture.homeClanId);
  const awayClan = MOCK_CLANS.find(c => c.id === fixture.awayClanId);
  
  const homeRank = homeClan ? getRankFromRating(homeClan.skillRating) : null;
  const awayRank = awayClan ? getRankFromRating(awayClan.skillRating) : null;

  const isFinal = fixture.status === FixtureStatus.FINAL;
  const isLive = fixture.status === FixtureStatus.LIVE;
  
  const homeWin = isFinal && fixture.homeScore! > fixture.awayScore!;
  const awayWin = isFinal && fixture.awayScore! > fixture.homeScore!;
  const isDraw = isFinal && fixture.homeScore === fixture.awayScore;

  return (
    <div className="min-h-screen bg-gray-50 pb-20">
      <PageHeader title="Match Details" showBack />

      <div className="p-4 space-y-6">
        {/* Match Card / Scoreboard */}
        <div className="bg-gradient-to-br from-gray-900 via-gray-800 to-black rounded-3xl p-6 text-white shadow-2xl relative overflow-hidden">
          {/* Decorative background elements */}
          <div className="absolute top-0 right-0 w-64 h-64 bg-emerald-500/10 rounded-full blur-3xl -translate-y-1/2 translate-x-1/3" />
          <div className="absolute bottom-0 left-0 w-48 h-48 bg-blue-500/10 rounded-full blur-2xl translate-y-1/3 -translate-x-1/3" />
          
          <div className="flex justify-center mb-6">
            <Badge variant="outline" className={`border-0 uppercase tracking-widest font-black ${
              isLive ? 'bg-red-500 text-white animate-pulse' :
              isFinal ? 'bg-white/20 text-white' :
              'bg-emerald-500 text-white'
            }`}>
              {isLive ? 'Live Now' : isFinal ? 'Full Time' : 'Upcoming'}
            </Badge>
          </div>

          <div className="flex items-center justify-between relative z-10">
            {/* Home Clan */}
            <div className="flex flex-col items-center flex-1">
              <div className="w-16 h-16 rounded-2xl bg-white/10 backdrop-blur-md flex items-center justify-center text-3xl border border-white/20 shadow-lg mb-3">
                {homeClan?.emblem || '⚽'}
              </div>
              <span className="font-bold text-center text-sm mb-2">{homeClan?.name}</span>
              {homeRank && <TierBadge tier={homeRank.tier} division={homeRank.division} size="sm" showLabel={false} />}
            </div>

            {/* Score / VS */}
            <div className="flex flex-col items-center px-4">
              {isFinal || isLive ? (
                <div className="flex items-center gap-3">
                  <span className={`text-4xl font-black ${homeWin ? 'text-emerald-400' : 'text-white'}`}>
                    {fixture.homeScore}
                  </span>
                  <span className="text-gray-500 text-xl font-bold">-</span>
                  <span className={`text-4xl font-black ${awayWin ? 'text-emerald-400' : 'text-white'}`}>
                    {fixture.awayScore}
                  </span>
                </div>
              ) : (
                <div className="text-2xl font-black text-gray-400 bg-white/10 px-4 py-2 rounded-xl">
                  VS
                </div>
              )}
            </div>

            {/* Away Clan */}
            <div className="flex flex-col items-center flex-1">
              <div className="w-16 h-16 rounded-2xl bg-white/10 backdrop-blur-md flex items-center justify-center text-3xl border border-white/20 shadow-lg mb-3">
                {awayClan?.emblem || '🛡️'}
              </div>
              <span className="font-bold text-center text-sm mb-2">{awayClan?.name || 'TBD'}</span>
              {awayRank ? <TierBadge tier={awayRank.tier} division={awayRank.division} size="sm" showLabel={false} /> : <div className="h-6" />}
            </div>
          </div>
        </div>

        {/* Info Grid */}
        <div className="grid grid-cols-2 gap-3">
          <div className="bg-white rounded-2xl p-4 border border-gray-100 flex items-center gap-3 shadow-sm">
            <div className="p-2.5 bg-emerald-50 rounded-xl text-emerald-600">
              <Calendar size={20} />
            </div>
            <div>
              <p className="text-xs text-gray-500 font-bold uppercase">{fixture.day}</p>
              <p className="text-sm font-bold text-gray-900">{fixture.date}</p>
            </div>
          </div>
          <div className="bg-white rounded-2xl p-4 border border-gray-100 flex items-center gap-3 shadow-sm">
            <div className="p-2.5 bg-blue-50 rounded-xl text-blue-600">
              <Clock size={20} />
            </div>
            <div>
              <p className="text-xs text-gray-500 font-bold uppercase">Time</p>
              <p className="text-sm font-bold text-gray-900">{fixture.timeSlot.split(' - ')[0]}</p>
            </div>
          </div>
          <div className="bg-white rounded-2xl p-4 border border-gray-100 flex items-center gap-3 shadow-sm col-span-2">
            <div className="p-2.5 bg-amber-50 rounded-xl text-amber-600">
              <MapPin size={20} />
            </div>
            <div>
              <p className="text-xs text-gray-500 font-bold uppercase">Venue</p>
              <p className="text-sm font-bold text-gray-900">{fixture.venue}</p>
            </div>
          </div>
        </div>

        {/* SR Changes (If Final) */}
        {isFinal && (fixture.homeSrChange !== undefined || fixture.awaySrChange !== undefined) && (
          <motion.div 
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            className="bg-white rounded-2xl p-5 border border-gray-100 shadow-sm"
          >
            <h3 className="font-bold text-gray-900 flex items-center gap-2 mb-4">
              <Trophy size={18} className="text-amber-500" />
              Rating Updates
            </h3>
            <div className="flex divide-x divide-gray-100">
              <div className="flex-1 pr-4">
                <p className="text-xs text-gray-500 font-bold mb-1 truncate">{homeClan?.name}</p>
                <div className={`flex items-center gap-1.5 text-lg font-black ${
                  fixture.homeSrChange! > 0 ? 'text-emerald-600' : 'text-red-500'
                }`}>
                  {fixture.homeSrChange! > 0 ? <TrendingUp size={20} /> : <TrendingDown size={20} />}
                  {fixture.homeSrChange! > 0 ? '+' : ''}{fixture.homeSrChange} SR
                </div>
              </div>
              <div className="flex-1 pl-4">
                <p className="text-xs text-gray-500 font-bold mb-1 truncate">{awayClan?.name}</p>
                <div className={`flex items-center gap-1.5 text-lg font-black ${
                  fixture.awaySrChange! > 0 ? 'text-emerald-600' : 'text-red-500'
                }`}>
                  {fixture.awaySrChange! > 0 ? <TrendingUp size={20} /> : <TrendingDown size={20} />}
                  {fixture.awaySrChange! > 0 ? '+' : ''}{fixture.awaySrChange} SR
                </div>
              </div>
            </div>
          </motion.div>
        )}

        {/* Timeline / Scorers */}
        {isFinal && fixture.scorers && fixture.scorers.length > 0 && (
          <motion.div 
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.1 }}
            className="bg-white rounded-2xl p-5 border border-gray-100 shadow-sm"
          >
            <h3 className="font-bold text-gray-900 mb-4 flex items-center gap-2">
              ⚽ Match Highlights
            </h3>
            <div className="space-y-4 relative before:absolute before:inset-0 before:ml-5 before:-translate-x-px md:before:mx-auto md:before:translate-x-0 before:h-full before:w-0.5 before:bg-gradient-to-b before:from-transparent before:via-gray-200 before:to-transparent">
              {[...fixture.scorers]
                .sort((a, b) => a.minute - b.minute)
                .map((scorer, idx) => {
                  const player = MOCK_PLAYERS.find(p => p.id === scorer.playerId);
                  const isHomeScorer = scorer.clanId === fixture.homeClanId;
                  
                  return (
                    <div key={idx} className="relative flex items-center justify-between md:justify-normal md:odd:flex-row-reverse group is-active">
                      <div className="flex items-center justify-center w-10 h-10 rounded-full border-4 border-white bg-emerald-100 text-emerald-600 shadow shrink-0 md:order-1 md:group-odd:-translate-x-1/2 md:group-even:translate-x-1/2 z-10">
                        <span className="text-xs font-black">{scorer.minute}'</span>
                      </div>
                      <div className={`w-[calc(100%-4rem)] md:w-[calc(50%-2.5rem)] p-3 rounded-xl border border-gray-100 bg-gray-50 shadow-sm flex items-center gap-3 ${
                        isHomeScorer ? 'md:justify-end md:text-right' : ''
                      }`}>
                        {isHomeScorer && <span className="text-xl hidden md:block">⚽</span>}
                        <div className={isHomeScorer ? 'md:text-right flex-1' : 'flex-1'}>
                          <p className="font-bold text-gray-900 text-sm">{player?.name || 'Unknown Player'}</p>
                          <p className="text-xs text-gray-500 font-medium">{player?.username ? `@${player.username}` : 'Goal'}</p>
                        </div>
                        {!isHomeScorer && <span className="text-xl">⚽</span>}
                        {isHomeScorer && <span className="text-xl md:hidden">⚽</span>}
                      </div>
                    </div>
                  );
              })}
            </div>
          </motion.div>
        )}

        {/* Match VOD / Stream */}
        <motion.div 
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2 }}
          className="bg-white rounded-2xl overflow-hidden border border-gray-100 shadow-sm"
        >
          <div className="p-4 border-b border-gray-100 flex items-center gap-2">
            <PlayCircle className="text-red-500" size={20} />
            <h3 className="font-bold text-gray-900">
              {isFinal ? 'Match Replay' : isLive ? 'Live Stream' : 'Live Broadcast'}
            </h3>
          </div>
          
          <div className="aspect-video bg-gray-900 relative flex items-center justify-center group cursor-pointer overflow-hidden">
            {fixture.videoUrl ? (
              <iframe 
                className="w-full h-full"
                src={fixture.videoUrl}
                title="Match Video"
                allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
                allowFullScreen
              ></iframe>
            ) : (
              <>
                <div className="absolute inset-0 bg-[url('https://images.unsplash.com/photo-1518605368461-1e1252220a77?q=80&w=2070&auto=format&fit=crop')] bg-cover bg-center opacity-30 mix-blend-overlay group-hover:scale-105 transition-transform duration-700" />
                <div className="relative z-10 text-center p-6 backdrop-blur-sm bg-black/40 rounded-2xl border border-white/10">
                  {isLive ? (
                    <Button className="bg-red-500 hover:bg-red-600 text-white font-bold rounded-full px-8">
                      Watch Live
                    </Button>
                  ) : isFinal ? (
                    <div className="flex flex-col items-center gap-2">
                      <ShieldAlert className="text-gray-400 mb-2" size={32} />
                      <p className="text-white font-bold">VOD Not Available</p>
                      <p className="text-gray-400 text-sm">Recording was not uploaded for this match.</p>
                    </div>
                  ) : (
                    <div className="flex flex-col items-center gap-2">
                      <div className="text-white font-black text-2xl mb-1">Starts in</div>
                      <div className="flex gap-3">
                        <div className="bg-white/20 rounded-lg p-2 min-w-[60px]">
                          <div className="text-xl font-bold text-white">02</div>
                          <div className="text-[10px] text-gray-300 uppercase">Days</div>
                        </div>
                        <div className="bg-white/20 rounded-lg p-2 min-w-[60px]">
                          <div className="text-xl font-bold text-white">14</div>
                          <div className="text-[10px] text-gray-300 uppercase">Hours</div>
                        </div>
                      </div>
                    </div>
                  )}
                </div>
              </>
            )}
          </div>
        </motion.div>
        
        {/* Bottom padding spacing for mobile view */}
        <div className="h-6"></div>
      </div>
    </div>
  );
}