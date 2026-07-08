import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router';
import { motion, AnimatePresence } from 'motion/react';
import { format, isBefore, startOfDay } from 'date-fns';
import { ChevronLeft, Calendar as CalendarIcon, Clock, MapPin, Apple, CheckCircle2, Swords, Plus, Shield } from 'lucide-react';
import { DayPicker } from 'react-day-picker';
import confetti from 'canvas-confetti';

import { Button } from '@/app/components/ui/button';
import { TimeSlot, FixtureStatus, Fixture } from '@/app/lib/types';
import { MOCK_FIXTURES, MOCK_CLANS } from '@/app/lib/data/mockData';
import { FixtureCard } from '@/app/components/fixture/FixtureCard';
import 'react-day-picker/dist/style.css';

export default function CreateMatch() {
  const navigate = useNavigate();
  const [step, setStep] = useState<0 | 1 | 2 | 3>(0);
  const [selectedDate, setSelectedDate] = useState<Date | undefined>(undefined);
  const [selectedTime, setSelectedTime] = useState<TimeSlot | undefined>(undefined);
  const [selectedFixtureToJoin, setSelectedFixtureToJoin] = useState<Fixture | null>(null);
  const [isProcessing, setIsProcessing] = useState(false);

  // Filter for OPEN matches (simulating "next 2 weeks")
  const openFixtures = MOCK_FIXTURES.filter(f => f.status === FixtureStatus.OPEN);

  // Group fixtures by date
  const fixturesByDate = openFixtures.reduce((acc, fixture) => {
    const dateKey = format(new Date(fixture.date), 'yyyy-MM-dd');
    if (!acc[dateKey]) {
      acc[dateKey] = [];
    }
    acc[dateKey].push(fixture);
    return acc;
  }, {} as Record<string, Fixture[]>);

  // Sort dates chronologically
  const sortedDates = Object.keys(fixturesByDate).sort();

  // Disable days that are not Tuesday (2) or Thursday (4), or are in the past
  const disabledDays = (date: Date) => {
    const day = date.getDay();
    const isPast = isBefore(date, startOfDay(new Date()));
    return isPast || (day !== 2 && day !== 4);
  };

  const handleNext = () => {
    if (step === 1 && selectedDate && selectedTime) {
      setStep(2);
    }
  };

  const handleJoinClick = (fixture: Fixture) => {
    setSelectedFixtureToJoin(fixture);
    setSelectedDate(new Date(fixture.date));
    setSelectedTime(fixture.timeSlot);
    setStep(2); // Jump straight to checkout for joining
  };

  const handleCreateClick = () => {
    setSelectedFixtureToJoin(null);
    setSelectedDate(undefined);
    setSelectedTime(undefined);
    setStep(1); // Go to time selection
  };

  const handlePayment = () => {
    setIsProcessing(true);
    // Simulate Apple Pay processing delay
    setTimeout(() => {
      setIsProcessing(false);
      setStep(3);
    }, 2000);
  };

  useEffect(() => {
    if (step === 3) {
      // Fire confetti
      const duration = 3 * 1000;
      const animationEnd = Date.now() + duration;
      const defaults = { startVelocity: 30, spread: 360, ticks: 60, zIndex: 0 };

      const randomInRange = (min: number, max: number) => Math.random() * (max - min) + min;

      const interval: any = setInterval(function () {
        const timeLeft = animationEnd - Date.now();

        if (timeLeft <= 0) {
          return clearInterval(interval);
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

      return () => clearInterval(interval);
    }
  }, [step]);

  return (
    <div className="min-h-screen bg-gray-50 flex flex-col">
      {/* Header */}
      <div className="bg-white px-4 py-4 flex items-center shadow-sm sticky top-0 z-10">
        {step === 0 ? (
           <button 
             onClick={() => navigate(-1)} 
             className="p-2 -ml-2 rounded-full hover:bg-gray-100 transition-colors text-gray-700"
           >
             <ChevronLeft size={24} />
           </button>
        ) : step < 3 ? (
          <button 
            onClick={() => step === 1 ? setStep(0) : step === 2 && selectedFixtureToJoin ? setStep(0) : setStep(1)} 
            className="p-2 -ml-2 rounded-full hover:bg-gray-100 transition-colors text-gray-700"
          >
            <ChevronLeft size={24} />
          </button>
        ) : (
          <div className="w-10"></div> // Spacer for alignment
        )}
        <h1 className="flex-1 text-center text-lg font-bold text-gray-900">
          {step === 0 ? 'Play' : step === 1 ? 'Select Time' : step === 2 ? 'Checkout' : 'Success'}
        </h1>
        <div className="w-10"></div>
      </div>

      {/* Main Content */}
      <div className="flex-1 overflow-y-auto overflow-x-hidden relative">
        <AnimatePresence mode="wait">
          
          {step === 0 && (
            <motion.div 
              key="step0"
              initial={{ opacity: 0, x: -20 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -20 }}
              className="p-4 space-y-6 pb-32"
            >
              <div className="bg-gradient-to-br from-emerald-600 to-teal-500 rounded-3xl p-6 text-white shadow-xl relative overflow-hidden">
                <div className="absolute top-0 right-0 w-48 h-48 bg-white/10 rounded-full blur-3xl -translate-y-1/2 translate-x-1/3" />
                <div className="relative z-10">
                  <h2 className="text-2xl font-black mb-2">Ready to Clash?</h2>
                  <p className="text-emerald-50 mb-6 max-w-[250px]">Challenge open teams or host a new match to climb the ranks.</p>
                  
                  <Button 
                    onClick={handleCreateClick}
                    className="w-full bg-white text-emerald-600 hover:bg-emerald-50 font-bold py-6 rounded-xl flex items-center justify-center gap-2 shadow-lg"
                  >
                    <Plus size={20} />
                    Host a Match
                  </Button>
                </div>
                <Swords size={120} className="absolute -bottom-6 -right-6 text-white opacity-10" />
              </div>

              <div>
                <div className="flex items-center justify-between mb-4">
                  <h3 className="text-xl font-bold text-gray-900">Open Matches</h3>
                  <span className="text-sm font-bold text-emerald-600 bg-emerald-50 px-3 py-1 rounded-full">
                    Next 14 Days
                  </span>
                </div>
                
                {openFixtures.length > 0 ? (
                  <div className="space-y-6">
                    {sortedDates.map(dateKey => {
                      const fixtures = fixturesByDate[dateKey];
                      const dateObj = new Date(dateKey);
                      return (
                        <div key={dateKey} className="space-y-3">
                          <h4 className="text-sm font-bold text-gray-500 uppercase tracking-wider px-1">
                            {format(dateObj, 'EEEE, MMMM do')}
                          </h4>
                          <div className="space-y-3">
                            {fixtures.map(fixture => {
                              const homeClan = MOCK_CLANS.find(c => c.id === fixture.homeClanId)!;
                              return (
                                <motion.div
                                  key={fixture.id}
                                  whileHover={{ scale: 1.01 }}
                                  whileTap={{ scale: 0.98 }}
                                >
                                  <div className="bg-white border border-gray-100 rounded-2xl overflow-hidden shadow-sm hover:shadow-md transition-shadow">
                                    <div className="pointer-events-none">
                                      <FixtureCard
                                        fixture={fixture}
                                        homeClan={homeClan}
                                      />
                                    </div>
                                    <div className="p-3 bg-gray-50 border-t border-gray-100">
                                      <Button
                                        onClick={() => handleJoinClick(fixture)}
                                        className="w-full bg-black hover:bg-gray-800 text-white font-bold rounded-xl"
                                      >
                                        Join Match
                                      </Button>
                                    </div>
                                  </div>
                                </motion.div>
                              );
                            })}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                ) : (
                  <div className="text-center py-12 bg-white rounded-2xl border border-dashed border-gray-200">
                    <Shield className="mx-auto text-gray-300 mb-3" size={40} />
                    <p className="text-gray-500 font-medium">No open matches available.</p>
                    <p className="text-sm text-gray-400">Host one to get the ball rolling!</p>
                  </div>
                )}
              </div>
            </motion.div>
          )}

          {step === 1 && (
            <motion.div 
              key="step1"
              initial={{ opacity: 0, x: 20 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -20 }}
              className="p-4 space-y-8 pb-32"
            >
              <div>
                <h2 className="text-xl font-bold text-gray-900 mb-2">Pick a Date</h2>
                <p className="text-sm text-gray-500 mb-4">Matches are currently only available on Tuesdays and Thursdays.</p>
                <div className="bg-white rounded-2xl p-4 shadow-sm flex justify-center border border-gray-100">
                  <DayPicker
                    mode="single"
                    selected={selectedDate}
                    onSelect={setSelectedDate}
                    disabled={disabledDays}
                    className="custom-calendar text-gray-800"
                    modifiersClassNames={{
                      selected: 'bg-emerald-500 text-white rounded-full font-bold',
                      today: 'text-emerald-600 font-bold'
                    }}
                  />
                </div>
              </div>

              <AnimatePresence>
                {selectedDate && (
                  <motion.div
                    initial={{ opacity: 0, height: 0 }}
                    animate={{ opacity: 1, height: 'auto' }}
                  >
                    <h2 className="text-xl font-bold text-gray-900 mb-4">Pick a Time Slot</h2>
                    <div className="space-y-3">
                      {[TimeSlot.EARLY, TimeSlot.LATE].map((slot) => (
                        <div 
                          key={slot}
                          onClick={() => setSelectedTime(slot)}
                          className={`p-4 rounded-xl border-2 transition-all cursor-pointer flex items-center justify-between ${
                            selectedTime === slot 
                              ? 'border-emerald-500 bg-emerald-50' 
                              : 'border-gray-200 bg-white hover:border-emerald-300'
                          }`}
                        >
                          <div className="flex items-center gap-3">
                            <Clock className={selectedTime === slot ? 'text-emerald-600' : 'text-gray-400'} size={20} />
                            <span className={`font-semibold ${selectedTime === slot ? 'text-emerald-900' : 'text-gray-700'}`}>
                              {slot}
                            </span>
                          </div>
                          <div className={`w-5 h-5 rounded-full border-2 flex items-center justify-center ${
                            selectedTime === slot ? 'border-emerald-500' : 'border-gray-300'
                          }`}>
                            {selectedTime === slot && <div className="w-2.5 h-2.5 rounded-full bg-emerald-500" />}
                          </div>
                        </div>
                      ))}
                    </div>
                  </motion.div>
                )}
              </AnimatePresence>
            </motion.div>
          )}

          {step === 2 && selectedDate && selectedTime && (
            <motion.div 
              key="step2"
              initial={{ opacity: 0, x: 20 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -20 }}
              className="p-4 space-y-6 pb-32"
            >
              <div className="bg-white rounded-2xl p-6 shadow-sm border border-gray-100">
                <h2 className="text-xl font-bold text-gray-900 mb-6">
                  {selectedFixtureToJoin ? 'Join Match Summary' : 'Match Summary'}
                </h2>
                
                <div className="space-y-4">
                  <div className="flex items-start gap-4">
                    <div className="bg-blue-100 p-2 rounded-lg text-blue-600">
                      <CalendarIcon size={20} />
                    </div>
                    <div>
                      <p className="text-sm text-gray-500 font-medium">Date</p>
                      <p className="text-gray-900 font-semibold">{format(selectedDate, 'EEEE, MMMM do, yyyy')}</p>
                    </div>
                  </div>
                  
                  <div className="flex items-start gap-4">
                    <div className="bg-orange-100 p-2 rounded-lg text-orange-600">
                      <Clock size={20} />
                    </div>
                    <div>
                      <p className="text-sm text-gray-500 font-medium">Time</p>
                      <p className="text-gray-900 font-semibold">{selectedTime}</p>
                    </div>
                  </div>
                  
                  <div className="flex items-start gap-4">
                    <div className="bg-emerald-100 p-2 rounded-lg text-emerald-600">
                      <MapPin size={20} />
                    </div>
                    <div>
                      <p className="text-sm text-gray-500 font-medium">Venue</p>
                      <p className="text-gray-900 font-semibold">
                        {selectedFixtureToJoin ? selectedFixtureToJoin.venue : 'Central Sports Complex'}
                      </p>
                    </div>
                  </div>
                </div>

                <div className="my-6 border-t border-gray-100 border-dashed"></div>

                <div className="flex justify-between items-center">
                  <span className="text-gray-500 font-medium">Total Amount</span>
                  <span className="text-2xl font-black text-gray-900">20 BHD</span>
                </div>
              </div>

              <div className="bg-emerald-50 rounded-xl p-4 text-emerald-800 text-sm font-medium flex gap-2">
                <div className="shrink-0 mt-0.5">💡</div>
                <p>
                  {selectedFixtureToJoin 
                    ? 'By joining this match, your clan will be scheduled to face the opponent and it will lock in the fixture.' 
                    : 'By creating this match, it will be listed as "Open" on the fixtures board for other clans to challenge.'}
                </p>
              </div>
            </motion.div>
          )}

          {step === 3 && (
            <motion.div 
              key="step3"
              initial={{ opacity: 0, scale: 0.95 }}
              animate={{ opacity: 1, scale: 1 }}
              className="p-4 flex flex-col items-center justify-center min-h-[70vh] text-center space-y-6"
            >
              <motion.div 
                initial={{ scale: 0 }}
                animate={{ scale: 1 }}
                transition={{ type: 'spring', delay: 0.2 }}
                className="w-24 h-24 bg-gradient-to-tr from-emerald-500 to-teal-400 rounded-full flex items-center justify-center text-white shadow-xl shadow-emerald-500/30 mb-4"
              >
                <CheckCircle2 size={48} />
              </motion.div>
              
              <div>
                <motion.h2 
                  initial={{ opacity: 0, y: 10 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ delay: 0.4 }}
                  className="text-3xl font-black text-gray-900 mb-2"
                >
                  {selectedFixtureToJoin ? 'Match Joined!' : 'Match Created!'}
                </motion.h2>
                <motion.p 
                  initial={{ opacity: 0, y: 10 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ delay: 0.5 }}
                  className="text-gray-500 text-lg max-w-[280px] mx-auto"
                >
                  {selectedFixtureToJoin 
                    ? 'Your game is on the board. Get ready for battle!' 
                    : 'Your match is now open for challenges!'}
                </motion.p>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {/* Footer Fixed Action */}
      {step === 1 && (
        <div className="fixed bottom-0 left-0 right-0 p-4 bg-white/80 backdrop-blur-md border-t border-gray-100 z-[60]">
          <Button
            className="w-full py-6 text-lg font-bold rounded-xl bg-gradient-to-r from-emerald-500 to-teal-500 hover:from-emerald-600 hover:to-teal-600 text-white shadow-lg shadow-emerald-500/30"
            disabled={!selectedDate || !selectedTime}
            onClick={handleNext}
          >
            Continue
          </Button>
        </div>
      )}
      
      {step === 2 && (
        <div className="fixed bottom-0 left-0 right-0 p-4 bg-white/80 backdrop-blur-md border-t border-gray-100 z-[60]">
          <Button
            className="w-full py-6 text-lg font-bold rounded-xl bg-black hover:bg-gray-900 text-white flex items-center justify-center gap-2"
            onClick={handlePayment}
            disabled={isProcessing}
          >
            {isProcessing ? (
              <div className="w-6 h-6 border-2 border-white/30 border-t-white rounded-full animate-spin" />
            ) : (
              <>
                <Apple size={22} className="-mt-1" />
                Pay 20 BHD
              </>
            )}
          </Button>
        </div>
      )}
      
      {step === 3 && (
        <div className="fixed bottom-0 left-0 right-0 p-4 bg-white/80 backdrop-blur-md z-[60]">
          <Button
            className="w-full py-6 text-lg font-bold rounded-xl bg-gradient-to-r from-emerald-600 to-teal-500 hover:from-emerald-700 hover:to-teal-600 text-white shadow-lg shadow-emerald-500/30"
            onClick={() => navigate('/')}
          >
            Back to Home
          </Button>
        </div>
      )}
      
      <style>{`
        .custom-calendar .rdp-day_selected, 
        .custom-calendar .rdp-day_selected:focus-visible, 
        .custom-calendar .rdp-day_selected:hover {
          background-color: var(--color-emerald-500);
          color: white;
        }
        .custom-calendar .rdp-button:hover:not([disabled]):not(.rdp-day_selected) {
          background-color: var(--color-emerald-50);
        }
        .custom-calendar .rdp-day_today {
          font-weight: 700;
          color: var(--color-emerald-600);
        }
      `}</style>
    </div>
  );
}