import { PageHeader, HeaderActionButton } from '@/app/components/layout/PageHeader';
import { HeroBanner } from '@/app/components/layout/HeroBanner';
import { ClanCard } from '@/app/components/clan/ClanCard';
import { FixtureCard } from '@/app/components/fixture/FixtureCard';
import { MOCK_CLANS, MOCK_FIXTURES, MOCK_PLAYERS } from '@/app/lib/data/mockData';
import { Flame, Calendar, Plus, Zap } from 'lucide-react';
import { Button } from '@/app/components/ui/button';
import { useNavigate } from 'react-router';

export default function Home() {
  const currentPlayer = MOCK_PLAYERS[0];
  const myClan = MOCK_CLANS.find(c => c.id === currentPlayer.clanId);
  const isTeamLeader = myClan?.ownerId === currentPlayer.id;
  const upcomingFixtures = MOCK_FIXTURES.filter(f => f.status !== 'FINAL').slice(0, 3);
  const navigate = useNavigate();

  const firstName = currentPlayer.name.split(' ')[0];

  return (
    <div className="min-h-screen bg-gradient-to-b from-emerald-50/60 via-white to-gray-50">
      <PageHeader
        brand
        title="Field"
        rightAction={
          <HeaderActionButton
            icon={<Plus size={18} strokeWidth={3} />}
            onClick={() => isTeamLeader && navigate('/create-match')}
            disabled={!isTeamLeader}
            variant="emerald"
          />
        }
      />

      <div className="p-4 space-y-6">
        <HeroBanner
          theme="pitch"
          eyebrow={`Match Ready · ${new Date().toLocaleDateString('en-US', { weekday: 'short' }).toUpperCase()}`}
          title={`Game on, ${firstName}.`}
          subtitle="The pitch is calling. Rally your clan and take the field."
          icon={<Flame size={28} className="text-orange-300 drop-shadow" />}
          chips={myClan ? [
            { label: 'Rating', value: myClan.skillRating },
            { label: 'Wins', value: myClan.wins },
            { label: 'Streak', value: `${Math.max(1, myClan.wins % 5)}🔥`, accent: 'text-orange-200' },
          ] : undefined}
        />

        {/* My Clan */}
        {myClan && (
          <div>
            <SectionHeader label="My Clan" />
            <ClanCard clan={myClan} />
            <div className="mt-4">
              <Button
                onClick={() => isTeamLeader && navigate('/create-match')}
                disabled={!isTeamLeader}
                className={`relative w-full py-6 font-black uppercase tracking-wider text-base rounded-2xl flex items-center justify-center gap-2 overflow-hidden ${
                  isTeamLeader
                    ? 'bg-gradient-to-r from-blue-600 via-indigo-600 to-violet-600 hover:brightness-110 text-white shadow-xl shadow-blue-500/30'
                    : 'bg-gray-200 text-gray-400'
                }`}
              >
                <Zap size={20} className="relative" />
                <span className="relative">Find or Host a Match</span>
              </Button>
              {!isTeamLeader && (
                <p className="text-center text-xs text-gray-500 mt-2">Only Team Leaders can create matches.</p>
              )}
            </div>
          </div>
        )}

        {/* Upcoming Matches */}
        <div>
          <SectionHeader label="Upcoming Matches" icon={<Calendar size={14} />} />
          <div className="space-y-3">
            {upcomingFixtures.map(fixture => {
              const homeClan = MOCK_CLANS.find(c => c.id === fixture.homeClanId);
              const awayClan = fixture.awayClanId ? MOCK_CLANS.find(c => c.id === fixture.awayClanId) : undefined;
              if (!homeClan) return null;
              return (
                <FixtureCard
                  key={fixture.id}
                  fixture={fixture}
                  homeClan={homeClan}
                  awayClan={awayClan}
                />
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}

function SectionHeader({ label, icon }: { label: string; icon?: React.ReactNode }) {
  return (
    <div className="flex items-center gap-2 mb-3">
      <span className="block w-1 h-5 rounded-full bg-gradient-to-b from-emerald-500 to-blue-600" />
      {icon && <span className="text-gray-500">{icon}</span>}
      <h3 className="text-xs font-black uppercase tracking-[0.18em] text-gray-700">{label}</h3>
      <span className="flex-1 h-px bg-gradient-to-r from-gray-200 to-transparent" />
    </div>
  );
}
