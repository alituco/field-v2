import { createBrowserRouter, redirect } from 'react-router';
import { AppLayout } from './components/layout/AppLayout';
import Home from './pages/Home';
import Clans from './pages/Clans';
import ClanDetail from './pages/ClanDetail';
import Fixtures from './pages/Fixtures';
import FixtureDetail from './pages/FixtureDetail';
import Leaderboard from './pages/Leaderboard';
import Profile from './pages/Profile';
import CreateMatch from './pages/CreateMatch';
import CreateClan from './pages/CreateClan';
import Auth from './pages/Auth';
import { isAuthenticated } from './lib/auth';

const requireAuth = () => {
  if (!isAuthenticated()) throw redirect('/auth');
  return null;
};

const requireGuest = () => {
  if (isAuthenticated()) throw redirect('/');
  return null;
};

export const router = createBrowserRouter([
  {
    path: '/auth',
    Component: Auth,
    loader: requireGuest,
  },
  {
    path: '/',
    Component: AppLayout,
    loader: requireAuth,
    children: [
      { index: true, Component: Home },
      { path: 'clans', Component: Clans },
      { path: 'clans/:clanId', Component: ClanDetail },
      { path: 'fixtures', Component: Fixtures },
      { path: 'fixtures/:fixtureId', Component: FixtureDetail },
      { path: 'leaderboard', Component: Leaderboard },
      { path: 'profile', Component: Profile },
      { path: 'create-match', Component: CreateMatch },
      { path: 'create-clan', Component: CreateClan }
    ]
  }
]);
