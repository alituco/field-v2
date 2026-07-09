# Field Referee Web App

Mobile-first Next.js app for referees to run a match clock, record goals, assists, and blue cards.

## Setup

Create `referee/.env.local`:

```sh
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
REFEREE_ACCESS_CODE=pick-a-referee-code
```

The service-role key is used only by Next.js API routes. Do not expose it as a `NEXT_PUBLIC_` value.

## Run

```sh
cd referee
npm install
npm run dev -- -p 3001
```

Open `http://localhost:3001` on the referee phone or simulator browser.

## Current Flow

- Enter the referee access code.
- Pick a scheduled/live fixture.
- Start the match timer.
- Record goals with scorer and optional assist.
- Record blue cards. Active cards count down from 2 minutes and alert when the player can return.
- Finish match. The server computes score from recorded goals and applies SR through Supabase.
