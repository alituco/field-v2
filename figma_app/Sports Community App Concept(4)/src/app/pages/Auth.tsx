import { useState, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router';
import { motion, AnimatePresence } from 'motion/react';
import { ArrowLeft, ArrowRight, Phone, Shield, Sparkles } from 'lucide-react';
import { InputOTP, InputOTPGroup, InputOTPSlot } from '@/app/components/ui/input-otp';
import { setSession } from '@/app/lib/auth';

type Step = 'welcome' | 'phone' | 'otp' | 'name';

const stepOrder: Step[] = ['welcome', 'phone', 'otp', 'name'];

export default function Auth() {
  const navigate = useNavigate();
  const [step, setStep] = useState<Step>('welcome');
  const [direction, setDirection] = useState<1 | -1>(1);
  const [phone, setPhone] = useState('');
  const [otp, setOtp] = useState('');
  const [name, setName] = useState('');
  const [verifying, setVerifying] = useState(false);

  const go = (next: Step) => {
    setDirection(stepOrder.indexOf(next) > stepOrder.indexOf(step) ? 1 : -1);
    setStep(next);
  };

  const back = () => {
    if (step === 'phone') go('welcome');
    else if (step === 'otp') go('phone');
    else if (step === 'name') go('otp');
  };

  const submitPhone = () => {
    if (phone.replace(/\D/g, '').length < 10) return;
    go('otp');
  };

  // Auto-advance once OTP is complete
  useEffect(() => {
    if (step === 'otp' && otp.length === 6 && !verifying) {
      setVerifying(true);
      const t = setTimeout(() => {
        setVerifying(false);
        go('name');
      }, 850);
      return () => clearTimeout(t);
    }
  }, [otp, step]);

  const finish = () => {
    if (!name.trim()) return;
    setSession({
      phone: formatPhone(phone),
      name: name.trim(),
      createdAt: new Date().toISOString(),
    });
    navigate('/', { replace: true });
  };

  return (
    <div className="relative min-h-screen overflow-hidden bg-gradient-to-br from-emerald-950 via-emerald-900 to-blue-950 text-white">
      {/* Pitch lines decoration */}
      <PitchBackdrop />

      {/* Top bar */}
      <div className="relative z-10 flex items-center justify-between px-5 pt-6 pb-2">
        <AnimatePresence mode="wait" initial={false}>
          {step !== 'welcome' ? (
            <motion.button
              key="back"
              initial={{ opacity: 0, x: -10 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -10 }}
              whileTap={{ scale: 0.92 }}
              onClick={back}
              className="w-10 h-10 rounded-full bg-white/10 backdrop-blur border border-white/15 flex items-center justify-center"
            >
              <ArrowLeft size={18} />
            </motion.button>
          ) : (
            <div key="spacer" className="w-10 h-10" />
          )}
        </AnimatePresence>

        <StepDots current={step} />

        <div className="w-10 h-10" />
      </div>

      {/* Step content */}
      <div className="relative z-10 px-6 pt-8 pb-10">
        <AnimatePresence mode="wait" custom={direction} initial={false}>
          {step === 'welcome' && (
            <Slide key="welcome" direction={direction}>
              <Welcome onStart={() => go('phone')} />
            </Slide>
          )}
          {step === 'phone' && (
            <Slide key="phone" direction={direction}>
              <PhoneStep phone={phone} setPhone={setPhone} onNext={submitPhone} />
            </Slide>
          )}
          {step === 'otp' && (
            <Slide key="otp" direction={direction}>
              <OtpStep
                phone={formatPhone(phone)}
                otp={otp}
                setOtp={setOtp}
                verifying={verifying}
              />
            </Slide>
          )}
          {step === 'name' && (
            <Slide key="name" direction={direction}>
              <NameStep name={name} setName={setName} onFinish={finish} />
            </Slide>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}

/* ---------- Steps ---------- */

function Welcome({ onStart }: { onStart: () => void }) {
  return (
    <div className="flex flex-col items-start gap-8 pt-10">
      <motion.div
        initial={{ scale: 0.6, rotate: -20, opacity: 0 }}
        animate={{ scale: 1, rotate: 0, opacity: 1 }}
        transition={{ type: 'spring', stiffness: 180, damping: 14 }}
        className="relative w-20 h-20 rounded-3xl bg-gradient-to-br from-emerald-400 via-emerald-500 to-blue-500 shadow-2xl shadow-emerald-500/40 flex items-center justify-center"
      >
        <motion.span
          className="absolute inset-0 rounded-3xl ring-2 ring-white/30"
          animate={{ scale: [1, 1.25, 1], opacity: [0.7, 0, 0.7] }}
          transition={{ duration: 2.4, repeat: Infinity, ease: 'easeInOut' }}
        />
        <Sparkles size={36} strokeWidth={2.4} className="text-white" />
      </motion.div>

      <div>
        <motion.h1
          initial={{ y: 20, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          transition={{ delay: 0.1, type: 'spring', stiffness: 140, damping: 16 }}
          className="text-5xl font-black tracking-tight leading-[1.05]"
        >
          Welcome to{' '}
          <span className="bg-gradient-to-r from-emerald-300 via-emerald-200 to-blue-300 bg-clip-text text-transparent">
            Field.
          </span>
        </motion.h1>
        <motion.p
          initial={{ y: 20, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          transition={{ delay: 0.22, type: 'spring', stiffness: 140, damping: 16 }}
          className="mt-4 text-lg text-emerald-100/80 max-w-sm leading-relaxed"
        >
          Form your clan. Challenge rivals. Climb from Division 5 to Division 1.
        </motion.p>
      </div>

      <motion.div
        initial={{ y: 20, opacity: 0 }}
        animate={{ y: 0, opacity: 1 }}
        transition={{ delay: 0.35 }}
        className="w-full"
      >
        <PrimaryButton onClick={onStart} label="Get started" />
        <p className="text-center text-xs text-white/40 mt-4 uppercase tracking-widest">
          By continuing you agree to our Terms
        </p>
      </motion.div>
    </div>
  );
}

function PhoneStep({
  phone,
  setPhone,
  onNext,
}: {
  phone: string;
  setPhone: (s: string) => void;
  onNext: () => void;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const t = setTimeout(() => inputRef.current?.focus(), 320);
    return () => clearTimeout(t);
  }, []);

  const digits = phone.replace(/\D/g, '');
  const valid = digits.length >= 10;

  return (
    <StepShell
      icon={<Phone size={28} strokeWidth={2.4} />}
      title="What's your number?"
      subtitle="We'll send you a quick code to verify. No spam, ever."
    >
      <div className="w-full">
        <div className="flex items-center gap-3 rounded-2xl border border-white/15 bg-white/5 backdrop-blur-xl p-4 focus-within:border-emerald-300/60 focus-within:bg-white/10 transition-all">
          <div className="flex items-center gap-2 pr-3 border-r border-white/15">
            <span className="text-2xl">🇺🇸</span>
            <span className="text-lg font-bold tracking-tight">+1</span>
          </div>
          <input
            ref={inputRef}
            value={formatPhone(phone)}
            onChange={(e) => setPhone(e.target.value.replace(/\D/g, '').slice(0, 10))}
            inputMode="numeric"
            placeholder="(555) 123-4567"
            className="flex-1 bg-transparent outline-none text-2xl font-bold tracking-tight placeholder-white/30"
            onKeyDown={(e) => e.key === 'Enter' && valid && onNext()}
          />
        </div>

        <div className="mt-8">
          <PrimaryButton disabled={!valid} onClick={onNext} label="Send code" />
        </div>
      </div>
    </StepShell>
  );
}

function OtpStep({
  phone,
  otp,
  setOtp,
  verifying,
}: {
  phone: string;
  otp: string;
  setOtp: (s: string) => void;
  verifying: boolean;
}) {
  return (
    <StepShell
      icon={<Shield size={28} strokeWidth={2.4} />}
      title="Enter the code"
      subtitle={
        <>
          We sent a 6-digit code to <span className="font-bold text-white">+1 {phone}</span>
        </>
      }
    >
      <div className="w-full flex flex-col items-center gap-6">
        <InputOTP
          maxLength={6}
          value={otp}
          onChange={setOtp}
          autoFocus
          containerClassName="gap-2"
          disabled={verifying}
        >
          <InputOTPGroup className="gap-2">
            {[0, 1, 2, 3, 4, 5].map((i) => (
              <InputOTPSlot
                key={i}
                index={i}
                className="w-12 h-14 rounded-xl border-white/20 bg-white/5 backdrop-blur text-2xl font-black text-white shadow-lg shadow-emerald-500/0 data-[active=true]:border-emerald-300 data-[active=true]:ring-emerald-300/40 data-[active=true]:bg-white/10"
              />
            ))}
          </InputOTPGroup>
        </InputOTP>

        <AnimatePresence mode="wait">
          {verifying ? (
            <motion.div
              key="verifying"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              className="flex items-center gap-2 text-emerald-300 font-bold uppercase tracking-widest text-xs"
            >
              <motion.span
                className="w-2 h-2 rounded-full bg-emerald-300"
                animate={{ scale: [1, 1.5, 1], opacity: [1, 0.4, 1] }}
                transition={{ duration: 1, repeat: Infinity }}
              />
              Verifying
            </motion.div>
          ) : (
            <motion.button
              key="resend"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="text-sm text-white/50 hover:text-white transition uppercase tracking-widest font-bold"
            >
              Resend code
            </motion.button>
          )}
        </AnimatePresence>

        <p className="text-[11px] text-white/30 uppercase tracking-widest text-center">
          Demo · any 6 digits will work
        </p>
      </div>
    </StepShell>
  );
}

function NameStep({
  name,
  setName,
  onFinish,
}: {
  name: string;
  setName: (s: string) => void;
  onFinish: () => void;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const t = setTimeout(() => inputRef.current?.focus(), 320);
    return () => clearTimeout(t);
  }, []);

  const valid = name.trim().length >= 2;

  return (
    <StepShell
      icon={<Sparkles size={28} strokeWidth={2.4} />}
      title="What should we call you?"
      subtitle="This is how your clan and rivals will see you."
    >
      <div className="w-full">
        <div className="rounded-2xl border border-white/15 bg-white/5 backdrop-blur-xl p-4 focus-within:border-emerald-300/60 focus-within:bg-white/10 transition-all">
          <input
            ref={inputRef}
            value={name}
            onChange={(e) => setName(e.target.value.slice(0, 24))}
            placeholder="Your name"
            className="w-full bg-transparent outline-none text-2xl font-bold tracking-tight placeholder-white/30"
            onKeyDown={(e) => e.key === 'Enter' && valid && onFinish()}
          />
        </div>

        <div className="mt-8">
          <PrimaryButton
            disabled={!valid}
            onClick={onFinish}
            label="Enter the pitch"
            icon={<ArrowRight size={20} strokeWidth={3} />}
          />
        </div>
      </div>
    </StepShell>
  );
}

/* ---------- Building blocks ---------- */

function StepShell({
  icon,
  title,
  subtitle,
  children,
}: {
  icon: React.ReactNode;
  title: string;
  subtitle: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-start gap-8 pt-6">
      <motion.div
        initial={{ scale: 0.7, opacity: 0 }}
        animate={{ scale: 1, opacity: 1 }}
        transition={{ type: 'spring', stiffness: 200, damping: 14 }}
        className="w-14 h-14 rounded-2xl bg-gradient-to-br from-emerald-400 to-blue-500 shadow-lg shadow-emerald-500/40 flex items-center justify-center"
      >
        {icon}
      </motion.div>

      <div>
        <h1 className="text-4xl font-black tracking-tight leading-[1.1]">{title}</h1>
        <p className="mt-3 text-base text-emerald-100/70 max-w-sm leading-relaxed">
          {subtitle}
        </p>
      </div>

      {children}
    </div>
  );
}

function PrimaryButton({
  label,
  onClick,
  disabled,
  icon,
}: {
  label: string;
  onClick?: () => void;
  disabled?: boolean;
  icon?: React.ReactNode;
}) {
  return (
    <motion.button
      whileTap={disabled ? undefined : { scale: 0.97 }}
      onClick={onClick}
      disabled={disabled}
      className={`relative w-full h-14 rounded-2xl flex items-center justify-center gap-2 font-black uppercase tracking-wider text-sm transition-all ${
        disabled
          ? 'bg-white/10 text-white/30 cursor-not-allowed'
          : 'bg-gradient-to-r from-emerald-400 via-emerald-400 to-blue-400 text-emerald-950 shadow-xl shadow-emerald-500/40'
      }`}
    >
      <span>{label}</span>
      {!disabled && (icon ?? <ArrowRight size={18} strokeWidth={3} />)}
    </motion.button>
  );
}

function Slide({
  children,
  direction,
}: {
  children: React.ReactNode;
  direction: 1 | -1;
}) {
  return (
    <motion.div
      initial={{ x: direction * 40, opacity: 0 }}
      animate={{ x: 0, opacity: 1 }}
      exit={{ x: direction * -40, opacity: 0 }}
      transition={{ type: 'spring', stiffness: 260, damping: 28 }}
    >
      {children}
    </motion.div>
  );
}

function StepDots({ current }: { current: Step }) {
  const idx = stepOrder.indexOf(current);
  return (
    <div className="flex items-center gap-1.5">
      {stepOrder.map((s, i) => (
        <motion.span
          key={s}
          animate={{
            width: i === idx ? 24 : 6,
            opacity: i <= idx ? 1 : 0.3,
          }}
          transition={{ type: 'spring', stiffness: 260, damping: 26 }}
          className="h-1.5 rounded-full bg-emerald-300"
        />
      ))}
    </div>
  );
}

function PitchBackdrop() {
  return (
    <>
      {/* Soft glow orbs */}
      <motion.div
        className="absolute -top-32 -right-24 w-80 h-80 rounded-full bg-emerald-400/30 blur-3xl"
        animate={{ scale: [1, 1.15, 1], opacity: [0.5, 0.7, 0.5] }}
        transition={{ duration: 8, repeat: Infinity, ease: 'easeInOut' }}
      />
      <motion.div
        className="absolute -bottom-32 -left-24 w-96 h-96 rounded-full bg-blue-500/30 blur-3xl"
        animate={{ scale: [1, 1.1, 1], opacity: [0.4, 0.6, 0.4] }}
        transition={{ duration: 9, repeat: Infinity, ease: 'easeInOut', delay: 1 }}
      />
      {/* Pitch center circle */}
      <div className="absolute inset-0 flex items-center justify-center pointer-events-none opacity-[0.06]">
        <div className="w-[140%] aspect-square rounded-full border-2 border-white" />
      </div>
      <div className="absolute inset-x-0 top-1/2 h-px bg-white/[0.06]" />
    </>
  );
}

/* ---------- helpers ---------- */

function formatPhone(raw: string) {
  const d = raw.replace(/\D/g, '').slice(0, 10);
  if (d.length <= 3) return d;
  if (d.length <= 6) return `(${d.slice(0, 3)}) ${d.slice(3)}`;
  return `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}`;
}
