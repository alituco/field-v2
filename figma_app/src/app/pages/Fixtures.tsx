import { PageHeader, HeaderActionButton } from '@/app/components/layout/PageHeader';
import { HeroBanner } from '@/app/components/layout/HeroBanner';
import { FixtureCard } from '@/app/components/fixture/FixtureCard';
import { MOCK_CLANS, MOCK_FIXTURES, MOCK_PLAYERS } from '@/app/lib/data/mockData';
import { Plus, Swords } from 'lucide-react';
import { Badge } from '@/app/components/ui/badge';
import { FixtureStatus } from '@/app/lib/types';
import { useState } from 'react';
import { useNavigate } from 'react-router';

export default function Fixtures() {
  const [selectedStatus, setSelectedStatus] = useState<FixtureStatus | 'ALL'>('ALL');
  const navigate = useNavigate();

  // Mock: assume first player is current user
  const currentPlayer = MOCK_PLAYERS[0];
  const myClan = MOCK_CLANS.find(c => c.id === currentPlayer.clanId);
  const isTeamLeader = myClan?.ownerId === currentPlayer.id;

  const filteredFixtures = selectedStatus === 'ALL'
    ? MOCK_FIXTURES
    : MOCK_FIXTURES.filter(f => f.status === selectedStatus);

  const statusFilters = [
    { value: 'ALL' as const, label: 'All', count: MOCK_FIXTURES.length },
    { value: FixtureStatus.OPEN, label: 'Open', count: MOCK_FIXTURES.filter(f => f.status === FixtureStatus.OPEN).length },
    { value: FixtureStatus.SCHEDULED, label: 'Scheduled', count: MOCK_FIXTURES.filter(f => f.status === FixtureStatus.SCHEDULED).length },
    { value: FixtureStatus.LIVE, label: 'Live', count: MOCK_FIXTURES.filter(f => f.status === FixtureStatus.LIVE).length },
    { value: FixtureStatus.FINAL, label: 'Final', count: MOCK_FIXTURES.filter(f => f.status === FixtureStatus.FINAL).length }
  ];

  return (
    <div className="min-h-screen bg-gray-50">
      <PageHeader
        title="Fixtures"
        rightAction={
          <HeaderActionButton
            icon={<Plus size={18} strokeWidth={3} />}
            label="Host"
            onClick={() => isTeamLeader && navigate('/create-match')}
            disabled={!isTeamLeader}
            variant="pink"
          />
        }
      />

      <div className="p-4 space-y-6">
        <HeroBanner
          theme="sunset"
          eyebrow="Match Day"
          title="Kickoff awaits."
          subtitle="Challenge rivals, defend your turf, and earn the SR."
          icon={<Swords size={28} className="text-orange-100 drop-shadow" />}
          chips={[
            { label: 'Open', value: MOCK_FIXTURES.filter(f => f.status === FixtureStatus.OPEN).length },
            { label: 'Live', value: MOCK_FIXTURES.filter(f => f.status === FixtureStatus.LIVE).length, accent: 'text-red-200' },
            { label: 'Scheduled', value: MOCK_FIXTURES.filter(f => f.status === FixtureStatus.SCHEDULED).length },
          ]}
        />

        {/* Status Filters */}
        <div>
          <h3 className="text-sm font-bold text-gray-600 uppercase tracking-wide mb-3">Filter Matches</h3>
          <div className="flex gap-2 overflow-x-auto pb-2 scrollbar-hide">
            {statusFilters.map(filter => (
              <button
                key={filter.value}
                onClick={() => setSelectedStatus(filter.value)}
                className={`
                  px-4 py-2 rounded-lg text-sm font-bold whitespace-nowrap transition-all flex items-center gap-2
                  ${selectedStatus === filter.value
                    ? 'bg-emerald-600 text-white shadow-md'
                    : 'bg-white text-gray-600 border border-gray-200 hover:border-gray-300'}
                `}
              >
                {filter.label}
                <Badge variant="secondary" className="ml-1 text-xs">
                  {filter.count}
                </Badge>
              </button>
            ))}
          </div>
        </div>

        {/* Fixtures List */}
        <div>
          <h3 className="text-sm font-bold text-gray-600 uppercase tracking-wide mb-3">
            {filteredFixtures.length} Match{filteredFixtures.length !== 1 ? 'es' : ''}
          </h3>
          <div className="space-y-3">
            {filteredFixtures.map(fixture => {
              const homeClan = MOCK_CLANS.find(c => c.id === fixture.homeClanId);
              const awayClan = fixture.awayClanId ? MOCK_CLANS.find(c => c.id === fixture.awayClanId) : undefined;

              if (!homeClan) return null;

              return (
              <div key={fixture.id} onClick={() => navigate(`/fixtures/${fixture.id}`)} className="cursor-pointer transition-transform active:scale-95">
                <FixtureCard
                  fixture={fixture}
                  homeClan={homeClan}
                  awayClan={awayClan}
                />
              </div>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}
