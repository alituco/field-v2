import { ImageWithFallback } from '@/app/components/figma/ImageWithFallback';
import { UserPlus, UserCheck } from 'lucide-react';
import { motion } from 'motion/react';
import type { Player } from '@/app/lib/types';

function initials(name: string) {
  return name.split(' ').map(n => n[0]).join('').slice(0, 2).toUpperCase();
}

export function PlayerAvatar({
  player,
  size = 44,
}: {
  player: Player;
  size?: number;
}) {
  return (
    <div
      className="relative shrink-0 rounded-full overflow-hidden bg-gradient-to-br from-emerald-400 to-blue-600 flex items-center justify-center text-white font-black shadow"
      style={{ width: size, height: size }}
    >
      {player.avatar ? (
        <ImageWithFallback
          src={player.avatar}
          alt={player.name}
          className="w-full h-full object-cover"
        />
      ) : (
        <span style={{ fontSize: size * 0.34 }}>{initials(player.name)}</span>
      )}
    </div>
  );
}

export function FollowButton({
  following,
  onClick,
}: {
  following: boolean;
  onClick: () => void;
}) {
  return (
    <motion.button
      whileTap={{ scale: 0.92 }}
      onClick={onClick}
      className={`inline-flex items-center gap-1.5 h-9 px-3.5 rounded-full text-xs font-black uppercase tracking-wider transition-colors ${
        following
          ? 'bg-gray-100 text-gray-600 border border-gray-200'
          : 'bg-gradient-to-br from-emerald-500 to-blue-600 text-white shadow-lg shadow-emerald-500/40'
      }`}
    >
      {following ? <UserCheck size={14} strokeWidth={3} /> : <UserPlus size={14} strokeWidth={3} />}
      {following ? 'Following' : 'Follow'}
    </motion.button>
  );
}

export function PlayerRow({
  player,
  following,
  onToggle,
}: {
  player: Player;
  following: boolean;
  onToggle: () => void;
}) {
  return (
    <div className="flex items-center gap-3 py-2.5">
      <PlayerAvatar player={player} />
      <div className="flex-1 min-w-0">
        <div className="font-bold text-sm text-gray-900 truncate">{player.name}</div>
        <div className="text-xs text-gray-500 truncate">
          @{player.username}
          {player.position && <span className="text-gray-400"> · {player.position}</span>}
        </div>
      </div>
      <FollowButton following={following} onClick={onToggle} />
    </div>
  );
}
