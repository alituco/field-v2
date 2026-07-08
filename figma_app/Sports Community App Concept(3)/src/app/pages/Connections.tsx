import { PageHeader } from '@/app/components/layout/PageHeader';
import { PlayerRow } from '@/app/components/social/PlayerRow';
import { MOCK_PLAYERS } from '@/app/lib/data/mockData';
import { CURRENT_PLAYER_ID, getFollowingIds, getFanIds, toggleFollow } from '@/app/lib/social';
import { Users, Heart, Search } from 'lucide-react';
import { motion } from 'motion/react';
import { useMemo, useState } from 'react';
import { useSearchParams } from 'react-router';

type Tab = 'following' | 'fans';

export default function Connections() {
  const [searchParams, setSearchParams] = useSearchParams();
  const initialTab: Tab = searchParams.get('tab') === 'fans' ? 'fans' : 'following';
  const [tab, setTab] = useState<Tab>(initialTab);
  const [followingIds, setFollowingIds] = useState<string[]>(() => getFollowingIds());

  const fanIds = useMemo(() => getFanIds(), []);

  const onToggle = (id: string) => setFollowingIds(toggleFollow(id));

  const changeTab = (t: Tab) => {
    setTab(t);
    setSearchParams({ tab: t }, { replace: true });
  };

  const followingPlayers = MOCK_PLAYERS.filter(p => followingIds.includes(p.id));
  const fanPlayers = MOCK_PLAYERS.filter(p => fanIds.includes(p.id));

  // People the user could follow (not themselves, not already followed).
  const discoverPlayers = MOCK_PLAYERS.filter(
    p => p.id !== CURRENT_PLAYER_ID && !followingIds.includes(p.id),
  );

  const listPlayers = tab === 'following' ? followingPlayers : fanPlayers;

  return (
    <div className="min-h-screen bg-gradient-to-b from-violet-50/70 via-white to-gray-50">
      <PageHeader title="People" showBack />

      <div className="p-4 space-y-5">
        {/* TABS */}
        <div className="relative grid grid-cols-2 gap-1 bg-gray-100 rounded-full p-1">
          <TabButton
            active={tab === 'following'}
            onClick={() => changeTab('following')}
            icon={<Users size={15} strokeWidth={2.5} />}
            label={`Following ${followingPlayers.length}`}
          />
          <TabButton
            active={tab === 'fans'}
            onClick={() => changeTab('fans')}
            icon={<Heart size={15} strokeWidth={2.5} />}
            label={`Fans ${fanPlayers.length}`}
          />
        </div>

        {/* LIST */}
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm px-4 divide-y divide-gray-50">
          {listPlayers.length > 0 ? (
            listPlayers.map(p => (
              <PlayerRow
                key={p.id}
                player={p}
                following={followingIds.includes(p.id)}
                onToggle={() => onToggle(p.id)}
              />
            ))
          ) : (
            <div className="py-10 text-center">
              <div className="text-sm font-bold text-gray-500">
                {tab === 'following' ? "You're not following anyone yet" : 'No fans yet'}
              </div>
              <div className="text-xs text-gray-400 mt-1">
                {tab === 'following' ? 'Discover players below to build your network.' : 'Keep playing to grow your fanbase.'}
              </div>
            </div>
          )}
        </div>

        {/* DISCOVER */}
        {discoverPlayers.length > 0 && (
          <div>
            <div className="flex items-center gap-2 mb-2">
              <span className="block w-1 h-5 rounded-full bg-gradient-to-b from-emerald-500 to-blue-600" />
              <Search size={14} className="text-emerald-600" />
              <h3 className="text-xs font-black uppercase tracking-[0.18em] text-gray-700">Discover Players</h3>
            </div>
            <motion.div
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              className="bg-white rounded-2xl border border-gray-100 shadow-sm px-4 divide-y divide-gray-50"
            >
              {discoverPlayers.map(p => (
                <PlayerRow
                  key={p.id}
                  player={p}
                  following={followingIds.includes(p.id)}
                  onToggle={() => onToggle(p.id)}
                />
              ))}
            </motion.div>
          </div>
        )}
      </div>
    </div>
  );
}

function TabButton({
  active, onClick, icon, label,
}: { active: boolean; onClick: () => void; icon: React.ReactNode; label: string }) {
  return (
    <button
      onClick={onClick}
      className={`relative h-10 rounded-full flex items-center justify-center gap-1.5 text-xs font-black uppercase tracking-wider transition-colors ${
        active ? 'text-white' : 'text-gray-500'
      }`}
    >
      {active && (
        <motion.span
          layoutId="connTab"
          className="absolute inset-0 rounded-full bg-gradient-to-br from-emerald-500 to-blue-600 shadow-lg shadow-emerald-500/40"
          transition={{ type: 'spring', stiffness: 400, damping: 32 }}
        />
      )}
      <span className="relative flex items-center gap-1.5">{icon}{label}</span>
    </button>
  );
}
