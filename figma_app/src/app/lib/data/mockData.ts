import { Sport, FixtureStatus, DayOfWeek, TimeSlot, type Player, type Clan, type Fixture } from '../types';

export const MOCK_PLAYERS: Player[] = [
  { id: '1', username: 'striker_99', name: 'Alex Martinez', clanId: 'clan1' },
  { id: '2', username: 'goalkeeper_pro', name: 'Jordan Lee', clanId: 'clan1' },
  { id: '3', username: 'midfield_king', name: 'Taylor Swift', clanId: 'clan2' },
  { id: '4', username: 'defender_wall', name: 'Sam Rivera', clanId: 'clan2' },
  { id: '5', username: 'speedster', name: 'Chris Johnson', clanId: 'clan3' },
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
