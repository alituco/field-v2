# Field Referee Web App

Mobile-first Next.js app for referees to run clan and solo/Open Queue games,
including the match clock, goals, assists, blue cards, and livestream.

## Setup

Create `referee/.env.local`:

```sh
NEXT_PUBLIC_APP_ENV=staging
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
```

The service-role key is used only by Next.js API routes. Do not expose it as a `NEXT_PUBLIC_` value.

Use `NEXT_PUBLIC_APP_ENV=local`, `staging`, or `production`. Local and staging
show a permanent environment ribbon; production does not. The app refuses an
explicit staging/production environment when the Supabase project does not
match the guarded Field project.

## Run

```sh
cd referee
npm install
npm run dev -- -p 3001
```

Open `http://localhost:3001` on the referee phone or simulator browser.

## Current Flow

- Referee signs in with phone OTP.
- Admin referees can create referee profiles and assign referees to clan or
  Open Queue games.
- Assigned referees see only their own upcoming games.
- Three hours before kickoff, a full Open Queue game appears as White Team vs
  Black Team using its confirmed bookings and automatically balanced teams.
- Start the match timer.
- Record goals with scorer and optional assist.
- Record blue cards. Active cards count down from 2 minutes and alert when the player can return.
- Finish match. The server computes score from recorded goals and applies SR through Supabase.
