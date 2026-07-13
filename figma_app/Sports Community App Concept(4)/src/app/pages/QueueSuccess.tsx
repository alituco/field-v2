import { useEffect } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router';
import { motion } from 'motion/react';
import confetti from 'canvas-confetti';
import { PageHeader } from '@/app/components/layout/PageHeader';
import { getQueueMatch, getBooking, roleLabel } from '@/app/lib/openQueue';
import type { QueueRole } from '@/app/lib/types';
import { Check, Clock, MapPin, User, Users, Bell, BadgeCheck } from 'lucide-react';

export default function QueueSuccess() {
  const navigate = useNavigate();
  const { matchId } = useParams();
  const [params] = useSearchParams();
  const booking = getBooking();
  const role = (params.get('role') as QueueRole) ?? booking?.role ?? 'MID';
  const match = matchId ? getQueueMatch(matchId) : undefined;

  useEffect(() => {
    // Controlled, single celebratory burst.
    const t = setTimeout(() => {
      confetti({
        particleCount: 90,
        spread: 70,
        origin: { y: 0.35 },
        colors: ['#10b981', '#3b82f6', '#22d3ee', '#ffffff'],
      });
    }, 250);
    return () => clearTimeout(t);
  }, []);

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
    { icon: <Users size={16} />, label: 'Players', value: `${Math.max(match.confirmed, 10)} of ${match.capacity} confirmed` },
  ];

  return (
    <div className="min-h-screen bg-gray-50 pb-8">
      <PageHeader title="Booking Confirmed" showBack />

      <div className="p-4 space-y-6">
        <div className="flex flex-col items-center text-center pt-4">
          <motion.div
            initial={{ scale: 0, rotate: -20 }}
            animate={{ scale: 1, rotate: 0 }}
            transition={{ type: 'spring', stiffness: 200, damping: 14 }}
            className="w-20 h-20 rounded-full bg-emerald-500 flex items-center justify-center shadow-xl shadow-emerald-500/40"
          >
            <Check size={40} strokeWidth={3} className="text-white" />
          </motion.div>
          <h1 className="mt-5 text-2xl font-black text-gray-900 uppercase tracking-tight">
            Your spot is reserved
          </h1>
          <p className="mt-1 text-sm text-gray-500 max-w-xs">
            You're confirmed for this Open Queue match.
          </p>
        </div>

        <div className="bg-white rounded-3xl border border-gray-100 shadow-sm overflow-hidden divide-y divide-gray-50">
          {rows.map(row => {
            const isPosition = row.label === 'Position';
            return (
              <div key={row.label} className={`flex items-center gap-3 px-5 py-4 ${isPosition ? 'bg-emerald-50/80' : ''}`}>
                <div className={`w-9 h-9 rounded-xl flex items-center justify-center shrink-0 ${isPosition ? 'bg-emerald-600 text-white shadow-sm shadow-emerald-600/25' : 'bg-gray-50 text-gray-500'}`}>
                  {isPosition ? <BadgeCheck size={18} /> : row.icon}
                </div>
                <div className="min-w-0 flex-1">
                  <div className={`text-[10px] font-black uppercase tracking-wider ${isPosition ? 'text-emerald-700' : 'text-gray-400'}`}>
                    {row.label}
                  </div>
                  <div className={`text-sm font-bold truncate ${isPosition ? 'text-emerald-950' : 'text-gray-900'}`}>{row.value}</div>
                </div>
                {isPosition && <span className="rounded-full bg-emerald-600 px-2.5 py-1 text-[10px] font-black uppercase tracking-wider text-white">Your role</span>}
              </div>
            );
          })}
        </div>

        <div className="flex items-start gap-3 rounded-3xl bg-blue-50 border border-blue-100 p-5">
          <Bell size={18} className="text-blue-600 shrink-0 mt-0.5" />
          <p className="text-sm text-gray-600">
            We'll notify you once the match fills and your team (White or Black) is assigned.
          </p>
        </div>

        <div className="space-y-2">
          <motion.button
            whileTap={{ scale: 0.98 }}
            onClick={() => navigate(`/queue/success/${match.id}?role=${role}`)}
            className="w-full h-14 rounded-2xl bg-gray-900 text-white font-black tracking-wide"
          >
            View Booking
          </motion.button>
          <button
            onClick={() => navigate('/')}
            className="w-full h-12 rounded-2xl text-gray-500 font-bold text-sm"
          >
            Back to Home
          </button>
        </div>
      </div>
    </div>
  );
}
