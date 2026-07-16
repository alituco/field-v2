import { type Division } from '@/app/lib/types';
import { formatRank } from '@/app/lib/constants/tiers';
import { TierBadge } from '../layout/TierBadge';
import { motion } from 'motion/react';

interface RankUpOverlayProps { newDivision: Division; onClose: () => void; }

export function RankUpOverlay({ newDivision, onClose }: RankUpOverlayProps) {
  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} onClick={onClose} className="fixed inset-0 z-[100] flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm">
      <motion.div initial={{ scale: 0.92, y: 16 }} animate={{ scale: 1, y: 0 }} onClick={(event) => event.stopPropagation()} className="w-full max-w-sm rounded-3xl bg-white p-8 text-center shadow-2xl">
        <p className="text-xs font-bold uppercase tracking-[0.2em] text-emerald-700">Clan promoted</p>
        <h2 className="mt-2 text-3xl font-black text-gray-900">Division up</h2>
        <div className="my-6 flex justify-center"><TierBadge division={newDivision} size="lg" showLabel={false} /></div>
        <p className="text-2xl font-black text-gray-900">{formatRank({ division: newDivision })}</p>
        <button onClick={onClose} className="mt-7 h-12 w-full rounded-2xl bg-emerald-600 font-bold text-white">Keep playing</button>
      </motion.div>
    </motion.div>
  );
}
