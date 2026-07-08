import { useEffect } from 'react';
import { Tier, type Division } from '@/app/lib/types';
import { TIER_CONFIGS, formatRank } from '@/app/lib/constants/tiers';
import { TierBadge } from '../layout/TierBadge';
import confetti from 'canvas-confetti';
import { motion } from 'motion/react';

interface RankUpOverlayProps {
  newTier: Tier;
  newDivision?: Division;
  onClose: () => void;
}

export function RankUpOverlay({ newTier, newDivision, onClose }: RankUpOverlayProps) {
  const config = TIER_CONFIGS[newTier];

  useEffect(() => {
    // Fire confetti
    const duration = 3000;
    const animationEnd = Date.now() + duration;
    const defaults = { startVelocity: 30, spread: 360, ticks: 60, zIndex: 0 };

    function randomInRange(min: number, max: number) {
      return Math.random() * (max - min) + min;
    }

    const interval = setInterval(function() {
      const timeLeft = animationEnd - Date.now();

      if (timeLeft <= 0) {
        clearInterval(interval);
        return;
      }

      const particleCount = 50 * (timeLeft / duration);

      confetti({
        ...defaults,
        particleCount,
        origin: { x: randomInRange(0.1, 0.3), y: Math.random() - 0.2 }
      });
      confetti({
        ...defaults,
        particleCount,
        origin: { x: randomInRange(0.7, 0.9), y: Math.random() - 0.2 }
      });
    }, 250);

    // Auto close after 4 seconds
    const timeout = setTimeout(onClose, 4000);

    return () => {
      clearInterval(interval);
      clearTimeout(timeout);
    };
  }, [onClose]);

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm"
      onClick={onClose}
    >
      <motion.div
        initial={{ scale: 0.5, opacity: 0, y: 50 }}
        animate={{ scale: 1, opacity: 1, y: 0 }}
        transition={{ type: 'spring', duration: 0.6 }}
        className="relative max-w-md w-full mx-4"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Glow effect */}
        <div className={`absolute inset-0 bg-gradient-to-br ${config.gradient} blur-3xl opacity-50 rounded-3xl`} />

        {/* Content card */}
        <div className="relative bg-white rounded-3xl p-8 text-center shadow-2xl">
          <motion.div
            initial={{ scale: 0 }}
            animate={{ scale: 1 }}
            transition={{ delay: 0.3, type: 'spring' }}
          >
            <h2 className="text-3xl font-black text-gray-900 mb-2">RANK UP!</h2>
            <p className="text-gray-600 mb-6">You've ascended to</p>

            <div className="mb-6 flex justify-center">
              <TierBadge tier={newTier} division={newDivision} size="lg" showLabel={false} animated />
            </div>

            <div className={`text-4xl font-black mb-2 ${config.textColor} uppercase tracking-wider`}>
              {formatRank({ tier: newTier, division: newDivision })}
            </div>

            <p className="text-sm text-gray-500">
              Keep dominating the field!
            </p>
          </motion.div>
        </div>
      </motion.div>
    </motion.div>
  );
}
