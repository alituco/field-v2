import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";
import { assertSafeDevDataTarget } from "./_shared/environment_guard.ts";

type ProfileRow = { id: string; phone: string | null };
type PlayerRatingRow = { profile_id: string; skill_rating: number };
type GameRow = { id: string; venue: string; price_fils: number };
type FlowEdge = {
  to: number;
  reverseIndex: number;
  capacity: number;
};

const maxUpcomingBookingsPerProfile = 2;

const url = requireEnv("SUPABASE_URL");
assertSafeDevDataTarget(url, "Open Queue data seed");
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

const gameSpecs = [
  {
    venue: "[OQ MOCK] TFA, Saar",
    age: "Ages 16–30",
    count: 10,
  },
  {
    venue: "[OQ MOCK] TFA, Saar",
    age: "Ages 18–30",
    count: 12,
  },
  {
    venue: "[OQ MOCK] Isa Town SC",
    age: "Ages 16–24",
    count: 9,
  },
  {
    venue: "[OQ MOCK] Riffa Views",
    age: "All ages",
    count: 7,
  },
  {
    venue: "[OQ MOCK] Bahrain Bay",
    age: "Ages 18–35",
    count: 6,
  },
  {
    venue: "[OQ MOCK] Seef Court",
    age: "All ages",
    count: 11,
  },
];

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

const { data: upcomingBookingRows, error: upcomingBookingsError } = await admin
  .from("open_queue_bookings")
  .select(
    "profile_id,open_queue_games!open_queue_bookings_game_id_fkey!inner(status,starts_at)",
  )
  .eq("status", "CONFIRMED")
  .in("open_queue_games.status", ["OPEN", "FULL"])
  .gt("open_queue_games.starts_at", new Date().toISOString());
if (upcomingBookingsError) throw upcomingBookingsError;

const upcomingCounts = new Map<string, number>();
for (const booking of upcomingBookingRows ?? []) {
  const profileId = booking.profile_id as string;
  upcomingCounts.set(profileId, (upcomingCounts.get(profileId) ?? 0) + 1);
}

const profilePlans = planProfileAssignments(
  profiles,
  rolePlans.map((roles) => roles.length),
  upcomingCounts,
);

const { data: playerRatingRows, error: playerRatingsError } = await admin
  .from("player_ratings")
  .select("profile_id,skill_rating")
  .in("profile_id", profiles.map((profile) => profile.id));
if (playerRatingsError) throw playerRatingsError;

const ratingsByProfileId = new Map(
  ((playerRatingRows ?? []) as PlayerRatingRow[]).map((rating) => [
    rating.profile_id,
    rating.skill_rating,
  ]),
);
const missingRatingProfile = profiles.find((profile) =>
  !ratingsByProfileId.has(profile.id)
);
if (missingRatingProfile != null) {
  throw new Error(
    `Profile ${missingRatingProfile.id} does not have a player rating.`,
  );
}

const insertedGames: GameRow[] = [];
const { data: occupiedGameRows, error: occupiedGamesError } = await admin
  .from("open_queue_games")
  .select("starts_at")
  .neq("status", "CANCELLED");
if (occupiedGamesError) throw occupiedGamesError;

const occupiedStarts = new Set(
  (occupiedGameRows ?? []).map((game) =>
    new Date(String(game.starts_at)).toISOString()
  ),
);
const gameStarts = buildUpcomingOpenQueueStarts(
  new Date(),
  gameSpecs.length,
  occupiedStarts,
);
for (let index = 0; index < gameSpecs.length; index += 1) {
  const spec = gameSpecs[index];
  const startsAt = gameStarts[index];
  const endsAt = new Date(startsAt.getTime() + 60 * 60 * 1000);
  const { data, error } = await admin
    .from("open_queue_games")
    .insert({
      venue: spec.venue,
      starts_at: startsAt.toISOString(),
      ends_at: endsAt.toISOString(),
      timezone: "Asia/Bahrain",
      age_label: spec.age,
      price_fils: 3000,
    })
    .select("id,venue,price_fils")
    .single();
  if (error) throw error;
  insertedGames.push(data as GameRow);
}

for (let gameIndex = 0; gameIndex < insertedGames.length; gameIndex += 1) {
  const game = insertedGames[gameIndex];
  const roles = rolePlans[gameIndex];
  for (let bookingIndex = 0; bookingIndex < roles.length; bookingIndex += 1) {
    const profile = profilePlans[gameIndex][bookingIndex];
    const rating = ratingsByProfileId.get(profile.id)!;
    const { error } = await admin.from("open_queue_bookings").insert({
      game_id: game.id,
      profile_id: profile.id,
      role: roles[bookingIndex],
      player_rating_at_booking: rating,
      amount_paid_fils: game.price_fils,
      base_amount_fils: game.price_fils,
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

function buildUpcomingOpenQueueStarts(
  now: Date,
  count: number,
  occupiedStarts: Set<string>,
) {
  const starts: Date[] = [];
  const bahrainNow = new Date(now.getTime() + 3 * 60 * 60 * 1000);
  const cursor = new Date(Date.UTC(
    bahrainNow.getUTCFullYear(),
    bahrainNow.getUTCMonth(),
    bahrainNow.getUTCDate(),
  ));

  for (let daysChecked = 0; starts.length < count; daysChecked += 1) {
    if (daysChecked > 366) {
      throw new Error(
        "Could not find enough Open Queue slots in the next year.",
      );
    }
    const day = cursor.getUTCDay();
    if (day === 2 || day === 5) {
      const startsAt = new Date(Date.UTC(
        cursor.getUTCFullYear(),
        cursor.getUTCMonth(),
        cursor.getUTCDate(),
        17,
        30,
      ));
      if (startsAt > now && !occupiedStarts.has(startsAt.toISOString())) {
        starts.push(startsAt);
      }
    }
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }

  return starts;
}

function planProfileAssignments(
  availableProfiles: ProfileRow[],
  gameSizes: number[],
  existingUpcomingCounts: Map<string, number>,
) {
  const remainingByProfile = availableProfiles.map((profile) =>
    Math.max(
      0,
      maxUpcomingBookingsPerProfile -
        (existingUpcomingCounts.get(profile.id) ?? 0),
    )
  );
  const requiredSlots = gameSizes.reduce((total, size) => total + size, 0);
  const availableSlots = remainingByProfile.reduce(
    (total, remaining) => total + remaining,
    0,
  );
  const largestGame = Math.max(...gameSizes);
  const eligibleProfiles = remainingByProfile.filter((count) => count > 0)
    .length;

  if (availableSlots < requiredSlots) {
    throw new Error(
      `Open Queue mock data needs ${requiredSlots} available player booking slots, ` +
        `but only ${availableSlots} remain under the maximum of ` +
        `${maxUpcomingBookingsPerProfile} upcoming solo games per player. ` +
        "Add profiles, finish or cancel upcoming bookings, then run the seed again.",
    );
  }
  if (eligibleProfiles < largestGame) {
    throw new Error(
      `Open Queue mock data needs ${largestGame} distinct eligible profiles ` +
        `for its largest game, but only ${eligibleProfiles} can accept another ` +
        "upcoming solo booking.",
    );
  }

  const source = 0;
  const gameOffset = 1;
  const profileOffset = gameOffset + gameSizes.length;
  const sink = profileOffset + availableProfiles.length;
  const graph = Array.from(
    { length: sink + 1 },
    () => [] as FlowEdge[],
  );
  const assignmentEdges = gameSizes.map(() => new Map<number, FlowEdge>());

  for (let gameIndex = 0; gameIndex < gameSizes.length; gameIndex += 1) {
    addFlowEdge(graph, source, gameOffset + gameIndex, gameSizes[gameIndex]);
    for (
      let profileIndex = 0;
      profileIndex < availableProfiles.length;
      profileIndex += 1
    ) {
      if (remainingByProfile[profileIndex] === 0) continue;
      const edge = addFlowEdge(
        graph,
        gameOffset + gameIndex,
        profileOffset + profileIndex,
        1,
      );
      assignmentEdges[gameIndex].set(profileIndex, edge);
    }
  }
  for (
    let profileIndex = 0;
    profileIndex < availableProfiles.length;
    profileIndex += 1
  ) {
    addFlowEdge(
      graph,
      profileOffset + profileIndex,
      sink,
      remainingByProfile[profileIndex],
    );
  }

  const assignedSlots = maximumFlow(graph, source, sink);
  if (assignedSlots !== requiredSlots) {
    throw new Error(
      `Could not distribute all ${requiredSlots} Open Queue mock bookings ` +
        `without exceeding ${maxUpcomingBookingsPerProfile} upcoming solo ` +
        "games per player. Add more eligible profiles and run the seed again.",
    );
  }

  return assignmentEdges.map((edges, gameIndex) => {
    const assignedProfiles = [...edges.entries()]
      .filter(([, edge]) => edge.capacity === 0)
      .map(([profileIndex]) => availableProfiles[profileIndex]);
    if (assignedProfiles.length !== gameSizes[gameIndex]) {
      throw new Error(
        "Open Queue booking allocation produced an invalid game.",
      );
    }
    return assignedProfiles;
  });
}

function addFlowEdge(
  graph: FlowEdge[][],
  from: number,
  to: number,
  capacity: number,
) {
  const forward: FlowEdge = {
    to,
    reverseIndex: graph[to].length,
    capacity,
  };
  const reverse: FlowEdge = {
    to: from,
    reverseIndex: graph[from].length,
    capacity: 0,
  };
  graph[from].push(forward);
  graph[to].push(reverse);
  return forward;
}

function maximumFlow(graph: FlowEdge[][], source: number, sink: number) {
  let totalFlow = 0;
  while (true) {
    const parents = Array.from(
      { length: graph.length },
      () => null as { node: number; edgeIndex: number } | null,
    );
    const queue = [source];
    parents[source] = { node: source, edgeIndex: -1 };

    for (let cursor = 0; cursor < queue.length; cursor += 1) {
      const node = queue[cursor];
      if (node === sink) break;
      for (let edgeIndex = 0; edgeIndex < graph[node].length; edgeIndex += 1) {
        const edge = graph[node][edgeIndex];
        if (edge.capacity === 0 || parents[edge.to] !== null) continue;
        parents[edge.to] = { node, edgeIndex };
        queue.push(edge.to);
      }
    }

    if (parents[sink] === null) return totalFlow;
    let pathCapacity = Number.MAX_SAFE_INTEGER;
    for (let node = sink; node !== source;) {
      const parent = parents[node]!;
      pathCapacity = Math.min(
        pathCapacity,
        graph[parent.node][parent.edgeIndex].capacity,
      );
      node = parent.node;
    }
    for (let node = sink; node !== source;) {
      const parent = parents[node]!;
      const edge = graph[parent.node][parent.edgeIndex];
      edge.capacity -= pathCapacity;
      graph[node][edge.reverseIndex].capacity += pathCapacity;
      node = parent.node;
    }
    totalFlow += pathCapacity;
  }
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}
