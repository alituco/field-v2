import { type Division } from '@/app/lib/types';

interface TierBadgeProps {
  division: Division;
  size?: 'sm' | 'md' | 'lg' | 'xl';
  showLabel?: boolean;
  animated?: boolean;
}

const sizes = {
  sm: 'h-8 min-w-8 px-2 text-xs',
  md: 'h-11 min-w-11 px-3 text-base',
  lg: 'h-16 min-w-16 px-4 text-2xl',
  xl: 'h-24 min-w-24 px-5 text-4xl',
};

/** A deliberately plain division marker: clear at every size, no tier visual language. */
export function TierBadge({ division, size = 'md', showLabel = true }: TierBadgeProps) {
  return (
    <div className="inline-flex flex-col items-center gap-1.5">
      <div className={`inline-flex items-center justify-center rounded-full bg-emerald-600 font-black tabular-nums text-white shadow-sm ${sizes[size]}`}>
        {division}
      </div>
      {showLabel && <span className="text-[10px] font-bold uppercase tracking-[0.16em] text-gray-500">Division {division}</span>}
    </div>
  );
}

export function RankCrest({ division }: { division: Division }) {
  return <div className="inline-flex h-full w-full items-center justify-center rounded-full bg-emerald-600 font-black text-white">{division}</div>;
}
