import { PageHeader, HeaderActionButton } from '@/app/components/layout/PageHeader';
import { HeroBanner } from '@/app/components/layout/HeroBanner';
import { ClanCard } from '@/app/components/clan/ClanCard';
import { MOCK_CLANS } from '@/app/lib/data/mockData';
import { Shield, Plus, Search } from 'lucide-react';
import { Input } from '@/app/components/ui/input';
import { useState } from 'react';
import { useNavigate } from 'react-router';

export default function Clans() {
  const navigate = useNavigate();
  const [searchQuery, setSearchQuery] = useState('');

  const filteredClans = MOCK_CLANS.filter(clan =>
    clan.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
    clan.tag.toLowerCase().includes(searchQuery.toLowerCase())
  );

  return (
    <div className="min-h-screen bg-gray-50">
      <PageHeader
        title="Clans"
        rightAction={
          <HeaderActionButton
            icon={<Plus size={18} strokeWidth={3} />}
            label="New"
            onClick={() => navigate('/create-clan')}
            variant="blue"
          />
        }
      />

      <div className="p-4 space-y-6">
        <HeroBanner
          theme="electric"
          eyebrow="Squads · Brotherhoods · Rivals"
          title="Find your tribe."
          subtitle="Join an elite squad or forge a new dynasty of your own."
          icon={<Shield size={28} className="text-blue-100 drop-shadow" />}
          chips={[
            { label: 'Clans', value: MOCK_CLANS.length },
            { label: 'Recruiting', value: MOCK_CLANS.filter(c => c.memberIds.length < 11).length },
          ]}
        />

        {/* Search */}
        <div className="relative">
          <Search size={18} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
          <Input
            placeholder="Search clans..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="pl-10 bg-white border-gray-200"
          />
        </div>

        {/* Clans List */}
        <div>
          <div className="flex items-center justify-between mb-3">
            <h3 className="text-sm font-bold text-gray-600 uppercase tracking-wide">
              {filteredClans.length} Clan{filteredClans.length !== 1 ? 's' : ''}
            </h3>
          </div>
          <div className="space-y-3">
            {filteredClans.map(clan => (
              <ClanCard key={clan.id} clan={clan} />
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
