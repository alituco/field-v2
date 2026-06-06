import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router';
import { motion, AnimatePresence } from 'motion/react';
import { ChevronLeft, Sparkles, Check, Zap, Shuffle } from 'lucide-react';
import confetti from 'canvas-confetti';
import { Button } from '@/app/components/ui/button';
import { Input } from '@/app/components/ui/input';
import { Textarea } from '@/app/components/ui/textarea';

/* ----------------------------- DATA ----------------------------- */

const EMBLEMS = [
  '⚽', '🦁', '🐉', '🦅', '🐺', '🦈', '🐅', '🦏',
  '⚡', '🔥', '🌪️', '❄️', '☄️', '💥', '🌊', '🌑',
  '👑', '🛡️', '⚔️', '🏆', '💀', '🎯', '🚀', '🪽',
];

interface ColorTheme {
  id: string;
  name: string;
  from: string;
  to: string;
  accent: string;
  ring: string;
}

const COLOR_THEMES: ColorTheme[] = [
  { id: 'pitch',    name: 'Pitch Green',     from: '#10b981', to: '#0369a1', accent: '#bbf7d0', ring: 'shadow-emerald-500/40' },
  { id: 'electric', name: 'Electric Blue',   from: '#22d3ee', to: '#4f46e5', accent: '#cffafe', ring: 'shadow-cyan-500/40' },
  { id: 'royal',    name: 'Royal Purple',    from: '#a855f7', to: '#581c87', accent: '#f5d0fe', ring: 'shadow-violet-500/40' },
  { id: 'sunset',   name: 'Sunset Strike',   from: '#f97316', to: '#db2777', accent: '#fed7aa', ring: 'shadow-orange-500/40' },
  { id: 'crimson',  name: 'Crimson Fury',    from: '#ef4444', to: '#7f1d1d', accent: '#fecaca', ring: 'shadow-red-500/40' },
  { id: 'gold',     name: 'Golden Age',      from: '#facc15', to: '#b45309', accent: '#fef3c7', ring: 'shadow-amber-500/40' },
  { id: 'shadow',   name: 'Shadow Realm',    from: '#1f2937', to: '#000000', accent: '#9ca3af', ring: 'shadow-slate-700/60' },
  { id: 'mint',     name: 'Arctic Mint',     from: '#5eead4', to: '#0d9488', accent: '#ccfbf1', ring: 'shadow-teal-500/40' },
];

type PatternId = 'solid' | 'stripes' | 'sash' | 'chevron' | 'pitch';
interface Pattern {
  id: PatternId;
  name: string;
  description: string;
}

const PATTERNS: Pattern[] = [
  { id: 'solid',   name: 'Solid',    description: 'Clean & classic' },
  { id: 'stripes', name: 'Stripes',  description: 'Classic kit vibes' },
  { id: 'sash',    name: 'Sash',     description: 'Old-school crest' },
  { id: 'chevron', name: 'Chevron',  description: 'Aggressive arrow' },
  { id: 'pitch',   name: 'Pitch',    description: 'Live on the field' },
];

const STEP_LABELS = ['Identity', 'Emblem', 'Kit', 'Glory'];

/* ----------------------------- PAGE ----------------------------- */

export default function CreateClan() {
  const navigate = useNavigate();
  const [step, setStep] = useState<0 | 1 | 2 | 3>(0);
  const [clanName, setClanName] = useState('');
  const [clanTag, setClanTag] = useState('');
  const [motto, setMotto] = useState('');
  const [emblem, setEmblem] = useState<string | null>(null);
  const [themeId, setThemeId] = useState<string>('pitch');
  const [patternId, setPatternId] = useState<PatternId>('solid');

  const theme = COLOR_THEMES.find(t => t.id === themeId)!;

  const canAdvance =
    (step === 0 && clanName.trim().length >= 2 && clanTag.trim().length >= 2) ||
    (step === 1 && !!emblem) ||
    (step === 2 && !!themeId && !!patternId);

  const handleNext = () => {
    if (!canAdvance) return;
    setStep(s => (s + 1) as 0 | 1 | 2 | 3);
  };

  const randomize = () => {
    setEmblem(EMBLEMS[Math.floor(Math.random() * EMBLEMS.length)]);
    setThemeId(COLOR_THEMES[Math.floor(Math.random() * COLOR_THEMES.length)].id);
    setPatternId(PATTERNS[Math.floor(Math.random() * PATTERNS.length)].id);
  };

  // Confetti on success step
  useEffect(() => {
    if (step !== 3) return;
    const duration = 3000;
    const end = Date.now() + duration;
    const rnd = (min: number, max: number) => Math.random() * (max - min) + min;
    const i = setInterval(() => {
      if (Date.now() > end) return clearInterval(i);
      const left = (end - Date.now()) / duration;
      confetti({ particleCount: 40 * left, spread: 360, startVelocity: 30, ticks: 60, origin: { x: rnd(0.1, 0.3), y: Math.random() - 0.1 }, colors: [theme.from, theme.to, theme.accent] });
      confetti({ particleCount: 40 * left, spread: 360, startVelocity: 30, ticks: 60, origin: { x: rnd(0.7, 0.9), y: Math.random() - 0.1 }, colors: [theme.from, theme.to, theme.accent] });
    }, 230);
    return () => clearInterval(i);
  }, [step, theme]);

  return (
    <div className="min-h-screen bg-gray-50 flex flex-col">
      {/* ───── HEADER + PROGRESS ───── */}
      <div className="bg-white/95 backdrop-blur-sm sticky top-0 z-30 border-b border-gray-100">
        <div className="px-4 py-3 flex items-center justify-between">
          {step > 0 && step < 3 ? (
            <button
              onClick={() => setStep((step - 1) as 0 | 1 | 2)}
              className="w-9 h-9 -ml-1 rounded-full bg-gray-50 flex items-center justify-center text-gray-700 active:scale-95 transition"
            >
              <ChevronLeft size={18} />
            </button>
          ) : step === 0 ? (
            <button
              onClick={() => navigate(-1)}
              className="w-9 h-9 -ml-1 rounded-full bg-gray-50 flex items-center justify-center text-gray-700 active:scale-95 transition"
            >
              <ChevronLeft size={18} />
            </button>
          ) : <div className="w-9" />}

          <div className="text-xs font-black uppercase tracking-[0.22em] text-gray-700">
            {STEP_LABELS[step]}
          </div>

          {step < 2 ? (
            <button
              onClick={randomize}
              className="inline-flex items-center gap-1 text-xs font-black uppercase tracking-wider text-emerald-600 active:scale-95 transition"
              title="Randomize"
            >
              <Shuffle size={14} /> Random
            </button>
          ) : <div className="w-16" />}
        </div>

        {/* Step dots */}
        <div className="px-4 pb-3 flex items-center gap-1.5">
          {STEP_LABELS.map((_, i) => (
            <div
              key={i}
              className={`flex-1 h-1.5 rounded-full transition-all duration-300 ${
                i < step ? 'bg-emerald-500' : i === step ? 'bg-gradient-to-r from-emerald-500 to-blue-600' : 'bg-gray-200'
              }`}
            />
          ))}
        </div>
      </div>

      {/* ───── CONTENT ───── */}
      <div className="flex-1 overflow-y-auto overflow-x-hidden pb-48">
        <AnimatePresence mode="wait">
          {/* STEP 0: IDENTITY */}
          {step === 0 && (
            <motion.div
              key="s0"
              initial={{ opacity: 0, x: 14 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -14 }}
              className="p-4 space-y-5"
            >
              <div className="text-center mt-2">
                <h2 className="text-3xl font-black tracking-tight text-gray-900 uppercase">Build your legacy</h2>
                <p className="text-sm text-gray-500 mt-1">Forge a name that strikes fear into rivals.</p>
              </div>

              <KitCard
                clanName={clanName || 'YOUR CLAN'}
                clanTag={clanTag || 'TAG'}
                motto={motto || 'Your motto here.'}
                emblem={emblem ?? '⚽'}
                theme={theme}
                pattern={patternId}
                preview
              />

              <div className="space-y-4">
                <Field label="Clan Name" hint={`${clanName.length}/24`}>
                  <Input
                    value={clanName}
                    onChange={e => setClanName(e.target.value)}
                    maxLength={24}
                    placeholder="Thunder FC"
                    className="bg-white border-gray-200 text-base py-5 font-bold"
                  />
                </Field>

                <Field label="Tag" hint={`${clanTag.length}/5`}>
                  <div className="relative">
                    <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 font-bold text-lg">[</span>
                    <Input
                      value={clanTag}
                      onChange={e => setClanTag(e.target.value.toUpperCase().replace(/\s/g, ''))}
                      maxLength={5}
                      placeholder="TFC"
                      className="bg-white border-gray-200 text-base py-5 pl-7 pr-7 text-center font-black uppercase tracking-widest"
                    />
                    <span className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 font-bold text-lg">]</span>
                  </div>
                </Field>

                <Field label="Motto" hint={`${motto.length}/60`} optional>
                  <Textarea
                    value={motto}
                    onChange={e => setMotto(e.target.value)}
                    maxLength={60}
                    placeholder="Never bend the knee."
                    rows={2}
                    className="bg-white border-gray-200 resize-none font-medium"
                  />
                </Field>
              </div>
            </motion.div>
          )}

          {/* STEP 1: EMBLEM */}
          {step === 1 && (
            <motion.div
              key="s1"
              initial={{ opacity: 0, x: 14 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -14 }}
              className="p-4 space-y-5"
            >
              <div className="text-center mt-2">
                <h2 className="text-3xl font-black tracking-tight text-gray-900 uppercase">Pick your emblem</h2>
                <p className="text-sm text-gray-500 mt-1">The symbol your rivals will learn to fear.</p>
              </div>

              <KitCard
                clanName={clanName}
                clanTag={clanTag}
                motto={motto}
                emblem={emblem ?? '⚽'}
                theme={theme}
                pattern={patternId}
              />

              <div className="grid grid-cols-6 gap-2">
                {EMBLEMS.map(e => {
                  const selected = emblem === e;
                  return (
                    <motion.button
                      key={e}
                      whileTap={{ scale: 0.9 }}
                      onClick={() => setEmblem(e)}
                      className={`aspect-square rounded-xl text-2xl flex items-center justify-center transition-all ${
                        selected
                          ? 'bg-gradient-to-br from-emerald-500 to-blue-600 shadow-md shadow-emerald-500/30 scale-105 ring-2 ring-white'
                          : 'bg-white border border-gray-200 hover:border-gray-300'
                      }`}
                    >
                      <span className={selected ? 'drop-shadow' : ''}>{e}</span>
                    </motion.button>
                  );
                })}
              </div>
            </motion.div>
          )}

          {/* STEP 2: KIT (color + pattern) */}
          {step === 2 && (
            <motion.div
              key="s2"
              initial={{ opacity: 0, x: 14 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -14 }}
              className="p-4 space-y-5"
            >
              <div className="text-center mt-2">
                <h2 className="text-3xl font-black tracking-tight text-gray-900 uppercase">Design the kit</h2>
                <p className="text-sm text-gray-500 mt-1">Color & pattern — make it unmistakable.</p>
              </div>

              <KitCard
                clanName={clanName}
                clanTag={clanTag}
                motto={motto}
                emblem={emblem ?? '⚽'}
                theme={theme}
                pattern={patternId}
              />

              {/* Color swatches */}
              <div>
                <SubLabel>Color</SubLabel>
                <div className="grid grid-cols-4 gap-2.5">
                  {COLOR_THEMES.map(t => (
                    <motion.button
                      key={t.id}
                      whileTap={{ scale: 0.92 }}
                      onClick={() => setThemeId(t.id)}
                      className={`relative aspect-square rounded-2xl overflow-hidden shadow-sm ${themeId === t.id ? 'ring-2 ring-gray-900 ring-offset-2' : ''}`}
                      style={{ background: `linear-gradient(135deg, ${t.from}, ${t.to})` }}
                    >
                      {themeId === t.id && (
                        <motion.div
                          initial={{ scale: 0 }}
                          animate={{ scale: 1 }}
                          className="absolute inset-0 flex items-center justify-center"
                        >
                          <div className="w-7 h-7 rounded-full bg-white flex items-center justify-center">
                            <Check size={16} className="text-gray-900" strokeWidth={3} />
                          </div>
                        </motion.div>
                      )}
                      <div className="absolute bottom-1 left-0 right-0 text-center text-[9px] font-black uppercase tracking-wider text-white/90 drop-shadow">
                        {t.name.split(' ')[0]}
                      </div>
                    </motion.button>
                  ))}
                </div>
              </div>

              {/* Patterns */}
              <div>
                <SubLabel>Pattern</SubLabel>
                <div className="grid grid-cols-5 gap-2">
                  {PATTERNS.map(p => (
                    <motion.button
                      key={p.id}
                      whileTap={{ scale: 0.92 }}
                      onClick={() => setPatternId(p.id)}
                      className={`flex flex-col items-center gap-1.5 p-2 rounded-xl transition-all ${
                        patternId === p.id
                          ? 'bg-gray-900 text-white shadow-md'
                          : 'bg-white border border-gray-200 text-gray-700'
                      }`}
                    >
                      <div className="w-full aspect-[3/2] rounded-md overflow-hidden">
                        <PatternSwatch pattern={p.id} theme={theme} />
                      </div>
                      <span className="text-[9px] font-black uppercase tracking-wider">{p.name}</span>
                    </motion.button>
                  ))}
                </div>
                <p className="mt-2 text-xs text-gray-500 text-center font-medium">
                  {PATTERNS.find(p => p.id === patternId)?.description}
                </p>
              </div>
            </motion.div>
          )}

          {/* STEP 3: REVEAL */}
          {step === 3 && (
            <motion.div
              key="s3"
              initial={{ opacity: 0, scale: 0.92 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ type: 'spring', stiffness: 200, damping: 18 }}
              className="p-4 flex flex-col items-center justify-center min-h-[80vh] gap-6"
            >
              <motion.div
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.15 }}
                className="inline-flex items-center gap-2 text-amber-500"
              >
                <Sparkles size={18} />
                <span className="text-xs font-black uppercase tracking-[0.22em]">A clan is born</span>
                <Sparkles size={18} />
              </motion.div>

              <motion.div
                initial={{ rotate: -6, scale: 0.85, opacity: 0 }}
                animate={{ rotate: 0, scale: 1, opacity: 1 }}
                transition={{ delay: 0.2, type: 'spring', stiffness: 160, damping: 12 }}
                className="w-full max-w-sm"
              >
                <KitCard
                  clanName={clanName}
                  clanTag={clanTag}
                  motto={motto}
                  emblem={emblem ?? '⚽'}
                  theme={theme}
                  pattern={patternId}
                  large
                />
              </motion.div>

              <motion.p
                initial={{ opacity: 0, y: 6 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.5 }}
                className="text-center text-gray-600 max-w-xs"
              >
                The pitch is yours. Rally your squad and stake your claim on the table.
              </motion.p>
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {/* ───── FIXED ACTION BUTTON ───── */}
      <div className="fixed bottom-16 left-0 right-0 p-4 bg-white/95 backdrop-blur-md border-t border-gray-100 z-40 shadow-2xl">
        {step < 3 ? (
          <Button
            disabled={!canAdvance}
            onClick={handleNext}
            className={`w-full py-6 font-black uppercase tracking-wider text-base rounded-2xl flex items-center justify-center gap-2 ${
              canAdvance
                ? 'bg-gradient-to-r from-emerald-600 via-emerald-500 to-blue-600 text-white shadow-lg shadow-emerald-500/30'
                : 'bg-gray-200 text-gray-400'
            }`}
          >
            {step === 2 ? <><Zap size={18} /> Forge Clan</> : 'Continue'}
          </Button>
        ) : (
          <Button
            onClick={() => navigate('/clans')}
            className="w-full py-6 font-black uppercase tracking-wider text-base rounded-2xl text-white shadow-lg"
            style={{ background: `linear-gradient(90deg, ${theme.from}, ${theme.to})` }}
          >
            Enter the Field
          </Button>
        )}
      </div>
    </div>
  );
}

/* ----------------------------- KIT CARD ----------------------------- */

interface KitCardProps {
  clanName: string;
  clanTag: string;
  motto: string;
  emblem: string;
  theme: ColorTheme;
  pattern: PatternId;
  large?: boolean;
  preview?: boolean;
}

function KitCard({ clanName, clanTag, motto, emblem, theme, pattern, large, preview }: KitCardProps) {
  return (
    <div
      className={`relative overflow-hidden rounded-3xl shadow-2xl ${theme.ring} text-white ${large ? 'aspect-[4/5]' : 'aspect-[5/3]'} ${preview ? 'opacity-90' : ''}`}
      style={{ background: `linear-gradient(135deg, ${theme.from}, ${theme.to})` }}
    >
      <PatternOverlay pattern={pattern} theme={theme} />

      {/* Top-right tag pill */}
      <div className="absolute top-4 right-4 px-2.5 py-1 rounded-full bg-black/25 backdrop-blur-sm">
        <span className="text-[10px] font-black uppercase tracking-[0.18em]">
          [{clanTag || '—'}]
        </span>
      </div>

      <div className="relative h-full flex flex-col items-center justify-center px-5 text-center">
        <motion.div
          key={emblem}
          initial={{ scale: 0.7, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          transition={{ type: 'spring', stiffness: 240, damping: 16 }}
          className={`${large ? 'w-28 h-28 text-6xl' : 'w-20 h-20 text-4xl'} rounded-3xl bg-white/15 backdrop-blur-md border-2 border-white/30 flex items-center justify-center shadow-2xl mb-3`}
        >
          {emblem}
        </motion.div>
        <h3 className={`font-black uppercase tracking-tight ${large ? 'text-3xl' : 'text-xl'} drop-shadow break-words max-w-full`}>
          {clanName || '—'}
        </h3>
        {motto && (
          <p className={`mt-1 italic font-medium text-white/85 ${large ? 'text-sm' : 'text-xs'} max-w-[80%]`}>
            "{motto}"
          </p>
        )}
      </div>

      {/* Stripe at bottom */}
      <div
        className="absolute bottom-0 left-0 right-0 h-1.5"
        style={{ background: `linear-gradient(90deg, ${theme.accent}, transparent)` }}
      />
    </div>
  );
}

/* ----------------------------- PATTERNS ----------------------------- */

function PatternOverlay({ pattern, theme }: { pattern: PatternId; theme: ColorTheme }) {
  if (pattern === 'solid') return null;

  if (pattern === 'stripes') {
    return (
      <div
        className="absolute inset-0 opacity-25"
        style={{
          backgroundImage: `repeating-linear-gradient(90deg, ${theme.accent} 0 12px, transparent 12px 32px)`,
        }}
      />
    );
  }

  if (pattern === 'sash') {
    return (
      <div
        className="absolute inset-0 opacity-30"
        style={{
          background: `linear-gradient(125deg, transparent 38%, ${theme.accent} 38%, ${theme.accent} 58%, transparent 58%)`,
        }}
      />
    );
  }

  if (pattern === 'chevron') {
    return (
      <svg className="absolute inset-0 w-full h-full opacity-30" preserveAspectRatio="none" viewBox="0 0 100 100">
        <path d="M -10 100 L 50 40 L 110 100 Z" fill={theme.accent} />
      </svg>
    );
  }

  if (pattern === 'pitch') {
    return (
      <svg className="absolute inset-0 w-full h-full opacity-25" preserveAspectRatio="none" viewBox="0 0 400 240">
        <line x1="200" y1="-20" x2="200" y2="260" stroke={theme.accent} strokeWidth="2" />
        <circle cx="200" cy="120" r="58" fill="none" stroke={theme.accent} strokeWidth="2" />
        <circle cx="200" cy="120" r="3" fill={theme.accent} />
        <path d="M 400 0 A 28 28 0 0 1 372 28" fill="none" stroke={theme.accent} strokeWidth="2" />
        <path d="M 0 240 A 28 28 0 0 1 28 212" fill="none" stroke={theme.accent} strokeWidth="2" />
      </svg>
    );
  }

  return null;
}

function PatternSwatch({ pattern, theme }: { pattern: PatternId; theme: ColorTheme }) {
  return (
    <div
      className="w-full h-full relative"
      style={{ background: `linear-gradient(135deg, ${theme.from}, ${theme.to})` }}
    >
      <PatternOverlay pattern={pattern} theme={theme} />
    </div>
  );
}

/* ----------------------------- FORM HELPERS ----------------------------- */

function Field({
  label, hint, optional, children,
}: { label: string; hint?: string; optional?: boolean; children: React.ReactNode }) {
  return (
    <div>
      <div className="flex items-center justify-between mb-1.5">
        <label className="text-xs font-black uppercase tracking-[0.18em] text-gray-700">
          {label}
          {optional && <span className="ml-1.5 text-[9px] font-bold tracking-widest text-gray-400">OPTIONAL</span>}
        </label>
        {hint && <span className="text-[10px] font-bold text-gray-400">{hint}</span>}
      </div>
      {children}
    </div>
  );
}

function SubLabel({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex items-center gap-2 mb-2.5">
      <span className="block w-1 h-4 rounded-full bg-gradient-to-b from-emerald-500 to-blue-600" />
      <h3 className="text-xs font-black uppercase tracking-[0.18em] text-gray-700">{children}</h3>
    </div>
  );
}
