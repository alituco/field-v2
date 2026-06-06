import { Clan } from '@/app/lib/types';
import { getRankFromRating } from '@/app/lib/constants/tiers';
import { TierBadge } from '../layout/TierBadge';
import { Users, TrendingUp } from 'lucide-react';
import { Link } from 'react-router';

interface ClanCardProps {
  clan: Clan;
  rank?: number;
}

export function ClanCard({ clan, rank }: ClanCardProps) {
  const { tier, division } = getRankFromRating(clan.skillRating);
  const winRate = clan.wins + clan.losses > 0
    ? Math.round((clan.wins / (clan.wins + clan.losses)) * 100)
    : 0;

  return (
    <Link to={`/clans/${clan.id}`}>
      <div className="bg-white rounded-xl p-4 shadow-sm border border-gray-200 hover:shadow-md transition-shadow">
        <div className="flex items-start gap-4">
          {/* Rank Badge */}
          {rank !== undefined && (
            <div className="flex-shrink-0">
              <div className={`
                w-10 h-10 rounded-lg flex items-center justify-center font-bold text-lg
                ${rank === 1 ? 'bg-gradient-to-br from-yellow-400 to-amber-500 text-white' :
                  rank === 2 ? 'bg-gradient-to-br from-gray-300 to-gray-400 text-white' :
                  rank === 3 ? 'bg-gradient-to-br from-orange-600 to-amber-700 text-white' :
                  'bg-gray-100 text-gray-600'}
              `}>
                {rank}
              </div>
            </div>
          )}

          {/* Emblem */}
          <div className="flex-shrink-0">
            <div className="w-14 h-14 rounded-xl bg-gradient-to-br from-emerald-400 to-emerald-600 flex items-center justify-center text-3xl shadow-lg shadow-emerald-500/30">
              {clan.emblem || '⚽'}
            </div>
          </div>

          {/* Info */}
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 mb-1">
              <h3 className="font-bold text-gray-900 truncate">{clan.name}</h3>
              <span className="text-xs font-bold text-gray-500 uppercase">{clan.tag}</span>
            </div>

            <div className="flex items-center gap-3 text-sm text-gray-600 mb-2">
              <div className="flex items-center gap-1">
                <Users size={14} />
                <span>{clan.memberIds.length}</span>
              </div>
              <div className="flex items-center gap-1">
                <TrendingUp size={14} className="text-emerald-600" />
                <span className="font-semibold">{winRate}%</span>
              </div>
              <div className="text-xs">
                {clan.wins}W - {clan.losses}L
              </div>
            </div>

            {/* Rating Bar */}
            <div className="flex items-center gap-2">
              <div className="flex-1 bg-gray-100 rounded-full h-2 overflow-hidden">
                <div
                  className="h-full bg-gradient-to-r from-emerald-500 to-blue-500 transition-all duration-300"
                  style={{ width: `${Math.min((clan.skillRating / 5000) * 100, 100)}%` }}
                />
              </div>
              <span className="text-xs font-bold text-gray-700">{clan.skillRating}</span>
            </div>
          </div>

          {/* Tier Badge */}
          <div className="flex-shrink-0">
            <TierBadge tier={tier} division={division} size="sm" showLabel={false} />
          </div>
        </div>
      </div>
    </Link>
  );
}
