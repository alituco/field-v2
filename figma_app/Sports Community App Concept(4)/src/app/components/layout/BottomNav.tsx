import { Home, Calendar, Shield, Trophy, User } from 'lucide-react';
import { Link, useLocation } from 'react-router';

const navItems = [
  { path: '/', icon: Home, label: 'Home' },
  { path: '/fixtures', icon: Calendar, label: 'Fixtures' },
  { path: '/clans', icon: Shield, label: 'Clans' },
  { path: '/leaderboard', icon: Trophy, label: 'Ranks' },
  { path: '/profile', icon: User, label: 'Profile' }
];

export function BottomNav() {
  const location = useLocation();

  return (
    <nav className="fixed bottom-0 left-0 right-0 bg-white border-t border-gray-200 h-16 flex items-center justify-around px-2 z-50">
      {navItems.map((item) => {
        const Icon = item.icon;
        const isActive = location.pathname === item.path;

        return (
          <Link
            key={item.path}
            to={item.path}
            className={`
              flex flex-col items-center justify-center gap-0.5 flex-1 h-full
              transition-colors duration-150
              ${isActive ? 'text-emerald-600' : 'text-gray-500'}
            `}
          >
            <Icon size={22} strokeWidth={isActive ? 2.5 : 2} />
            <span className={`text-[10px] font-medium ${isActive ? 'font-semibold' : ''}`}>
              {item.label}
            </span>
          </Link>
        );
      })}
    </nav>
  );
}
