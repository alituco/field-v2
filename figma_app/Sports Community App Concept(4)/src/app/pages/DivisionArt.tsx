import { PageHeader } from '@/app/components/layout/PageHeader';
import { DivisionCrest } from '@/app/components/layout/DivisionCrest';
import { DIVISION_CONFIGS } from '@/app/lib/constants/tiers';
import { type Division } from '@/app/lib/types';
import { motion } from 'motion/react';

// Entry (5) → top (1)
const order: Division[] = [5, 4, 3, 2, 1];

const METAL_LABEL: Record<Division, string> = {
  5: 'Bronze',
  4: 'Steel',
  3: 'Silver',
  2: 'Gold',
  1: 'Elite',
};

export default function DivisionArt() {
  return (
    <div className="min-h-screen bg-gray-50 pb-24">
      <PageHeader title="Division Art" showBack />

      <main className="px-4 pt-4 space-y-4">
        <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">
          🎨 Temporary preview — reviewing the new FIFA-style crests for each division.
        </div>

        {/* Hero: top division showcased big */}
        <section className="flex flex-col items-center rounded-3xl border border-gray-100 bg-gradient-to-b from-emerald-50 to-white px-6 py-8 shadow-sm">
          <DivisionCrest division={1} size="xl" animated />
          <h1 className="mt-4 text-2xl font-black text-gray-900">Division 1</h1>
          <p className="text-sm font-semibold text-emerald-700">Elite · The top division</p>
        </section>

        {/* Full ladder */}
        <section className="grid grid-cols-2 gap-3">
          {order.map((division, i) => {
            const config = DIVISION_CONFIGS[division];
            return (
              <motion.div
                key={division}
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: i * 0.05 }}
                className="flex flex-col items-center rounded-2xl border border-gray-100 bg-white px-4 py-5 shadow-sm"
              >
                <DivisionCrest division={division} size="lg" animated />
                <div className="mt-3 text-base font-black text-gray-900">{config.label}</div>
                <div className="text-xs font-bold uppercase tracking-wider text-gray-400">{METAL_LABEL[division]}</div>
                <p className="mt-1 text-center text-xs text-gray-500 leading-4">{config.description}</p>
              </motion.div>
            );
          })}
        </section>

        {/* Size reference row */}
        <section className="rounded-2xl border border-gray-100 bg-white px-4 py-5 shadow-sm">
          <div className="mb-4 text-xs font-black uppercase tracking-widest text-gray-500">Badge sizes</div>
          <div className="flex items-end justify-around">
            {(['sm', 'md', 'lg'] as const).map(size => (
              <div key={size} className="flex flex-col items-center gap-2">
                <DivisionCrest division={1} size={size} />
                <span className="text-[10px] font-bold uppercase tracking-wider text-gray-400">{size}</span>
              </div>
            ))}
          </div>
        </section>
      </main>
    </div>
  );
}
