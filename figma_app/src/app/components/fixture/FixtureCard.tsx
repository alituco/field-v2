import { Fixture, Clan, FixtureStatus } from '@/app/lib/types';
import { MapPin, Clock, Calendar } from 'lucide-react';
import { Badge } from '@/app/components/ui/badge';

interface FixtureCardProps {
  fixture: Fixture;
  homeClan: Clan;
  awayClan?: Clan;
}

const statusConfig = {
  [FixtureStatus.OPEN]: {
    label: 'Looking for opponent',
    color: 'bg-blue-100 text-blue-700 border-blue-200'
  },
  [FixtureStatus.SCHEDULED]: {
    label: 'Scheduled',
    color: 'bg-emerald-100 text-emerald-700 border-emerald-200'
  },
  [FixtureStatus.LIVE]: {
    label: 'Live',
    color: 'bg-orange-100 text-orange-700 border-orange-200 animate-pulse'
  },
  [FixtureStatus.FINAL]: {
    label: 'Final',
    color: 'bg-gray-100 text-gray-700 border-gray-200'
  }
};

export function FixtureCard({ fixture, homeClan, awayClan }: FixtureCardProps) {
  const config = statusConfig[fixture.status];
  const matchDate = new Date(fixture.date);

  return (
    <div className="bg-white rounded-xl border border-gray-200 overflow-hidden shadow-sm hover:shadow-md transition-shadow">
      {/* Status Bar */}
      <div className={`px-4 py-2 border-b ${config.color}`}>
        <div className="flex items-center justify-between">
          <span className="text-sm font-bold">{config.label}</span>
          <div className="flex items-center gap-2 text-xs">
            <Calendar size={12} />
            <span>{matchDate.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}</span>
          </div>
        </div>
      </div>

      {/* Match Info */}
      <div className="p-4">
        {/* Teams */}
        <div className="flex items-center justify-between mb-4">
          {/* Home */}
          <div className="flex items-center gap-3 flex-1">
            <div className="w-12 h-12 rounded-lg bg-gradient-to-br from-emerald-400 to-emerald-600 flex items-center justify-center text-2xl shadow-md">
              {homeClan.emblem || '⚽'}
            </div>
            <div>
              <div className="font-bold text-gray-900">{homeClan.name}</div>
              <div className="text-xs text-gray-500">{homeClan.tag}</div>
            </div>
          </div>

          {/* VS or Score */}
          <div className="px-4">
            {fixture.status === FixtureStatus.FINAL && fixture.homeScore !== undefined && fixture.awayScore !== undefined ? (
              <div className="text-center">
                <div className="text-2xl font-bold text-gray-900">
                  {fixture.homeScore} - {fixture.awayScore}
                </div>
              </div>
            ) : (
              <div className="text-lg font-bold text-gray-400">VS</div>
            )}
          </div>

          {/* Away */}
          <div className="flex items-center gap-3 flex-1 justify-end">
            {awayClan ? (
              <>
                <div className="text-right">
                  <div className="font-bold text-gray-900">{awayClan.name}</div>
                  <div className="text-xs text-gray-500">{awayClan.tag}</div>
                </div>
                <div className="w-12 h-12 rounded-lg bg-gradient-to-br from-blue-400 to-blue-600 flex items-center justify-center text-2xl shadow-md">
                  {awayClan.emblem || '⚽'}
                </div>
              </>
            ) : (
              <div className="w-12 h-12 rounded-lg border-2 border-dashed border-gray-300 flex items-center justify-center text-gray-400">
                ?
              </div>
            )}
          </div>
        </div>

        {/* Details */}
        <div className="flex items-center gap-4 text-sm text-gray-600 pt-3 border-t border-gray-100">
          <div className="flex items-center gap-1.5">
            <MapPin size={14} />
            <span>{fixture.venue}</span>
          </div>
          <div className="flex items-center gap-1.5">
            <Clock size={14} />
            <span>{fixture.timeSlot}</span>
          </div>
        </div>
      </div>
    </div>
  );
}
