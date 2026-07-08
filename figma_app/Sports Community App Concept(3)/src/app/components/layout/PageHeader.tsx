import { ArrowLeft } from 'lucide-react';
import { useNavigate } from 'react-router';
import { motion } from 'motion/react';

interface PageHeaderProps {
  title: string;
  showBack?: boolean;
  rightAction?: React.ReactNode;
  /** When true, render the bold FIELD wordmark instead of a plain title. */
  brand?: boolean;
}

export function PageHeader({ title, showBack = false, rightAction, brand = false }: PageHeaderProps) {
  const navigate = useNavigate();

  return (
    <header className="sticky top-0 z-40">
      {/* Subtle blurred backdrop */}
      <div className="absolute inset-0 bg-white/70 backdrop-blur-xl border-b border-gray-200/60" />

      {/* Accent stripe */}
      <div className="absolute bottom-0 left-0 right-0 h-[2px] bg-gradient-to-r from-transparent via-emerald-500/60 to-transparent" />

      <div className="relative h-16 flex items-center justify-between px-4">
        <div className="flex items-center gap-2">
          {showBack && (
            <button
              onClick={() => navigate(-1)}
              className="w-9 h-9 -ml-1 rounded-full bg-white border border-gray-200 shadow-sm hover:shadow flex items-center justify-center transition-all active:scale-95"
            >
              <ArrowLeft size={18} className="text-gray-800" />
            </button>
          )}

          {brand ? (
            <BrandMark />
          ) : (
            <div className="flex items-center gap-2">
              <span className="block w-1 h-6 rounded-full bg-gradient-to-b from-emerald-500 to-blue-600" />
              <h1 className="text-xl font-black tracking-tight text-gray-900 uppercase">
                {title}
              </h1>
            </div>
          )}
        </div>

        {rightAction && <div>{rightAction}</div>}
      </div>
    </header>
  );
}

function BrandMark() {
  return (
    <div className="flex items-center gap-2">
      <motion.div
        className="relative w-9 h-9 rounded-full bg-gradient-to-br from-emerald-400 via-emerald-500 to-blue-600 shadow-lg shadow-emerald-500/40 flex items-center justify-center"
        animate={{ rotate: [0, 360] }}
        transition={{ duration: 14, ease: 'linear', repeat: Infinity }}
      >
        {/* Mini soccer-ball pattern */}
        <svg viewBox="0 0 24 24" className="w-6 h-6 text-white/95">
          <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" strokeWidth="1.4" />
          <polygon points="12,7 15,9.5 13.8,13 10.2,13 9,9.5" fill="currentColor" />
          <line x1="12" y1="2" x2="12" y2="7" stroke="currentColor" strokeWidth="1" />
          <line x1="22" y1="12" x2="15.5" y2="11" stroke="currentColor" strokeWidth="1" />
          <line x1="2" y1="12" x2="8.5" y2="11" stroke="currentColor" strokeWidth="1" />
          <line x1="6" y1="20" x2="10.2" y2="13" stroke="currentColor" strokeWidth="1" />
          <line x1="18" y1="20" x2="13.8" y2="13" stroke="currentColor" strokeWidth="1" />
        </svg>
      </motion.div>

      <div className="flex items-baseline gap-1">
        <h1 className="text-2xl font-black tracking-tighter uppercase bg-gradient-to-r from-emerald-600 via-emerald-500 to-blue-600 bg-clip-text text-transparent">
          Field
        </h1>
        <span className="text-[10px] font-black tracking-widest text-gray-400 uppercase">FC</span>
      </div>
    </div>
  );
}

/**
 * A stylized circular icon-action button intended for use as a PageHeader
 * `rightAction`. Renders a gradient orb with a soft glow + pulse ring.
 */
interface HeaderActionButtonProps {
  icon: React.ReactNode;
  label?: string;
  onClick?: () => void;
  disabled?: boolean;
  variant?: 'emerald' | 'blue' | 'amber' | 'violet' | 'pink';
}

const variantGradients: Record<NonNullable<HeaderActionButtonProps['variant']>, string> = {
  emerald: 'from-emerald-500 via-emerald-500 to-blue-600 shadow-emerald-500/50',
  blue: 'from-blue-500 via-indigo-500 to-violet-600 shadow-blue-500/50',
  amber: 'from-amber-400 via-orange-500 to-red-500 shadow-orange-500/50',
  violet: 'from-fuchsia-500 via-violet-500 to-indigo-600 shadow-violet-500/50',
  pink: 'from-pink-500 via-rose-500 to-orange-500 shadow-pink-500/50',
};

export function HeaderActionButton({
  icon,
  label,
  onClick,
  disabled = false,
  variant = 'emerald',
}: HeaderActionButtonProps) {
  if (disabled) {
    return (
      <button
        disabled
        className={`h-10 ${label ? 'px-3 gap-1.5' : 'w-10 justify-center'} rounded-full bg-gray-200 text-gray-400 text-xs font-bold uppercase tracking-wider flex items-center cursor-not-allowed`}
      >
        <span className="w-5 h-5 flex items-center justify-center shrink-0">{icon}</span>
        {label}
      </button>
    );
  }

  return (
    <motion.button
      whileTap={{ scale: 0.92 }}
      onClick={onClick}
      className={`relative h-10 ${label ? 'px-4 pl-3 gap-1.5' : 'w-10 justify-center'} rounded-full bg-gradient-to-br ${variantGradients[variant]} text-white shadow-lg flex items-center font-bold text-xs uppercase tracking-wider`}
    >
      {/* Pulse ring */}
      <motion.span
        className="absolute inset-0 rounded-full ring-2 ring-white/30"
        animate={{ scale: [1, 1.2, 1], opacity: [0.6, 0, 0.6] }}
        transition={{ duration: 2.4, repeat: Infinity, ease: 'easeInOut' }}
      />
      <span className="relative w-5 h-5 flex items-center justify-center shrink-0">{icon}</span>
      {label && <span className="relative">{label}</span>}
    </motion.button>
  );
}
