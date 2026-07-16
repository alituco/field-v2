import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type FeedRow = {
  id: string;
  status: string;
  starts_at: string;
  white_score: number | null;
  black_score: number | null;
  confirmed_count: number;
  goalkeeper_spots: number;
  defender_spots: number;
  midfielder_spots: number;
  attacker_spots: number;
  my_booking_id: string | null;
  my_booking_role: string | null;
  my_booking_team: string | null;
};

type GameRow = {
  id: string;
  status: string;
  starts_at: string;
  white_score: number | null;
  black_score: number | null;
  goalkeeper_capacity: number;
  defender_capacity: number;
  midfielder_capacity: number;
  attacker_capacity: number;
};

type BookingRow = {
  id: string;
  game_id: string;
  profile_id: string;
  role: string;
  team: string | null;
  status: string;
};

const url = requireEnv("SUPABASE_URL");
const publishableKey = requireEnv("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = requireEnv("DEV_SEED_PASSWORD");
const verifierPhone = `+97339${
  String(Math.floor(100000 + Math.random() * 900000))
}`;

const admin = createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const authenticated = createClient(url, publishableKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const anonymous = createClient(url, publishableKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const { data: verifier, error: createVerifierError } = await admin.auth.admin
  .createUser({
    phone: verifierPhone,
    password,
    phone_confirm: true,
    user_metadata: { display_name: "Fixture Feed Verifier" },
  });
if (createVerifierError) throw createVerifierError;

try {
  await verifyFeed(verifier.user.id);
} finally {
  const { error } = await admin.auth.admin.deleteUser(verifier.user.id);
  if (error) throw error;
}

async function verifyFeed(verifierUserId: string) {
  const { data: session, error: signInError } = await authenticated.auth
    .signInWithPassword({ phone: verifierPhone, password });
  if (signInError) throw signInError;
  assert(session.user != null, "The fixture-feed verifier did not sign in.");
  assert(
    session.user.id === verifierUserId,
    "The fixture-feed verifier signed in as the wrong user.",
  );

  const [feedResult, gamesResult, bookingsResult, anonymousResult] =
    await Promise
      .all([
        authenticated.rpc("list_open_queue_fixture_games"),
        admin.from("open_queue_games").select(
          "id,status,starts_at,white_score,black_score,goalkeeper_capacity,defender_capacity,midfielder_capacity,attacker_capacity",
        ).neq("status", "CANCELLED").order("starts_at"),
        admin.from("open_queue_bookings").select(
          "id,game_id,profile_id,role,team,status",
        ).eq("status", "CONFIRMED"),
        anonymous.rpc("list_open_queue_fixture_games"),
      ]);

  if (feedResult.error) throw feedResult.error;
  if (gamesResult.error) throw gamesResult.error;
  if (bookingsResult.error) throw bookingsResult.error;
  assert(
    anonymousResult.error != null,
    "Anonymous users must not be able to load the solo Fixtures feed.",
  );

  const feed = (feedResult.data ?? []) as FeedRow[];
  const games = (gamesResult.data ?? []) as GameRow[];
  const bookings = (bookingsResult.data ?? []) as BookingRow[];
  const gameById = new Map(games.map((game) => [game.id, game]));
  const bookingsByGame = new Map<string, BookingRow[]>();
  for (const booking of bookings) {
    const current = bookingsByGame.get(booking.game_id) ?? [];
    current.push(booking);
    bookingsByGame.set(booking.game_id, current);
  }

  assert(
    feed.length === games.length,
    "The feed omitted a non-cancelled game.",
  );
  assert(feed.length > 0, "The solo Fixtures feed is empty.");
  assert(
    feed.some((row) => row.status === "FINAL"),
    "The feed does not include completed solo games.",
  );
  assert(
    feed.some((row) => row.status === "OPEN" || row.status === "FULL"),
    "The feed does not include upcoming solo games.",
  );
  assert(
    feed.every((row) => row.status !== "CANCELLED"),
    "The feed exposed a cancelled solo game.",
  );

  for (let index = 1; index < feed.length; index++) {
    assert(
      Date.parse(feed[index - 1].starts_at) <=
        Date.parse(feed[index].starts_at),
      "The solo Fixtures feed is not ordered by kickoff.",
    );
  }

  for (const row of feed) {
    const game = gameById.get(row.id);
    assert(game != null, `Feed game ${row.id} does not exist.`);
    const confirmed = bookingsByGame.get(row.id) ?? [];
    const countRole = (role: string) =>
      confirmed.filter((booking) => booking.role === role).length;

    assert(
      row.confirmed_count === confirmed.length,
      `Confirmed-player count is wrong for ${row.id}.`,
    );
    assert(
      row.goalkeeper_spots === game.goalkeeper_capacity - countRole("GK") &&
        row.defender_spots === game.defender_capacity - countRole("DEF") &&
        row.midfielder_spots === game.midfielder_capacity - countRole("MID") &&
        row.attacker_spots === game.attacker_capacity - countRole("ATT"),
      `Position availability is wrong for ${row.id}.`,
    );
    assert(
      row.white_score === game.white_score &&
        row.black_score === game.black_score,
      `The final score is wrong for ${row.id}.`,
    );

    const myBooking = confirmed.find((booking) =>
      booking.profile_id === session.user.id
    );
    assert(
      row.my_booking_id === (myBooking?.id ?? null) &&
        row.my_booking_role === (myBooking?.role ?? null) &&
        row.my_booking_team === (myBooking?.team ?? null),
      `Caller-only booking metadata is wrong for ${row.id}.`,
    );
  }

  console.log(
    `Verified ${feed.length} solo Fixtures games (${
      feed.filter((row) => row.status === "FINAL").length
    } final, ${
      feed.filter((row) => row.status !== "FINAL").length
    } upcoming/live).`,
  );
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
