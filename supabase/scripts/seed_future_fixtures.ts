import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type Clan = {
  id: string;
  name: string;
  tag: string;
  created_by: string;
};

type FixtureSlot = {
  match_date: string;
  time_slot: TimeSlot;
};

type TimeSlot = "7:00 PM - 8:00 PM";

type PlannedFixture = {
  home: Clan;
  away?: Clan;
  status: "OPEN" | "SCHEDULED";
  sequence: number;
};

const MOCK_VENUE_PREFIX = "[MOCK] ";
const DEFAULT_FIXTURE_COUNT = 32;
const MAX_FIXTURE_COUNT = 100;
const MAX_UPCOMING_MATCHES_PER_CLAN = 2;
const TIME_SLOTS: TimeSlot[] = ["7:00 PM - 8:00 PM"];
const VENUES = [
  "Bahrain Bay Arena",
  "Dilmun Field",
  "Hidd Sports Centre",
  "Pearl Arena",
  "Riffa Sports Hall",
  "Saar Club",
  "Seef Futsal Court",
  "Water Garden City",
];

const supabaseUrl = requireEnv("SUPABASE_URL");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const requestedCount = parseRequestedCount(Deno.args[0]);
const today = dateOnly(new Date());

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const { data: clanRows, error: clanError } = await admin
  .from("clans")
  .select("id,name,tag,created_by")
  .is("archived_at", null)
  .order("tag");

if (clanError) throw new Error(`Could not load clans: ${clanError.message}`);

const { data: memberRows, error: memberError } = await admin
  .from("clan_members")
  .select("clan_id")
  .is("left_at", null);

if (memberError) {
  throw new Error(`Could not load clan rosters: ${memberError.message}`);
}

const memberCounts = new Map<string, number>();
for (const member of memberRows ?? []) {
  const clanId = String(member.clan_id);
  memberCounts.set(clanId, (memberCounts.get(clanId) ?? 0) + 1);
}

const clans = ((clanRows ?? []) as Clan[]).filter(
  (clan) => (memberCounts.get(clan.id) ?? 0) >= 7,
);
if (clans.length < 2) {
  throw new Error(
    "At least two active clans with seven players are required to seed fixtures.",
  );
}

const { data: existingRows, error: existingError } = await admin
  .from("fixtures")
  .select(
    "match_date,time_slot,venue,status,home_clan_id,away_clan_id",
  )
  .in("status", ["OPEN", "SCHEDULED", "LIVE"]);

if (existingError) {
  throw new Error(`Could not load future fixtures: ${existingError.message}`);
}

const existingFixtures = existingRows ?? [];
const occupiedSlots = new Set(
  existingFixtures.map((fixture) =>
    slotKey(String(fixture.match_date), String(fixture.time_slot))
  ),
);
const existingMockCount =
  existingFixtures.filter((fixture) =>
    String(fixture.match_date) >= today &&
    String(fixture.venue).startsWith(MOCK_VENUE_PREFIX)
  ).length;
const fixturesToCreate = Math.max(0, requestedCount - existingMockCount);

const upcomingCounts = new Map(clans.map((clan) => [clan.id, 0]));
for (const fixture of existingFixtures) {
  incrementCount(upcomingCounts, String(fixture.home_clan_id));
  if (fixture.away_clan_id != null) {
    incrementCount(upcomingCounts, String(fixture.away_clan_id));
  }
}

const alreadyOverLimit = clans.filter(
  (clan) => (upcomingCounts.get(clan.id) ?? 0) > MAX_UPCOMING_MATCHES_PER_CLAN,
);
if (alreadyOverLimit.length > 0) {
  console.warn(
    "Existing data is already above the 2-upcoming-match clan limit: " +
      alreadyOverLimit.map((clan) =>
        `${clan.tag} (${upcomingCounts.get(clan.id)})`
      ).join(", ") +
      ". No additional fixtures will be assigned to those clans.",
  );
}

if (fixturesToCreate === 0) {
  console.log(
    `Already have ${existingMockCount} future mock fixtures; nothing to add.`,
  );
  Deno.exit(0);
}

const shuffledClans = seededShuffle(clans, 0x20260712);
const plannedFixtures = planFixtures(
  shuffledClans,
  upcomingCounts,
  fixturesToCreate,
  existingMockCount,
);

if (plannedFixtures.length === 0) {
  console.warn(
    `Could not add future mock fixtures: every eligible clan already has ` +
      `${MAX_UPCOMING_MATCHES_PER_CLAN} upcoming matches.`,
  );
  Deno.exit(0);
}

if (plannedFixtures.length < fixturesToCreate) {
  console.warn(
    `Clan capacity allows ${plannedFixtures.length} more mock fixtures, ` +
      `so the requested total of ${requestedCount} cannot be reached.`,
  );
}

const availableSlots = buildAvailableSlots(
  today,
  occupiedSlots,
  plannedFixtures.length,
);
const inserted: Array<{
  date: string;
  time: TimeSlot;
  status: "OPEN" | "SCHEDULED";
  home: string;
  away?: string;
}> = [];

for (let index = 0; index < plannedFixtures.length; index += 1) {
  const slot = availableSlots[index];
  const { away, home, sequence, status } = plannedFixtures[index];
  const paidAt = new Date().toISOString();

  const { error } = await admin.from("fixtures").insert({
    status,
    home_clan_id: home.id,
    away_clan_id: away?.id ?? null,
    venue: `${MOCK_VENUE_PREFIX}${VENUES[sequence % VENUES.length]}`,
    day: weekdayFor(slot.match_date),
    time_slot: slot.time_slot,
    match_date: slot.match_date,
    created_by: home.created_by,
    home_paid_by: home.created_by,
    home_paid_at: paidAt,
    away_paid_by: away?.created_by ?? null,
    away_paid_at: away == null ? null : paidAt,
  });

  if (error) {
    throw new Error(
      `Could not create ${slot.match_date} ${slot.time_slot}: ${error.message}`,
    );
  }

  inserted.push({
    date: slot.match_date,
    time: slot.time_slot,
    status,
    home: `${home.name} (${home.tag})`,
    away: away == null ? undefined : `${away.name} (${away.tag})`,
  });
}

const openCount =
  inserted.filter((fixture) => fixture.status === "OPEN").length;
const scheduledCount = inserted.length - openCount;
console.log(
  `Created ${inserted.length} future mock fixtures ` +
    `(${scheduledCount} scheduled, ${openCount} open).`,
);
console.log(
  `Date range: ${inserted[0].date} through ${inserted.at(-1)?.date}.`,
);
for (const fixture of inserted) {
  const matchup = fixture.away
    ? `${fixture.home} vs ${fixture.away}`
    : `${fixture.home} awaiting opponent`;
  console.log(
    `  ${fixture.date} · ${fixture.time} · ${fixture.status} · ${matchup}`,
  );
}

function planFixtures(
  clans: Clan[],
  existingCounts: Map<string, number>,
  requested: number,
  startSequence: number,
): PlannedFixture[] {
  const counts = new Map(existingCounts);
  const remainingClanSlots = clans.reduce(
    (total, clan) =>
      total +
      Math.max(
        0,
        MAX_UPCOMING_MATCHES_PER_CLAN - (counts.get(clan.id) ?? 0),
      ),
    0,
  );
  const target = Math.min(requested, remainingClanSlots);
  const orderById = new Map(clans.map((clan, index) => [clan.id, index]));
  const plans: PlannedFixture[] = [];

  while (plans.length < target) {
    const sequence = startSequence + plans.length;
    const rotation = sequence % clans.length;
    const eligible = clans
      .filter(
        (clan) => (counts.get(clan.id) ?? 0) < MAX_UPCOMING_MATCHES_PER_CLAN,
      )
      .sort((first, second) => {
        const countDifference = (counts.get(first.id) ?? 0) -
          (counts.get(second.id) ?? 0);
        if (countDifference !== 0) return countDifference;
        const firstOrder =
          ((orderById.get(first.id) ?? 0) - rotation + clans.length) %
          clans.length;
        const secondOrder =
          ((orderById.get(second.id) ?? 0) - rotation + clans.length) %
          clans.length;
        return firstOrder - secondOrder;
      });

    if (eligible.length === 0) break;

    const slotsLeft = eligible.reduce(
      (total, clan) =>
        total +
        MAX_UPCOMING_MATCHES_PER_CLAN - (counts.get(clan.id) ?? 0),
      0,
    );
    const fixturesLeft = target - plans.length;
    const prefersOpen = sequence % 4 === 0;
    const canSchedule = eligible.length >= 2 && slotsLeft >= fixturesLeft + 1;
    const home = eligible[0];
    const away = !prefersOpen && canSchedule ? eligible[1] : undefined;

    plans.push({
      home,
      away,
      status: away == null ? "OPEN" : "SCHEDULED",
      sequence,
    });
    incrementCount(counts, home.id);
    if (away != null) incrementCount(counts, away.id);
  }

  return plans;
}

function incrementCount(counts: Map<string, number>, clanId: string) {
  counts.set(clanId, (counts.get(clanId) ?? 0) + 1);
}

function buildAvailableSlots(
  startDate: string,
  occupied: Set<string>,
  count: number,
): FixtureSlot[] {
  const slots: FixtureSlot[] = [];
  const cursor = parseDate(startDate);
  cursor.setUTCDate(cursor.getUTCDate() + 1);

  for (let daysChecked = 0; slots.length < count; daysChecked += 1) {
    if (daysChecked > 366) {
      throw new Error(
        "Could not find enough empty fixture slots in the next year.",
      );
    }

    const weekday = cursor.getUTCDay();
    if (weekday === 2 || weekday === 5) {
      const matchDate = dateOnly(cursor);
      for (const timeSlot of TIME_SLOTS) {
        if (!occupied.has(slotKey(matchDate, timeSlot))) {
          slots.push({ match_date: matchDate, time_slot: timeSlot });
          occupied.add(slotKey(matchDate, timeSlot));
          if (slots.length === count) break;
        }
      }
    }

    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }

  return slots;
}

function seededShuffle<T>(values: T[], seed: number): T[] {
  const result = [...values];
  let state = seed >>> 0;
  const random = () => {
    state += 0x6d2b79f5;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };

  for (let index = result.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(random() * (index + 1));
    [result[index], result[swapIndex]] = [result[swapIndex], result[index]];
  }

  return result;
}

function parseRequestedCount(raw?: string): number {
  if (raw == null) return DEFAULT_FIXTURE_COUNT;
  const count = Number(raw);
  if (!Number.isInteger(count) || count < 1 || count > MAX_FIXTURE_COUNT) {
    throw new Error(
      `Fixture count must be a whole number between 1 and ${MAX_FIXTURE_COUNT}.`,
    );
  }
  return count;
}

function weekdayFor(date: string): "TUESDAY" | "FRIDAY" {
  return parseDate(date).getUTCDay() === 2 ? "TUESDAY" : "FRIDAY";
}

function parseDate(value: string): Date {
  return new Date(`${value}T00:00:00.000Z`);
}

function dateOnly(value: Date): string {
  return value.toISOString().slice(0, 10);
}

function slotKey(date: string, timeSlot: string): string {
  return `${date}|${timeSlot}`;
}

function requireEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}
