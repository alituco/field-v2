import { PageHeader } from '@/app/components/layout/PageHeader';
import { TierBadge } from '@/app/components/layout/TierBadge';
import { PlayerAvatar } from '@/app/components/social/PlayerRow';
import { MOCK_CLANS, MOCK_FIXTURES } from '@/app/lib/data/mockData';
import { getCurrentPlayer, getFollowingIds, getFanIds } from '@/app/lib/social';
import { clearSession } from '@/app/lib/auth';
import { getRankFromRating, TIER_CONFIGS } from '@/app/lib/constants/tiers';
import { FixtureStatus } from '@/app/lib/types';
import { Share2, Play, Eye, LogOut, History, Film, ChevronRight } from 'lucide-react';
import { motion } from 'motion/react';
import { useNavigate } from 'react-router';

export default function Profile() {
  const navigate = useNavigate();
  const currentPlayer = getCurrentPlayer();
  const myClan = MOCK_CLANS.find(c => c.id === currentPlayer.clanId);
  const rank = myClan ? getRankFromRating(myClan.skillRating) : null;
  const tier = rank?.tier ?? null;
  const division = rank?.division;
  const tierConfig = tier ? TIER_CONFIGS[tier] : null;

  const followingCount = getFollowingIds().length;
  const fansCount = getFanIds().length;

  const finals = MOCK_FIXTURES.filter(f => f.status === FixtureStatus.FINAL);
  const goalsScored = finals.flatMap(f => f.scorers ?? []).filter(s => s.playerId === currentPlayer.id).length;
  const assistsMade = finals.flatMap(f => f.scorers ?? []).filter(s => s.assistPlayerId === currentPlayer.id).length;
  const appearances = finals.filter(f => f.homeClanId === myClan?.id || f.awayClanId === myClan?.id).length;

  const highlights = currentPlayer.highlights ?? [];
  const career = currentPlayer.career ?? [];

  return (
    <div className="min-h-screen bg-gray-50">
      <PageHeader
        title="Profile"
        rightAction={
          <button
            onClick={() => {}}
            className="w-9 h-9 rounded-full bg-white border border-gray-200 shadow-sm flex items-center justify-center active:scale-95 transition-transform"
          >
            <Share2 size={16} className="text-gray-600" />
          </button>
        }
      />

      <div className="p-4 space-y-4">

        {/* IDENTITY CARD */}
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.35 }}
          className="bg-white rounded-3xl border border-gray-100 shadow-sm p-5"
        >
          <div className="flex items-center gap-4">
            <div className="relative shrink-0">
              <div className="w-20 h-20 rounded-full overflow-hidden ring-2 ring-gray-100">
                <PlayerAvatar player={currentPlayer} size={80} />
              </div>
              {tier && (
                <div className="absolute -bottom-2 -right-2">
                  <TierBadge tier={tier} division={division} size="sm" showLabel={false} />
                </div>
              )}
            </div>

            <div className="flex-1 min-w-0">
              <h2 className="text-xl font-black text-gray-900 tracking-tight leading-tight truncate">
                {currentPlayer.name}
              </h2>
              <div className="text-sm text-gray-400 font-medium truncate">@{currentPlayer.username}</div>

              {/* Clan row */}
              {myClan ? (
                <div className="mt-2 inline-flex items-center gap-1.5">
                  <span className="text-base leading-none">{myClan.emblem}</span>
                  <span className="text-sm font-bold text-gray-700">{myClan.name}</span>
                  <span className="text-xs text-gray-400 font-medium">{myClan.tag}</span>
                  {tier && tierConfig && (
                    <span className={`text-xs font-black ${tierConfig.textColor}`}>
                      · {tier.charAt(0) + tier.slice(1).toLowerCase()}{division ? ` ${['III','II','I'][3 - division]}` : ''}
                    </span>
                  )}
                </div>
              ) : (
                <div className="mt-2 text-xs text-gray-400 italic">No clan</div>
              )}
            </div>
          </div>

          {currentPlayer.bio && (
            <p className="mt-4 text-sm text-gray-600 leading-relaxed">{currentPlayer.bio}</p>
          )}

          {/* SOCIAL COUNTS */}
          <div className="mt-4 flex items-center gap-0 border-t border-gray-50 pt-4">
            <button
              onClick={() => navigate('/connections?tab=following')}
              className="flex-1 text-center active:opacity-60 transition-opacity"
            >
              <div className="text-xl font-black text-gray-900">{followingCount}</div>
              <div className="text-[11px] font-semibold text-gray-400 uppercase tracking-wider mt-0.5">Following</div>
            </button>
            <div className="w-px h-8 bg-gray-100" />
            <button
              onClick={() => navigate('/connections?tab=fans')}
              className="flex-1 text-center active:opacity-60 transition-opacity"
            >
              <div className="text-xl font-black text-gray-900">{fansCount}</div>
              <div className="text-[11px] font-semibold text-gray-400 uppercase tracking-wider mt-0.5">Fans</div>
            </button>
          </div>
        </motion.div>

        {/* STATS ROW */}
        <div className="grid grid-cols-3 gap-3">
          {[
            { value: appearances, label: 'Apps' },
            { value: goalsScored, label: 'Goals' },
            { value: assistsMade, label: 'Assists' },
          ].map(s => (
            <div key={s.label} className="bg-white rounded-2xl border border-gray-100 shadow-sm py-4 text-center">
              <div className="text-2xl font-black text-gray-900">{s.value}</div>
              <div className="text-[11px] font-semibold text-gray-400 uppercase tracking-wider mt-0.5">{s.label}</div>
            </div>
          ))}
        </div>

        {/* HIGHLIGHTS */}
        {highlights.length > 0 && (
          <div className="bg-white rounded-3xl border border-gray-100 shadow-sm overflow-hidden">
            <div className="flex items-center justify-between px-5 pt-5 pb-3">
              <div className="flex items-center gap-2">
                <Film size={15} className="text-gray-400" />
                <span className="text-sm font-black uppercase tracking-wider text-gray-700">Highlights</span>
              </div>
              <span className="text-xs text-gray-400">{highlights.length} clips</span>
            </div>

            <div className="divide-y divide-gray-50">
              {highlights.map((h, i) => (
                <motion.button
                  key={h.id}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ delay: 0.04 * i }}
                  whileTap={{ opacity: 0.7 }}
                  className="w-full flex items-center gap-3 px-5 py-3 text-left"
                >
                  {/* Thumbnail */}
                  <div className="relative shrink-0 w-20 h-14 rounded-xl overflow-hidden bg-gray-100">
                    <img src={h.thumbnail} alt={h.title} className="w-full h-full object-cover" />
                    <div className="absolute inset-0 bg-black/20 flex items-center justify-center">
                      <div className="w-7 h-7 rounded-full bg-white/80 flex items-center justify-center">
                        <Play size={12} fill="black" className="text-black ml-0.5" />
                      </div>
                    </div>
                    <span className="absolute bottom-1 right-1 px-1 py-0.5 rounded bg-black/60 text-white text-[9px] font-bold tracking-wide">
                      {h.duration}
                    </span>
                  </div>

                  {/* Meta */}
                  <div className="flex-1 min-w-0">
                    <div className="text-sm font-bold text-gray-900 leading-tight line-clamp-2">{h.title}</div>
                    <div className="mt-1 flex items-center gap-1 text-xs text-gray-400">
                      <Eye size={11} />
                      <span>{formatViews(h.views)} views</span>
                      {h.clanTag && <span>· {h.clanTag}</span>}
                    </div>
                  </div>

                  <ChevronRight size={16} className="text-gray-300 shrink-0" />
                </motion.button>
              ))}
            </div>
          </div>
        )}

        {/* CAREER */}
        {career.length > 0 && (
          <div className="bg-white rounded-3xl border border-gray-100 shadow-sm overflow-hidden">
            <div className="flex items-center gap-2 px-5 pt-5 pb-3">
              <History size={15} className="text-gray-400" />
              <span className="text-sm font-black uppercase tracking-wider text-gray-700">Career</span>
            </div>

            <div className="divide-y divide-gray-50">
              {career.map((c) => (
                <div key={c.id} className="flex items-center gap-3 px-5 py-3.5">
                  <div className="w-10 h-10 rounded-xl bg-gray-50 border border-gray-100 flex items-center justify-center text-xl shrink-0">
                    {c.emblem}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-1.5">
                      <span className="font-bold text-gray-900 text-sm truncate">{c.clanName}</span>
                      {c.current && (
                        <span className="px-1.5 py-0.5 rounded-full bg-emerald-100 text-emerald-700 text-[9px] font-black uppercase tracking-wider">
                          Now
                        </span>
                      )}
                    </div>
                    <div className="text-xs text-gray-400 mt-0.5">{c.period}</div>
                  </div>
                  <div className="text-right shrink-0">
                    <div className="text-sm font-black text-gray-900">{c.goals} <span className="font-normal text-gray-400 text-xs">G</span></div>
                    <div className="text-xs text-gray-400">{c.apps} apps</div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* SIGN OUT */}
        <button
          onClick={() => { clearSession(); navigate('/auth', { replace: true }); }}
          className="w-full flex items-center justify-center gap-2 h-12 rounded-2xl bg-white border border-gray-200 text-gray-500 font-semibold text-sm shadow-sm active:scale-[0.99] transition-transform"
        >
          <LogOut size={15} />
          Sign out
        </button>
      </div>
    </div>
  );
}

function formatViews(n: number) {
  return n >= 1000 ? `${(n / 1000).toFixed(1).replace(/\.0$/, '')}k` : `${n}`;
}
