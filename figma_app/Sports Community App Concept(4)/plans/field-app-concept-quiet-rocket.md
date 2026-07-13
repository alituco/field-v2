# Field - Gamified Sports Clan App Implementation Plan

## Context

Building a mobile-first sports community app where players form clans, challenge each other to matches at real venues, and climb a skill-tier ladder. V1 is frontend-only with localStorage persistence - no backend, auth, or payments. Focus is on gamified but clean UI for soccer/football.

**Core mechanics:**
- Players join one clan at a time
- Clans challenge each other to matches (Tue/Thu evenings at fixed time slots)
- Win = +80 rating, Loss = -60 rating
- Rating maps to tiers: Bronze → Silver → Gold → Platinum → Diamond → Master → Champion
- Rank-up triggers celebration overlay with confetti

## Technical Approach




## File Structure

```
/src/app/
├── App.tsx                               # Router + PlayerContext provider
├── pages/
│   ├── Onboarding.tsx                   # First-time player creation
│   ├── Home.tsx                         # Main feed with clan + fixtures
│   ├── Clans.tsx                        # Browse/search all clans
│   ├── ClanDetail.tsx                   # Single clan view with chat
│   ├── Fixtures.tsx                     # Browse/filter all matches
│   ├── FixtureDetail.tsx                # Single match view
│   ├── Leaderboard.tsx                  # Global clan rankings
│   ├── Profile.tsx                      # Current player profile
│   └── PlayerDetail.tsx                 # View other players
├── components/
│   ├── ui/                              # [EXISTING] Shadcn components
│   ├── layout/
│   │   ├── AppLayout.tsx                # Main wrapper with bottom nav
│   │   ├── BottomNav.tsx                # Mobile navigation (5 tabs)
│   │   ├── PageHeader.tsx               # Reusable header with back button
│   │   └── TierBadge.tsx                # Tier indicator (color + icon)
│   ├── clan/
│   │   ├── ClanCard.tsx                 # Summary card for lists
│   │   ├── ClanHeader.tsx               # Hero section with stats
│   │   ├── ClanMemberList.tsx           # Member list with owner badge
│   │   ├── ClanStats.tsx                # Win/loss/rating display
│   │   ├── JoinRequestCard.tsx          # Pending request item
│   │   ├── CreateClanDialog.tsx         # Modal for creation
│   │   └── EditClanDialog.tsx           # Modal for editing
│   ├── player/
│   │   ├── PlayerCard.tsx               # Player summary card
│   │   ├── PlayerAvatar.tsx             # Avatar with tier overlay
│   │   └── EditProfileDialog.tsx        # Profile editor
│   ├── fixture/
│   │   ├── FixtureCard.tsx              # Match card (adapts by status)
│   │   ├── FixtureList.tsx              # Scrollable list with filters
│   │   ├── CreateFixtureDialog.tsx      # Create match form
│   │   ├── JoinFixtureDialog.tsx        # Join as away team
│   │   ├── RecordResultDialog.tsx       # Score input + submit
│   │   └── FixtureFilters.tsx           # Filter chips (day/time/status)
│   ├── chat/
│   │   ├── ChatBubble.tsx               # Message item
│   │   ├── ChatInput.tsx                # Input field + send button
│   │   └── ChatThread.tsx               # Message list + input
│   ├── leaderboard/
│   │   ├── LeaderboardTable.tsx         # Ranked clan list
│   │   └── LeaderboardRow.tsx           # Individual row with rank/tier
│   ├── onboarding/
│   │   ├── WelcomeScreen.tsx            # Splash with sport selection
│   │   └── CreatePlayerForm.tsx         # Player details form
│   └── celebrations/
│       ├── RankUpOverlay.tsx            # Full-screen tier promotion
│       └── confetti.ts                  # canvas-confetti wrapper
├── lib/
│   ├── types/index.ts                   # All TypeScript interfaces
│   ├── constants/
│   │   ├── tiers.ts                     # TIER_CONFIGS array
│   │   ├── sports.ts                    # Sport enum (SOCCER for V1)
│   │   └── timeSlots.ts                 # DayOfWeek + TimeSlot enums
│   ├── context/
│   │   └── PlayerContext.tsx            # Global current player
│   ├── hooks/
│   │   ├── useLocalStorage.ts           # Generic reactive hook
│   │   ├── useCurrentPlayer.ts          # Access context
│   │   ├── usePlayers.ts                # Player CRUD
│   │   ├── useClans.ts                  # Clan CRUD + join/approve/kick
│   │   ├── useFixtures.ts               # Fixture CRUD + recordResult
│   │   ├── useChat.ts                   # Chat message operations
│   │   └── useTierSystem.ts             # getTier, checkRankUp, etc.
│   ├── utils/
│   │   ├── tierSystem.ts                # Rating → Tier mapping
│   │   ├── fixtureUtils.ts              # Match scheduling helpers
│   │   ├── dateUtils.ts                 # Date formatting
│   │   └── validation.ts                # Form rules
│   └── data/
│       ├── storage.ts                   # localStorage keys
│       └── mockData.ts                  # Seed data for demo
```

## Type Definitions

Core interfaces (all in `/src/app/lib/types/index.ts`):

**Player**
- id, username, name, dob, bio, phone, avatar, banner, favoriteSport
- clanId (optional - belongs to ONE clan)
- createdAt, updatedAt

**Clan**
- id, name, tag, sport, description, emblem
- ownerId, memberIds[], pendingRequestIds[]
- skillRating (0-5000+), wins, losses
- createdAt, updatedAt

**Fixture**
- id, status (OPEN | SCHEDULED | LIVE | FINAL)
- homeClanId, awayClanId (optional when OPEN)
- venue, day (Tue/Thu), timeSlot (6-7:30pm / 7:30-9pm), date
- homeScore, awayScore, winnerId
- createdById, createdAt, updatedAt

**ChatMessage**
- id, clanId, playerId, text, timestamp

**TierConfig**
- tier, minRating, maxRating, color, bgColor, icon (Lucide)

## Routes

```tsx
<Route path="/" element={<AppLayout />}>
  <Route index element={<Home />} />
  <Route path="clans" element={<Clans />} />
  <Route path="clans/:clanId" element={<ClanDetail />} />
  <Route path="fixtures" element={<Fixtures />} />
  <Route path="fixtures/:fixtureId" element={<FixtureDetail />} />
  <Route path="leaderboard" element={<Leaderboard />} />
  <Route path="profile" element={<Profile />} />
  <Route path="players/:playerId" element={<PlayerDetail />} />
</Route>
<Route path="onboarding" element={<Onboarding />} />
```

**Bottom Nav tabs:**
1. Home (House icon)
2. Fixtures (Calendar icon)
3. Clans (Shield icon)
4. Leaderboard (Trophy icon)
5. Profile (User icon)

## Tier System

Rating thresholds:
- Bronze: 0-499
- Silver: 500-999
- Gold: 1000-1499
- Platinum: 1500-2499
- Diamond: 2500-3499
- Master: 3500-4499
- Champion: 4500+

Each tier has color, bgColor, and icon (from Lucide React).

**Rank-up flow:**
1. `recordResult()` calculates new ratings
2. Detects tier boundary crossing
3. Returns `RatingChange` with `didRankUp: true`
4. Trigger `RankUpOverlay` (full-screen modal)
5. Fire `canvas-confetti`
6. Auto-dismiss after 3-5 seconds

## Critical User Flows

### Onboarding
1. Check localStorage for `field:currentPlayerId`
2. If missing → redirect to `/onboarding`
3. Show WelcomeScreen → CreatePlayerForm
4. Save player → set as currentPlayer → redirect to `/`

### Create Clan
1. Player taps FAB → CreateClanDialog opens
2. Form: name, tag, emblem, description
3. Submit → clan created, player becomes owner and first member
4. Navigate to `/clans/:clanId`

### Join Clan
1. Player views Clan Detail → taps "Request to Join"
2. Player added to `pendingRequestIds`
3. Owner sees request in UI → taps "Approve"
4. Player moved to `memberIds`, player's `clanId` updated

### Create Match
1. Clan owner taps "Create Match" FAB
2. Form: venue, day, time slot, date
3. Submit → fixture created with status=OPEN, homeClanId set
4. Navigate to `/fixtures/:fixtureId`

### Join Match (as Away Team)
1. Clan owner browses Fixtures page → finds OPEN match
2. Taps "Join Match" → confirmation
3. Fixture updated: `awayClanId` set, status=SCHEDULED

### Record Result
1. Match ends → home clan owner taps "Record Result"
2. Enter homeScore, awayScore → submit
3. Fixture status=FINAL, winner set
4. Both clan ratings updated (+80 for winner, -60 for loser)
5. Check for rank-up → if yes, show RankUpOverlay + confetti

## Mobile-First UI

**Layout pattern:**
```tsx
<div className="flex flex-col h-screen">
  <PageHeader /> {/* h-14, sticky top */}
  <main className="flex-1 overflow-y-auto p-4 pb-20">
    {children}
  </main>
  <BottomNav /> {/* h-16, fixed bottom */}
</div>
```

**Dialogs:**
- Use `useIsMobile()` hook
- Mobile: Shadcn `Drawer` (bottom sheet)
- Desktop: Shadcn `Dialog` (centered modal)

**Design direction:**
- Gamified but clean - creative icons, tier badges, animations
- Soccer-focused colors and imagery
- Use existing Shadcn components (Button, Card, Badge, Avatar, Tabs, Progress)
- Motion library for smooth transitions
- Sonner for toast notifications

## Implementation Sequence

### Phase 1: Foundation (15-20 files)
1. Type definitions (`/src/app/lib/types/index.ts`)
2. Constants (`tiers.ts`, `sports.ts`, `timeSlots.ts`)
3. Storage utilities (`storage.ts`, `mockData.ts`)
4. Generic hook (`useLocalStorage.ts`)
5. Router setup (`App.tsx` with BrowserRouter)
6. Layout components (`AppLayout`, `BottomNav`, `PageHeader`)

### Phase 2: State Management (10-12 files)
1. `PlayerContext.tsx`
2. Data hooks (`usePlayers`, `useClans`, `useFixtures`, `useChat`)
3. Utility functions (`tierSystem.ts`, `fixtureUtils.ts`, `dateUtils.ts`, `validation.ts`)
4. `useTierSystem` hook

### Phase 3: Onboarding (5-7 files)
1. `Onboarding.tsx` page
2. `WelcomeScreen` component
3. `CreatePlayerForm` component
4. Seed mock data in localStorage
5. Redirect logic in `App.tsx`

### Phase 4: Clan Features (10-12 files)
1. `Clans.tsx` page
2. `ClanDetail.tsx` page
3. `ClanCard`, `ClanHeader`, `ClanMemberList`, `ClanStats`
4. `CreateClanDialog`, `EditClanDialog`
5. `JoinRequestCard`
6. `TierBadge` component

### Phase 5: Fixture System (10-12 files)
1. `Fixtures.tsx` page
2. `FixtureDetail.tsx` page
3. `FixtureCard`, `FixtureList`, `FixtureFilters`
4. `CreateFixtureDialog`, `JoinFixtureDialog`, `RecordResultDialog`

### Phase 6: Chat & Profiles (8-10 files)
1. `ChatThread`, `ChatBubble`, `ChatInput`
2. `Profile.tsx`, `PlayerDetail.tsx`
3. `PlayerCard`, `PlayerAvatar`
4. `EditProfileDialog`

### Phase 7: Leaderboard (5-6 files)
1. `Leaderboard.tsx` page
2. `LeaderboardTable`, `LeaderboardRow`
3. Sorting/filtering logic

### Phase 8: Celebrations (4-5 files)
1. `RankUpOverlay` component
2. `confetti.ts` utilities
3. Integration with `recordResult` flow

### Phase 9: Home Feed (2-3 files)
1. `Home.tsx` page
2. Compose feed from clan card + recent fixtures

### Phase 10: Polish (5-8 refinements)
1. Loading states, empty states
2. Error handling
3. Animations (Motion)
4. Accessibility
5. Dark mode toggle (using next-themes)

**Total:** ~80-100 files

## Critical Files to Create First

1. `/src/app/lib/types/index.ts` - All TypeScript interfaces
2. `/src/app/lib/constants/tiers.ts` - Tier configuration
3. `/src/app/lib/hooks/useLocalStorage.ts` - Generic localStorage hook
4. `/src/app/lib/data/storage.ts` - Storage keys + utilities
5. `/src/app/lib/context/PlayerContext.tsx` - Global state
6. `/src/app/App.tsx` - Router + Context provider

## Reusable Patterns from Existing Components

- `Button` has variants: default, destructive, outline, secondary, ghost, link
- `Card` composition: Card > CardHeader > CardTitle/CardDescription > CardContent > CardFooter
- `Badge` has variants: default, secondary, destructive, outline
- `Avatar` with AvatarImage + AvatarFallback pattern
- Forms use `react-hook-form` + `Form` wrapper components
- Use `cn()` from `/src/app/components/ui/utils.ts` for class merging
- Use `useIsMobile()` hook for responsive dialogs

## Verification

After implementation:
1. Run dev server (already running)
2. Test onboarding flow: create player → verify saved to localStorage
3. Test clan creation: create clan → verify player is owner and member
4. Test join clan: request → approve → verify membership
5. Test fixture creation: create match → verify status=OPEN
6. Test join match: join as away → verify status=SCHEDULED
7. Test record result: enter scores → verify ratings updated, rank-up overlay if applicable
8. Test chat: send messages → verify saved to localStorage
9. Test leaderboard: verify clans sorted by rating
10. Test navigation: verify all bottom nav tabs work
11. Test mobile responsiveness: resize to 375px width
12. Check localStorage in DevTools: verify all keys present with correct data

## Notes

- Use Lucide React for all icons (already installed)
- Use `date-fns` for date formatting (already installed)
- Use `sonner` toast for success/error messages (already installed)
- Use `motion` for page transitions and animations (already installed)
- Use `canvas-confetti` for rank-up celebrations (already installed)
- Prefer Drawer on mobile, Dialog on desktop for forms
- All forms use react-hook-form v7.55 (already installed)
- Keep components small and focused - max 200 lines
- Extract repeated logic into custom hooks
- Use TypeScript strictly - no `any` types
