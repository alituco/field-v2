# Context

The user wants to add a Reels feature — a feed where players post short video clips of their goals, skills, and match moments. The question is where it fits in the existing navigation and information architecture.

---

## Recommendation: Replace the Ranks tab with Reels, move Ranks to a sub-page

### Why this placement wins

The bottom nav currently has 5 slots:

| Slot | Current |
|------|---------|
| 1 | Home |
| 2 | Fixtures |
| 3 | Clans |
| 4 | **Ranks** ← leaderboard |
| 5 | Profile |

**Reels belongs at slot 4.** Here's the reasoning:

- **Reels is a social discovery surface** — it's something users open passively to browse. It sits naturally between Clans (community) and Profile (self), which is exactly how TikTok/Instagram place their primary feed between social and personal.
- **Ranks/Leaderboard is a destination, not a habit.** Users check it occasionally, not daily. It doesn't need a permanent nav slot — it can live as a button on Home or inside the Clans page.
- **Fixtures and Clans stay where they are** — those are the core action loops (challenge, join, play) and should remain front-and-center.

The alternative (adding a 6th slot or replacing Home) are both worse: 6 icons is too cramped on mobile, and Home is the anchor screen.

---

## What gets built

### 1. `/reels` — Reels page (`src/app/pages/Reels.tsx`)
- Full-screen vertical snap-scroll feed (like TikTok/Instagram Reels)
- Each card shows: video thumbnail (tappable to "play"), player avatar + name, clan tag, caption, views + likes
- Mock data: reuse existing `highlights` from player mock data, surfaced as a community feed
- No actual video playback needed for V1 — tap opens a full-screen image overlay with a play icon

### 2. Bottom nav update (`src/app/components/layout/BottomNav.tsx`)
- Swap slot 4: `Ranks` (Trophy) → `Reels` (Clapperboard or Play icon)
- Keep the same active-state styling (emerald-600, strokeWidth 2.5)

### 3. Route + entry (`src/app/routes.ts`)
- Add `{ path: 'reels', Component: Reels }` as a child of AppLayout
- Leaderboard route stays wired at `/leaderboard`, just loses its nav slot

### 4. Leaderboard access
- Add a "Rankings" button/link to the Home page hero area or as a quick-action chip — keeps it reachable without a nav slot

---

## Files to modify

| File | Change |
|------|--------|
| `src/app/components/layout/BottomNav.tsx` | Swap Ranks → Reels in slot 4 |
| `src/app/routes.ts` | Add `/reels` route |
| `src/app/pages/Home.tsx` | Add a Leaderboard shortcut |
| **new** `src/app/pages/Reels.tsx` | Full-screen snap-scroll feed |

Mock data already exists (`currentPlayer.highlights`) — extend `MOCK_PLAYERS` highlights to all players for a community feed, or create a flat `MOCK_REELS` array in `mockData.ts`.

---

## Verification
- Navigate to Reels tab — feed renders, cards snap on scroll
- Profile highlights still show on `/profile`
- Leaderboard still reachable via Home shortcut at `/leaderboard`
- No broken nav links
