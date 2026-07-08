import { Outlet } from 'react-router';
import { BottomNav } from './BottomNav';

export function AppLayout() {
  return (
    <div className="flex flex-col h-screen bg-gray-50">
      <main className="flex-1 overflow-y-auto pb-20">
        <Outlet />
      </main>
      <BottomNav />
    </div>
  );
}
