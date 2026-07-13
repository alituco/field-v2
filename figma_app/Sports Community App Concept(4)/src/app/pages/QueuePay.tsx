import { useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router';
import { motion } from 'motion/react';
import { PageHeader } from '@/app/components/layout/PageHeader';
import { getQueueMatch, roleLabel, setBooking } from '@/app/lib/openQueue';
import type { QueueRole } from '@/app/lib/types';
import { Apple, Lock, Clock, MapPin, User, Loader2 } from 'lucide-react';

export default function QueuePay() {
  const navigate = useNavigate();
  const { matchId } = useParams();
  const [params] = useSearchParams();
  const role = (params.get('role') as QueueRole) ?? 'MID';
  const match = matchId ? getQueueMatch(matchId) : undefined;
  const [method, setMethod] = useState<'apple' | 'benefit'>('apple');
  const [processing, setProcessing] = useState(false);

  if (!match) {
    return (
      <div className="min-h-screen bg-gray-50">
        <PageHeader title="Payment" showBack />
        <div className="p-8 text-center text-gray-500">Game not found.</div>
      </div>
    );
  }

  const pay = () => {
    setProcessing(true);
    // Mock payment — no real gateway. Persist the booking then continue.
    setTimeout(() => {
      setBooking({ matchId: match.id, role, bookedAt: new Date().toISOString() });
      navigate(`/queue/success/${match.id}?role=${role}`);
    }, 1400);
  };

  const summary: { icon: React.ReactNode; value: string }[] = [
    { icon: <Clock size={15} />, value: `${match.dateGroup === 'TODAY' ? 'Today' : match.dateGroup} · ${match.timeLabel}` },
    { icon: <MapPin size={15} />, value: match.venue },
    { icon: <User size={15} />, value: roleLabel(role) },
  ];

  return (
    <div className="min-h-screen bg-gray-50 pb-8">
      <PageHeader title="Payment" showBack />

      <div className="p-4 space-y-5">
        {/* Match summary */}
        <div className="bg-white rounded-3xl border border-gray-100 shadow-sm p-5 space-y-2.5">
          {summary.map((s, i) => (
            <div key={i} className="flex items-center gap-2.5 text-sm font-semibold text-gray-700">
              <span className="text-gray-400">{s.icon}</span>
              {s.value}
            </div>
          ))}
        </div>

        {/* Total */}
        <div className="bg-white rounded-3xl border border-gray-100 shadow-sm p-5 flex items-center justify-between">
          <span className="text-sm font-semibold text-gray-500">Total to pay</span>
          <span className="text-2xl font-black text-gray-900">{match.price} BHD</span>
        </div>

        {/* Payment method */}
        <div className="space-y-3">
          <h2 className="text-xs font-black uppercase tracking-widest text-gray-500">
            Payment method
          </h2>
          <button
            onClick={() => setMethod('apple')}
            className={`w-full flex items-center gap-3 rounded-2xl border-2 p-4 transition-colors ${
              method === 'apple' ? 'border-gray-900 bg-gray-50' : 'border-gray-100 bg-white'
            }`}
          >
            <Apple size={22} className="text-gray-900" fill="currentColor" />
            <span className="font-black text-gray-900">Apple Pay</span>
            <span
              className={`ml-auto w-5 h-5 rounded-full border-2 ${
                method === 'apple' ? 'border-gray-900 bg-gray-900' : 'border-gray-300'
              }`}
            />
          </button>
          <button
            onClick={() => setMethod('benefit')}
            className={`w-full flex items-center gap-3 rounded-2xl border-2 p-4 transition-colors ${
              method === 'benefit' ? 'border-gray-900 bg-gray-50' : 'border-gray-100 bg-white'
            }`}
          >
            <span className="w-[22px] h-[22px] rounded-md bg-red-600 text-white text-[10px] font-black flex items-center justify-center">
              B
            </span>
            <span className="font-black text-gray-900">BenefitPay</span>
            <span
              className={`ml-auto w-5 h-5 rounded-full border-2 ${
                method === 'benefit' ? 'border-gray-900 bg-gray-900' : 'border-gray-300'
              }`}
            />
          </button>
        </div>

        {/* Notes */}
        <div className="flex items-center gap-2 text-xs text-gray-400 px-1">
          <Lock size={13} />
          Payments are secure. Free cancellation up to 3 hours before kick-off.
        </div>

        {/* Pay */}
        <motion.button
          whileTap={{ scale: processing ? 1 : 0.98 }}
          disabled={processing}
          onClick={pay}
          className="w-full h-14 rounded-2xl bg-gray-900 text-white font-black tracking-wide flex items-center justify-center gap-2 disabled:opacity-70"
        >
          {processing ? (
            <>
              <Loader2 size={18} className="animate-spin" /> Processing…
            </>
          ) : (
            `Pay ${match.price} BHD`
          )}
        </motion.button>
      </div>
    </div>
  );
}
