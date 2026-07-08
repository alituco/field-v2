import { Sport, FixtureStatus, DayOfWeek, TimeSlot, type Player, type Clan, type Fixture } from '../types';

const AVATAR = {
  p1: 'https://images.unsplash.com/photo-1516224498413-84ecf3a1e7fd?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400',
  p2: 'https://images.unsplash.com/photo-1568834643193-f5373acc1659?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400',
  p3: 'https://images.unsplash.com/photo-1671680134709-4978c22fb916?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400',
  p4: 'https://images.unsplash.com/photo-1568927198336-e9ae04365910?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400',
  p5: 'https://images.unsplash.com/photo-1623452088642-5bd2f74780cc?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400',
  p6: 'https://images.unsplash.com/photo-1542393881816-df51684879df?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400',
  p7: 'https://images.unsplash.com/photo-1739567994955-6441a2fbb62d?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400',
  p8: 'https://images.unsplash.com/photo-1779304551934-3a25eaaa22dc?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400',
};

const HL = {
  a: 'https://images.unsplash.com/photo-1517466787929-bc90951d0974?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=600',
  b: 'https://images.unsplash.com/photo-1631478854728-b4a5479d1d36?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=600',
  c: 'https://images.unsplash.com/photo-1611122261270-3171e87a5567?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=600',
  d: 'https://images.unsplash.com/photo-1667842501559-6c03ae022505?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=600',
};

export const MOCK_PLAYERS: Player[] = [
  {
    id: '1',
    username: 'striker_99',
    name: 'Alex Martinez',
    clanId: 'clan1',
    position: 'Striker',
    avatar: AVATAR.p1,
    bio: 'Left foot, big moments. Chasing the Champion tier. ⚡',
    followingIds: ['2', '3', '5'],
    fanIds: ['2', '4', '6', '7', '8'],
    highlights: [
      { id: 'h1', title: 'Last-minute winner vs PHX', thumbnail: HL.a, duration: '0:38', views: 12400, clanTag: 'TFC' },
      { id: 'h2', title: 'Solo run & finish', thumbnail: HL.b, duration: '0:22', views: 8700, clanTag: 'TFC' },
      { id: 'h3', title: 'Hat-trick highlights', thumbnail: HL.c, duration: '1:05', views: 21300, clanTag: 'TFC' },
      { id: 'h4', title: 'Volley of the season', thumbnail: HL.d, duration: '0:16', views: 5100, clanTag: 'TFC' },
    ],
    career: [
      { id: 'c1', clanName: 'Thunder FC', tag: 'TFC', emblem: '⚡', period: '2024 – Present', apps: 34, goals: 41, current: true },
      { id: 'c2', clanName: 'Riverside Rovers', tag: 'RVR', emblem: '🌊', period: '2022 – 2024', apps: 58, goals: 52 },
      { id: 'c3', clanName: 'Sunset Strikers', tag: 'SUN', emblem: '🌅', period: '2020 – 2022', apps: 40, goals: 23 },
    ],
  },
  { id: '2', username: 'goalkeeper_pro', name: 'Jordan Lee', clanId: 'clan1', position: 'Goalkeeper', avatar: AVATAR.p2, fanIds: ['1'] },
  { id: '3', username: 'midfield_king', name: 'Taylor Reed', clanId: 'clan2', position: 'Midfielder', avatar: AVATAR.p3, fanIds: ['1'] },
  { id: '4', username: 'defender_wall', name: 'Sam Rivera', clanId: 'clan2', position: 'Defender', avatar: AVATAR.p4 },
  { id: '5', username: 'speedster', name: 'Chris Johnson', clanId: 'clan3', position: 'Winger', avatar: AVATAR.p5, fanIds: ['1'] },
  { id: '6', username: 'the_maestro', name: 'Diego Fuentes', clanId: 'clan2', position: 'Playmaker', avatar: AVATAR.p6 },
  { id: '7', username: 'iron_keeper', name: 'Marcus Bell', clanId: 'clan3', position: 'Goalkeeper', avatar: AVATAR.p7 },
  { id: '8', username: 'target_man', name: 'Kofi Mensah', clanId: 'clan3', position: 'Striker', avatar: AVATAR.p8 },
];

export const MOCK_CLANS: Clan[] = [
  {
    id: 'clan1',
    name: 'Thunder FC',
    tag: 'TFC',
    sport: Sport.SOCCER,
    emblem: '⚡',
    ownerId: '1',
    memberIds: ['1', '2'],
    skillRating: 1850,
    wins: 12,
    losses: 5
  },
  {
    id: 'clan2',
    name: 'Phoenix United',
    tag: 'PHX',
    sport: Sport.SOCCER,
    emblem: '🔥',
    ownerId: '3',
    memberIds: ['3', '4'],
    skillRating: 2650,
    wins: 18,
    losses: 3
  },
  {
    id: 'clan3',
    name: 'Storm Riders',
    tag: 'STM',
    sport: Sport.SOCCER,
    emblem: '🌪️',
    ownerId: '5',
    memberIds: ['5'],
    skillRating: 890,
    wins: 6,
    losses: 8
  }
];

export const MOCK_FIXTURES: Fixture[] = [
  {
    id: 'fix1',
    status: FixtureStatus.SCHEDULED,
    homeClanId: 'clan1',
    awayClanId: 'clan2',
    venue: 'Central Sports Complex',
    day: DayOfWeek.TUESDAY,
    timeSlot: TimeSlot.EARLY,
    date: '2026-06-10'
  },
  {
    id: 'fix2',
    status: FixtureStatus.LIVE,
    homeClanId: 'clan3',
    awayClanId: 'clan1',
    venue: 'Riverside Park',
    day: DayOfWeek.THURSDAY,
    timeSlot: TimeSlot.LATE,
    date: '2026-06-06',
    homeScore: 1,
    awayScore: 0,
    videoUrl: 'https://www.youtube.com/embed/jfKfPfyJRdk'
  },
  {
    id: 'fix6',
    status: FixtureStatus.OPEN,
    homeClanId: 'clan2',
    venue: 'Sunset Pitch',
    day: DayOfWeek.TUESDAY,
    timeSlot: TimeSlot.EARLY,
    date: '2026-06-15'
  },
  {
    id: 'fix7',
    status: FixtureStatus.OPEN,
    homeClanId: 'clan1',
    venue: 'Eastside Arena',
    day: DayOfWeek.THURSDAY,
    timeSlot: TimeSlot.LATE,
    date: '2026-06-17'
  },
  {
    id: 'fix3',
    status: FixtureStatus.FINAL,
    homeClanId: 'clan2',
    awayClanId: 'clan3',
    venue: 'Downtown Stadium',
    day: DayOfWeek.TUESDAY,
    timeSlot: TimeSlot.LATE,
    date: '2026-06-03',
    homeScore: 3,
    awayScore: 1,
    winnerId: 'clan2',
    homeSrChange: 24,
    awaySrChange: -18,
    videoUrl: 'https://www.youtube.com/embed/dQw4w9WgXcQ',
    scorers: [
      { playerId: '3', minute: 12, clanId: 'clan2', assistPlayerId: '4' },
      { playerId: '5', minute: 45, clanId: 'clan3' },
      { playerId: '4', minute: 78, clanId: 'clan2', assistPlayerId: '3' },
      { playerId: '3', minute: 89, clanId: 'clan2', assistPlayerId: '4' }
    ]
  },
  {
    id: 'fix4',
    status: FixtureStatus.FINAL,
    homeClanId: 'clan1',
    awayClanId: 'clan3',
    venue: 'Central Sports Complex',
    day: DayOfWeek.TUESDAY,
    timeSlot: TimeSlot.EARLY,
    date: '2026-06-01',
    homeScore: 4,
    awayScore: 0,
    winnerId: 'clan1',
    homeSrChange: 32,
    awaySrChange: -25,
    videoUrl: 'https://www.youtube.com/embed/dQw4w9WgXcQ',
    scorers: [
      { playerId: '1', minute: 5, clanId: 'clan1', assistPlayerId: '2' },
      { playerId: '1', minute: 23, clanId: 'clan1' },
      { playerId: '2', minute: 55, clanId: 'clan1', assistPlayerId: '1' },
      { playerId: '1', minute: 81, clanId: 'clan1', assistPlayerId: '2' }
    ]
  },
  {
    id: 'fix5',
    status: FixtureStatus.FINAL,
    homeClanId: 'clan2',
    awayClanId: 'clan1',
    venue: 'Downtown Stadium',
    day: DayOfWeek.THURSDAY,
    timeSlot: TimeSlot.LATE,
    date: '2026-05-25',
    homeScore: 2,
    awayScore: 2,
    homeSrChange: 5,
    awaySrChange: 5
  }
];
