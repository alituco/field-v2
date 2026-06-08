import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type AdminClient = ReturnType<typeof createClient<any, "public", any>>;

type FakeUser = {
  phone: string;
  displayName: string;
};

type FakeClan = {
  name: string;
  tag: string;
  motto: string;
  emblem: string;
  themeId: string;
  patternId: string;
  skillRating: number;
  wins: number;
  losses: number;
  ownerPhone: string;
  memberPhones: string[];
};

type FakeFixture = {
  status: "OPEN" | "SCHEDULED" | "LIVE" | "FINAL";
  homeTag: string;
  awayTag?: string;
  venue: string;
  day: "TUESDAY" | "THURSDAY";
  timeSlot: "7:00 PM - 8:00 PM" | "8:30 PM - 9:30 PM";
  matchDate: string;
  homeScore?: number;
  awayScore?: number;
  winnerTag?: string;
  homeSrChange?: number;
  awaySrChange?: number;
  videoUrl?: string;
};

const fakeUsers: FakeUser[] = [
  { phone: "+97338883671", displayName: "Zara Haddad" },
  { phone: "+97338883672", displayName: "Omar Saleh" },
  { phone: "+97338883673", displayName: "Noor Khalid" },
  { phone: "+97338883674", displayName: "Maya Faris" },
  { phone: "+97338883675", displayName: "Sami Nasser" },
  { phone: "+97338883676", displayName: "Lina Abbas" },
  { phone: "+97338883677", displayName: "Rami Darwish" },
  { phone: "+97338883678", displayName: "Hala Mansour" },
];

const fakeClans: FakeClan[] = [
  {
    name: "Neon Royals",
    tag: "NRYL",
    motto: "Pressure makes us brighter.",
    emblem: "\u{1F451}",
    themeId: "royal",
    patternId: "stripes",
    skillRating: 2130,
    wins: 18,
    losses: 6,
    ownerPhone: "+97338883671",
    memberPhones: ["+97338883671", "+97338883672", "+97338883673"],
  },
  {
    name: "Mint Mavericks",
    tag: "MMAV",
    motto: "Fast feet, calm heads.",
    emblem: "\u{26A1}",
    themeId: "mint",
    patternId: "chevron",
    skillRating: 1675,
    wins: 11,
    losses: 8,
    ownerPhone: "+97338883674",
    memberPhones: ["+97338883674", "+97338883675", "+97338883676"],
  },
  {
    name: "Crimson Drift",
    tag: "CDRF",
    motto: "Win ugly, celebrate loud.",
    emblem: "\u{1F525}",
    themeId: "crimson",
    patternId: "sash",
    skillRating: 980,
    wins: 5,
    losses: 10,
    ownerPhone: "+97338883677",
    memberPhones: ["+97338883677", "+97338883678"],
  },
];

const fakeFixtures: FakeFixture[] = [
  {
    status: "SCHEDULED",
    homeTag: "NRYL",
    awayTag: "MMAV",
    venue: "Central Sports Complex",
    day: "TUESDAY",
    timeSlot: "7:00 PM - 8:00 PM",
    matchDate: "2026-06-09",
  },
  {
    status: "LIVE",
    homeTag: "CDRF",
    awayTag: "NRYL",
    venue: "Riverside Park",
    day: "THURSDAY",
    timeSlot: "8:30 PM - 9:30 PM",
    matchDate: "2026-06-11",
    homeScore: 1,
    awayScore: 0,
  },
  {
    status: "OPEN",
    homeTag: "MMAV",
    venue: "Sunset Pitch",
    day: "TUESDAY",
    timeSlot: "7:00 PM - 8:00 PM",
    matchDate: "2026-06-16",
  },
  {
    status: "OPEN",
    homeTag: "NRYL",
    venue: "Eastside Arena",
    day: "THURSDAY",
    timeSlot: "8:30 PM - 9:30 PM",
    matchDate: "2026-06-18",
  },
  {
    status: "FINAL",
    homeTag: "NRYL",
    awayTag: "CDRF",
    venue: "Downtown Stadium",
    day: "TUESDAY",
    timeSlot: "8:30 PM - 9:30 PM",
    matchDate: "2026-06-02",
    homeScore: 4,
    awayScore: 1,
    winnerTag: "NRYL",
    homeSrChange: 28,
    awaySrChange: -21,
  },
  {
    status: "FINAL",
    homeTag: "MMAV",
    awayTag: "NRYL",
    venue: "Central Sports Complex",
    day: "THURSDAY",
    timeSlot: "8:30 PM - 9:30 PM",
    matchDate: "2026-06-04",
    homeScore: 2,
    awayScore: 2,
    homeSrChange: 5,
    awaySrChange: 5,
  },
];

const supabaseUrl = requireEnv("SUPABASE_URL");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const seedPassword = requireEnv("DEV_SEED_PASSWORD");

if (seedPassword.length < 6) {
  throw new Error("DEV_SEED_PASSWORD must be at least 6 characters.");
}

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
}) as AdminClient;

const usersByPhone = new Map<string, string>();

for (const fakeUser of fakeUsers) {
  const userId = await ensureUser({
    admin,
    phone: fakeUser.phone,
    password: seedPassword,
    displayName: fakeUser.displayName,
  });
  usersByPhone.set(fakeUser.phone, userId);
}

await upsertProfiles(admin, usersByPhone);
await removeSeedOwnedRows(admin, [...usersByPhone.values()]);
const clanIdsByTag = await seedClans(admin, usersByPhone);
await seedFixtures(admin, clanIdsByTag);

console.log("");
console.log("Seeded dev users:");
for (const fakeUser of fakeUsers) {
  console.log(`  ${fakeUser.phone}  ${fakeUser.displayName}`);
}
console.log("");
console.log("Seeded dev clans:");
for (const fakeClan of fakeClans) {
  console.log(`  ${fakeClan.tag}  ${fakeClan.name}`);
}
console.log("");
console.log("Seeded dev fixtures:");
for (const fakeFixture of fakeFixtures) {
  console.log(
    `  ${fakeFixture.status}  ${fakeFixture.homeTag} ${
      fakeFixture.awayTag ? "vs " + fakeFixture.awayTag : "open"
    }`,
  );
}

async function ensureUser({
  admin,
  phone,
  password,
  displayName,
}: {
  admin: AdminClient;
  phone: string;
  password: string;
  displayName: string;
}) {
  const { data, error } = await admin.auth.admin.createUser({
    phone,
    password,
    phone_confirm: true,
    user_metadata: {
      display_name: displayName,
      name: displayName,
    },
  });

  if (!error && data.user) {
    return data.user.id;
  }

  if (!isAlreadyRegisteredError(error?.message)) {
    throw error ?? new Error(`Could not create dev user ${phone}.`);
  }

  const existingUser = await findUserByPhone(admin, phone);
  if (!existingUser) {
    throw new Error(`Dev user ${phone} exists, but could not be found.`);
  }

  const { error: updateError } = await admin.auth.admin.updateUserById(
    existingUser.id,
    {
      password,
      phone_confirm: true,
      user_metadata: {
        ...existingUser.user_metadata,
        display_name: displayName,
        name: displayName,
      },
    },
  );

  if (updateError) {
    throw updateError;
  }

  return existingUser.id;
}

async function upsertProfiles(
  admin: AdminClient,
  userIdsByPhone: Map<string, string>,
) {
  const rows = fakeUsers.map((fakeUser) => ({
    id: requireUserId(userIdsByPhone, fakeUser.phone),
    phone: fakeUser.phone,
    display_name: fakeUser.displayName,
  }));

  const { error } = await admin.from("profiles").upsert(rows, {
    onConflict: "id",
  });

  if (error) {
    throw error;
  }
}

async function removeSeedOwnedRows(admin: AdminClient, userIds: string[]) {
  const clanTags = fakeClans.map((clan) => clan.tag);

  await assertNoError(
    admin.from("clan_members").delete().in("profile_id", userIds),
    "delete seed member rows",
  );
  await assertNoError(
    admin.from("clans").delete().in("tag", clanTags),
    "delete seed clan tags",
  );
  await assertNoError(
    admin.from("clans").delete().in("created_by", userIds),
    "delete clans owned by seeded users",
  );
}

async function seedClans(
  admin: AdminClient,
  userIdsByPhone: Map<string, string>,
) {
  const clanIdsByTag = new Map<string, string>();

  for (const fakeClan of fakeClans) {
    const ownerId = requireUserId(userIdsByPhone, fakeClan.ownerPhone);
    const { data: clan, error } = await admin
      .from("clans")
      .insert({
        name: fakeClan.name,
        tag: fakeClan.tag,
        motto: fakeClan.motto,
        emblem: fakeClan.emblem,
        theme_id: fakeClan.themeId,
        pattern_id: fakeClan.patternId,
        skill_rating: fakeClan.skillRating,
        wins: fakeClan.wins,
        losses: fakeClan.losses,
        created_by: ownerId,
      })
      .select("id")
      .single();

    if (error) {
      throw error;
    }

    const clanId = (clan as { id?: string }).id;
    if (!clanId) {
      throw new Error(`Could not read created clan id for ${fakeClan.tag}.`);
    }
    clanIdsByTag.set(fakeClan.tag, clanId);

    const memberRows = fakeClan.memberPhones.map((phone) => ({
      clan_id: clanId,
      profile_id: requireUserId(userIdsByPhone, phone),
      role: phone === fakeClan.ownerPhone ? "owner" : "member",
    }));

    await assertNoError(
      admin.from("clan_members").upsert(memberRows, {
        onConflict: "clan_id,profile_id",
      }),
      `upsert members for ${fakeClan.tag}`,
    );
  }

  return clanIdsByTag;
}

async function seedFixtures(
  admin: AdminClient,
  clanIdsByTag: Map<string, string>,
) {
  const rows = fakeFixtures.map((fixture) => ({
    status: fixture.status,
    home_clan_id: requireClanId(clanIdsByTag, fixture.homeTag),
    away_clan_id: fixture.awayTag
      ? requireClanId(clanIdsByTag, fixture.awayTag)
      : null,
    venue: fixture.venue,
    day: fixture.day,
    time_slot: fixture.timeSlot,
    match_date: fixture.matchDate,
    home_score: fixture.homeScore ?? null,
    away_score: fixture.awayScore ?? null,
    winner_clan_id: fixture.winnerTag
      ? requireClanId(clanIdsByTag, fixture.winnerTag)
      : null,
    home_sr_change: fixture.homeSrChange ?? null,
    away_sr_change: fixture.awaySrChange ?? null,
    video_url: fixture.videoUrl ?? null,
    created_by: requireClanOwnerId(fixture.homeTag),
  }));

  await assertNoError(admin.from("fixtures").insert(rows), "insert fixtures");
}

function requireClanOwnerId(tag: string) {
  const clan = fakeClans.find((candidate) => candidate.tag === tag);
  if (!clan) {
    throw new Error(`Missing seeded clan owner for ${tag}.`);
  }
  return requireUserId(usersByPhone, clan.ownerPhone);
}

async function assertNoError(
  query: PromiseLike<{ error: { message: string } | null }>,
  action: string,
) {
  const { error } = await query;
  if (error) {
    throw new Error(`${action}: ${error.message}`);
  }
}

async function findUserByPhone(admin: AdminClient, phone: string) {
  const phoneDigits = normalizePhoneDigits(phone);

  for (let page = 1; page <= 10; page += 1) {
    const { data, error } = await admin.auth.admin.listUsers({
      page,
      perPage: 1000,
    });

    if (error) throw error;

    const user = data.users.find((candidate) =>
      normalizePhoneDigits(candidate.phone ?? "") === phoneDigits
    );
    if (user) return user;
    if (data.users.length < 1000) return null;
  }

  return null;
}

function requireUserId(userIdsByPhone: Map<string, string>, phone: string) {
  const userId = userIdsByPhone.get(phone);
  if (!userId) {
    throw new Error(`Missing seeded user id for ${phone}.`);
  }
  return userId;
}

function requireClanId(clanIdsByTag: Map<string, string>, tag: string) {
  const clanId = clanIdsByTag.get(tag);
  if (!clanId) {
    throw new Error(`Missing seeded clan id for ${tag}.`);
  }
  return clanId;
}

function requireEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function normalizePhoneDigits(phone: string) {
  return phone.replace(/\D/g, "");
}

function isAlreadyRegisteredError(message?: string) {
  if (!message) return false;
  const normalized = message.toLowerCase();
  return (
    normalized.includes("already registered") ||
    normalized.includes("already exists") ||
    normalized.includes("duplicate")
  );
}
