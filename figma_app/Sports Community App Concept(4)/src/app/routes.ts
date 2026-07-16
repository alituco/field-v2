import { createBrowserRouter, redirect } from 'react-router';
import { AppLayout } from './components/layout/AppLayout';
import Home from './pages/Home';
import Clans from './pages/Clans';
import ClanDetail from './pages/ClanDetail';
import Fixtures from './pages/Fixtures';
import FixtureDetail from './pages/FixtureDetail';
import Leaderboard from './pages/Leaderboard';
import Profile from './pages/Profile';
import Connections from './pages/Connections';
import DivisionArt from './pages/DivisionArt';
import CreateMatch from './pages/CreateMatch';
import CreateClan from './pages/CreateClan';
import Queue from './pages/Queue';
import QueueGames from './pages/QueueGames';
import QueueReview from './pages/QueueReview';
import QueuePay from './pages/QueuePay';
import QueueSuccess from './pages/QueueSuccess';
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
      { path: 'connections', Component: Connections },
      { path: 'division-art', Component: DivisionArt },
      { path: 'create-match', Component: CreateMatch },
      { path: 'create-clan', Component: CreateClan },
      { path: 'queue', Component: Queue },
      { path: 'queue/games', Component: QueueGames },
      { path: 'queue/review/:matchId', Component: QueueReview },
      { path: 'queue/pay/:matchId', Component: QueuePay },
      { path: 'queue/success/:matchId', Component: QueueSuccess }
    ]
  }
]);
