import { useEffect, useRef } from 'react';
import { Outlet, useLocation } from 'react-router';
import { BottomNav } from './BottomNav';

function ScrollReset() {
  const { pathname } = useLocation();
  const mainRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    // Grab the scrollable container and snap it to the top on every route change.
    const el = document.getElementById('main-scroll');
    if (el) el.scrollTop = 0;
  }, [pathname]);

  return null;
}

export function AppLayout() {
  return (
    <div className="flex flex-col h-screen bg-gray-50">
      <ScrollReset />
      <main id="main-scroll" className="flex-1 overflow-y-auto pb-20">
        <Outlet />
      </main>
      <BottomNav />
    </div>
  );
}
