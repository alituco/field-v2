import { useNavigate, useParams, useSearchParams } from 'react-router';
import { motion } from 'motion/react';
import { PageHeader } from '@/app/components/layout/PageHeader';
import { getQueueMatch, roleLabel } from '@/app/lib/openQueue';
import type { QueueRole } from '@/app/lib/types';
import {
  Clock,
  MapPin,
  User,
  Users,
  TrendingUp,
  Shield,
  Layers,
  ChevronRight,
  BadgeCheck,
} from 'lucide-react';

export default function QueueReview() {
  const navigate = useNavigate();
  const { matchId } = useParams();
  const [params] = useSearchParams();
  const role = (params.get('role') as QueueRole) ?? 'MID';
  const match = matchId ? getQueueMatch(matchId) : undefined;

  if (!match) {
    return (
      <div className="min-h-screen bg-gray-50">
        <PageHeader title="Booking" showBack />
        <div className="p-8 text-center text-gray-500">Game not found.</div>
      </div>
    );
  }

  const rows: { icon: React.ReactNode; label: string; value: string }[] = [
    { icon: <Clock size={16} />, label: 'Time', value: `${match.dateGroup === 'TODAY' ? 'Today' : match.dateGroup} · ${match.timeLabel}` },
    { icon: <MapPin size={16} />, label: 'Venue', value: match.venue },
    { icon: <User size={16} />, label: 'Position', value: roleLabel(role) },
    { icon: <Layers size={16} />, label: 'Format', value: '6-a-side · Ranked Open Queue' },
    { icon: <Users size={16} />, label: 'Players', value: `${match.confirmed} of ${match.capacity} confirmed` },
  ];

  return (
    <div className="min-h-screen bg-gray-50 pb-8">
      <PageHeader title="Open Queue Booking" showBack />

      <div className="p-4 space-y-5">
        <div className="bg-white rounded-3xl border border-gray-100 shadow-sm overflow-hidden divide-y divide-gray-50">
          {rows.map(row => {
            const isPosition = row.label === 'Position';
            return (
              <div key={row.label} className={`flex items-center gap-3 px-5 py-4 ${isPosition ? 'bg-emerald-50/80' : ''}`}>
                <div className={`w-9 h-9 rounded-xl flex items-center justify-center shrink-0 ${isPosition ? 'bg-emerald-600 text-white shadow-sm shadow-emerald-600/25' : 'bg-gray-50 text-gray-500'}`}>
                  {isPosition ? <BadgeCheck size={18} /> : row.icon}
                </div>
                <div className="min-w-0 flex-1">
                  <div className={`text-[10px] font-black uppercase tracking-wider ${isPosition ? 'text-emerald-700' : 'text-gray-400'}`}>{row.label}</div>
                  <div className={`text-sm font-bold truncate ${isPosition ? 'text-emerald-950' : 'text-gray-900'}`}>{row.value}</div>
                </div>
                {isPosition && <span className="rounded-full bg-emerald-600 px-2.5 py-1 text-[10px] font-black uppercase tracking-wider text-white">Selected</span>}
              </div>
            );
          })}
        </div>

        {/* Rating impact */}
        <div className="rounded-3xl bg-emerald-50 border border-emerald-100 p-5">
          <div className="flex items-center gap-2 text-emerald-700">
            <TrendingUp size={16} />
            <span className="text-xs font-black uppercase tracking-wider">Rating impact</span>
          </div>
          <ul className="mt-3 space-y-1.5 text-sm">
            <li className="flex items-center gap-2 font-semibold text-gray-800">
              <span className="w-1.5 h-1.5 rounded-full bg-emerald-500" />
              Affects your Player Rating
            </li>
            <li className="flex items-center gap-2 text-gray-500">
              <span className="w-1.5 h-1.5 rounded-full bg-gray-300" />
              Does not affect Clan Rating
            </li>
          </ul>
        </div>

        {/* Team assignment note */}
        <div className="flex items-start gap-3 rounded-3xl bg-white border border-gray-100 shadow-sm p-5">
          <Shield size={18} className="text-gray-400 shrink-0 mt-0.5" />
          <p className="text-sm text-gray-600">
            You'll be assigned to <span className="font-bold text-gray-900">White</span> or{' '}
            <span className="font-bold text-gray-900">Black</span> when the match fills, to keep
            both teams balanced.
          </p>
        </div>

        {/* Price + actions */}
        <div className="bg-white rounded-3xl border border-gray-100 shadow-sm p-5">
          <div className="flex items-center justify-between">
            <span className="text-sm font-semibold text-gray-500">Total</span>
            <span className="text-2xl font-black text-gray-900">{match.price} BHD</span>
          </div>
          <motion.button
            whileTap={{ scale: 0.98 }}
            onClick={() => navigate(`/queue/pay/${match.id}?role=${role}`)}
            className="mt-4 w-full h-14 rounded-2xl bg-gradient-to-r from-emerald-500 to-blue-600 text-white font-black tracking-wide flex items-center justify-center gap-2 shadow-lg shadow-emerald-500/25"
          >
            Confirm and Pay <ChevronRight size={18} />
          </motion.button>
          <button
            onClick={() => navigate(-1)}
            className="mt-2 w-full h-12 rounded-2xl text-gray-500 font-bold text-sm"
          >
            Back
          </button>
        </div>
      </div>
    </div>
  );
}
