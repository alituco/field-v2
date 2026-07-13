import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type ProfileRow = { id: string; phone: string | null };
type GameRow = { id: string; venue: string; price_fils: number };

const url = requireEnv("SUPABASE_URL");
const key = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const admin = createClient(url, key, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const { data: existing, error: existingError } = await admin
  .from("open_queue_games")
  .select("id")
  .like("venue", "[OQ MOCK]%");
if (existingError) throw existingError;
if ((existing ?? []).length > 0) {
  console.log(
    `Open Queue mock data already exists (${existing!.length} games).`,
  );
  Deno.exit(0);
}

const { data: profileRows, error: profileError } = await admin
  .from("profiles")
  .select("id,phone")
  .order("created_at");
if (profileError) throw profileError;

const profiles = (profileRows ?? []) as ProfileRow[];
if (profiles.length < 12) {
  throw new Error("Seed at least 12 profiles before seeding Open Queue data.");
}
profiles.sort((left, right) => {
  if (left.phone === "+97338883670") return -1;
  if (right.phone === "+97338883670") return 1;
  return left.id.localeCompare(right.id);
});

for (let index = 0; index < profiles.length; index += 1) {
  const rating = 980 + ((index * 73) % 920);
  const matches = 2 + (index % 18);
  const wins = Math.floor(matches * (0.35 + ((index % 5) * 0.08)));
  const draws = index % 4;
  const losses = Math.max(0, matches - wins - draws);
  const { error } = await admin.from("player_ratings").upsert({
    profile_id: profiles[index].id,
    skill_rating: rating,
    matches_played: matches,
    wins,
    draws,
    losses,
    last_change: index % 3 === 0 ? -8 : 5 + (index % 14),
    region: "bahrain",
  });
  if (error) throw error;
}

const start = new Date();
start.setUTCDate(start.getUTCDate() + 2);
start.setUTCHours(15, 30, 0, 0);

const gameSpecs = [
  {
    day: 0,
    hourOffset: 0,
    venue: "[OQ MOCK] TFA, Saar",
    age: "Ages 16–30",
    count: 10,
  },
  {
    day: 0,
    hourOffset: 2,
    venue: "[OQ MOCK] TFA, Saar",
    age: "Ages 18–30",
    count: 12,
  },
  {
    day: 2,
    hourOffset: 1,
    venue: "[OQ MOCK] Isa Town SC",
    age: "Ages 16–24",
    count: 9,
  },
  {
    day: 4,
    hourOffset: 2,
    venue: "[OQ MOCK] Riffa Views",
    age: "All ages",
    count: 7,
  },
  {
    day: 6,
    hourOffset: 0,
    venue: "[OQ MOCK] Bahrain Bay",
    age: "Ages 18–35",
    count: 6,
  },
  {
    day: 8,
    hourOffset: 1,
    venue: "[OQ MOCK] Seef Court",
    age: "All ages",
    count: 11,
  },
];

const insertedGames: GameRow[] = [];
for (const spec of gameSpecs) {
  const startsAt = new Date(start);
  startsAt.setUTCDate(startsAt.getUTCDate() + spec.day);
  startsAt.setUTCHours(startsAt.getUTCHours() + spec.hourOffset);
  const endsAt = new Date(startsAt.getTime() + 60 * 60 * 1000);
  const { data, error } = await admin
    .from("open_queue_games")
    .insert({
      venue: spec.venue,
      starts_at: startsAt.toISOString(),
      ends_at: endsAt.toISOString(),
      age_label: spec.age,
      price_fils: 3000,
    })
    .select("id,venue,price_fils")
    .single();
  if (error) throw error;
  insertedGames.push(data as GameRow);
}

const rolePlans = [
  ["GK", "GK", "DEF", "DEF", "DEF", "MID", "MID", "MID", "ATT", "ATT"],
  [
    "GK",
    "GK",
    "DEF",
    "DEF",
    "DEF",
    "DEF",
    "MID",
    "MID",
    "MID",
    "MID",
    "ATT",
    "ATT",
  ],
  ["GK", "DEF", "DEF", "DEF", "MID", "MID", "MID", "ATT", "ATT"],
  ["GK", "DEF", "DEF", "MID", "MID", "ATT", "ATT"],
  ["GK", "DEF", "DEF", "MID", "ATT", "ATT"],
  ["GK", "GK", "DEF", "DEF", "DEF", "DEF", "MID", "MID", "MID", "MID", "ATT"],
] as const;

for (let gameIndex = 0; gameIndex < insertedGames.length; gameIndex += 1) {
  const game = insertedGames[gameIndex];
  const roles = rolePlans[gameIndex];
  for (let bookingIndex = 0; bookingIndex < roles.length; bookingIndex += 1) {
    const profile = profiles[(bookingIndex + gameIndex * 3) % profiles.length];
    const rating = 980 +
      ((((bookingIndex + gameIndex * 3) % profiles.length) * 73) % 920);
    const { error } = await admin.from("open_queue_bookings").insert({
      game_id: game.id,
      profile_id: profile.id,
      role: roles[bookingIndex],
      player_rating_at_booking: rating,
      amount_paid_fils: game.price_fils,
      payment_method: "MOCK",
      payment_reference: `open-queue-seed-${gameIndex}-${bookingIndex}`,
    });
    if (error) throw error;
  }
}

console.log(
  `Created ${insertedGames.length} Open Queue games with ` +
    `${rolePlans.reduce((total, roles) => total + roles.length, 0)} bookings.`,
);

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}
