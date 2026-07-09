import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";

type AdminClient = ReturnType<typeof createClient<any, "public", any>>;

type FakeUser = {
  phone: string;
  displayName: string;
  username: string;
  bio: string;
  avatarUrl: string;
  followingCount: number;
  fansCount: number;
  highlights?: FakeHighlight[];
  career?: FakeCareerEntry[];
};

type FakeHighlight = {
  title: string;
  thumbnailUrl: string;
  duration: string;
  views: number;
  clanTag?: string;
};

type FakeCareerEntry = {
  clanName: string;
  tag: string;
  emblem: string;
  period: string;
  apps: number;
  goals: number;
  isCurrent?: boolean;
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
  region?: string;
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
  scorers?: FakeScorer[];
};

type FakeScorer = {
  clanTag: string;
  scorerPhone: string;
  minute: number;
  assistPhone?: string;
};

type FakeFollow = {
  followerPhone: string;
  followingPhone: string;
};

const fakeUsers: FakeUser[] = [
  {
    phone: "+97338883671",
    displayName: "Zara Haddad",
    username: "zara_strikes",
    bio: "Left foot, late runs, no wasted touches.",
    avatarUrl:
      "https://images.unsplash.com/photo-1516224498413-84ecf3a1e7fd?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400",
    followingCount: 3,
    fansCount: 5,
    highlights: [
      {
        title: "Last-minute winner vs CDRF",
        thumbnailUrl:
          "https://images.unsplash.com/photo-1517466787929-bc90951d0974?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=600",
        duration: "0:38",
        views: 12400,
        clanTag: "NRYL",
      },
      {
        title: "Solo run and finish",
        thumbnailUrl:
          "https://images.unsplash.com/photo-1631478854728-b4a5479d1d36?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=600",
        duration: "0:22",
        views: 8700,
        clanTag: "NRYL",
      },
      {
        title: "Four goal night highlights",
        thumbnailUrl:
          "https://images.unsplash.com/photo-1611122261270-3171e87a5567?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=600",
        duration: "1:05",
        views: 21300,
        clanTag: "NRYL",
      },
    ],
    career: [
      {
        clanName: "Neon Royals",
        tag: "NRYL",
        emblem: "\u{1F451}",
        period: "2025 - Present",
        apps: 34,
        goals: 41,
        isCurrent: true,
      },
      {
        clanName: "Riverside Rovers",
        tag: "RVR",
        emblem: "\u{1F30A}",
        period: "2023 - 2025",
        apps: 58,
        goals: 52,
      },
      {
        clanName: "Sunset Strikers",
        tag: "SUN",
        emblem: "\u{2600}",
        period: "2021 - 2023",
        apps: 40,
        goals: 23,
      },
    ],
  },
  {
    phone: "+97338883672",
    displayName: "Omar Saleh",
    username: "omar_gloves",
    bio: "Keeper first, captain when it gets loud.",
    avatarUrl:
      "https://images.unsplash.com/photo-1568834643193-f5373acc1659?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400",
    followingCount: 2,
    fansCount: 4,
    career: [
      {
        clanName: "Neon Royals",
        tag: "NRYL",
        emblem: "\u{1F451}",
        period: "2025 - Present",
        apps: 29,
        goals: 4,
        isCurrent: true,
      },
    ],
  },
  {
    phone: "+97338883673",
    displayName: "Noor Khalid",
    username: "noor_engine",
    bio: "Tempo setter. Finds the pass before the pass.",
    avatarUrl:
      "https://images.unsplash.com/photo-1671680134709-4978c22fb916?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400",
    followingCount: 5,
    fansCount: 7,
    career: [
      {
        clanName: "Neon Royals",
        tag: "NRYL",
        emblem: "\u{1F451}",
        period: "2026 - Present",
        apps: 18,
        goals: 12,
        isCurrent: true,
      },
    ],
  },
  {
    phone: "+97338883674",
    displayName: "Maya Faris",
    username: "maya_mint",
    bio: "Quick turns, clean finishes, calm head.",
    avatarUrl:
      "https://images.unsplash.com/photo-1568927198336-e9ae04365910?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400",
    followingCount: 4,
    fansCount: 6,
    highlights: [
      {
        title: "Counter attack clinic",
        thumbnailUrl:
          "https://images.unsplash.com/photo-1667842501559-6c03ae022505?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=600",
        duration: "0:29",
        views: 6900,
        clanTag: "MMAV",
      },
    ],
    career: [
      {
        clanName: "Mint Mavericks",
        tag: "MMAV",
        emblem: "\u{26A1}",
        period: "2025 - Present",
        apps: 25,
        goals: 19,
        isCurrent: true,
      },
    ],
  },
  {
    phone: "+97338883675",
    displayName: "Sami Nasser",
    username: "sami_switch",
    bio: "Box-to-box runner with one more sprint left.",
    avatarUrl:
      "https://images.unsplash.com/photo-1623452088642-5bd2f74780cc?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400",
    followingCount: 1,
    fansCount: 3,
    career: [
      {
        clanName: "Mint Mavericks",
        tag: "MMAV",
        emblem: "\u{26A1}",
        period: "2026 - Present",
        apps: 14,
        goals: 5,
        isCurrent: true,
      },
    ],
  },
  {
    phone: "+97338883676",
    displayName: "Lina Abbas",
    username: "lina_lines",
    bio: "Press trigger, recovery run, repeat.",
    avatarUrl:
      "https://images.unsplash.com/photo-1542393881816-df51684879df?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400",
    followingCount: 6,
    fansCount: 2,
    career: [
      {
        clanName: "Mint Mavericks",
        tag: "MMAV",
        emblem: "\u{26A1}",
        period: "2025 - Present",
        apps: 21,
        goals: 8,
        isCurrent: true,
      },
    ],
  },
  {
    phone: "+97338883677",
    displayName: "Rami Darwish",
    username: "rami_drift",
    bio: "Direct winger. Likes the far post.",
    avatarUrl:
      "https://images.unsplash.com/photo-1739567994955-6441a2fbb62d?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400",
    followingCount: 2,
    fansCount: 2,
    career: [
      {
        clanName: "Crimson Drift",
        tag: "CDRF",
        emblem: "\u{1F525}",
        period: "2025 - Present",
        apps: 22,
        goals: 11,
        isCurrent: true,
      },
    ],
  },
  {
    phone: "+97338883678",
    displayName: "Hala Mansour",
    username: "hala_hold",
    bio: "Anchor in midfield, first outlet under pressure.",
    avatarUrl:
      "https://images.unsplash.com/photo-1779304551934-3a25eaaa22dc?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=400",
    followingCount: 3,
    fansCount: 1,
    career: [
      {
        clanName: "Crimson Drift",
        tag: "CDRF",
        emblem: "\u{1F525}",
        period: "2026 - Present",
        apps: 13,
        goals: 3,
        isCurrent: true,
      },
    ],
  },
];

const fakeFollows: FakeFollow[] = [
  { followerPhone: "+97338883671", followingPhone: "+97338883672" },
  { followerPhone: "+97338883671", followingPhone: "+97338883673" },
  { followerPhone: "+97338883671", followingPhone: "+97338883674" },
  { followerPhone: "+97338883672", followingPhone: "+97338883671" },
  { followerPhone: "+97338883672", followingPhone: "+97338883673" },
  { followerPhone: "+97338883673", followingPhone: "+97338883671" },
  { followerPhone: "+97338883673", followingPhone: "+97338883672" },
  { followerPhone: "+97338883673", followingPhone: "+97338883674" },
  { followerPhone: "+97338883673", followingPhone: "+97338883675" },
  { followerPhone: "+97338883673", followingPhone: "+97338883676" },
  { followerPhone: "+97338883674", followingPhone: "+97338883671" },
  { followerPhone: "+97338883674", followingPhone: "+97338883673" },
  { followerPhone: "+97338883674", followingPhone: "+97338883675" },
  { followerPhone: "+97338883674", followingPhone: "+97338883676" },
  { followerPhone: "+97338883675", followingPhone: "+97338883672" },
  { followerPhone: "+97338883676", followingPhone: "+97338883671" },
  { followerPhone: "+97338883676", followingPhone: "+97338883673" },
  { followerPhone: "+97338883677", followingPhone: "+97338883671" },
  { followerPhone: "+97338883677", followingPhone: "+97338883673" },
  { followerPhone: "+97338883678", followingPhone: "+97338883671" },
  { followerPhone: "+97338883678", followingPhone: "+97338883672" },
  { followerPhone: "+97338883678", followingPhone: "+97338883677" },
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
    day: "THURSDAY",
    timeSlot: "7:00 PM - 8:00 PM",
    matchDate: "2026-07-09",
  },
  {
    status: "SCHEDULED",
    homeTag: "CDRF",
    awayTag: "NRYL",
    venue: "Riverside Park",
    day: "THURSDAY",
    timeSlot: "8:30 PM - 9:30 PM",
    matchDate: "2026-07-23",
  },
  {
    status: "OPEN",
    homeTag: "MMAV",
    venue: "Sunset Pitch",
    day: "TUESDAY",
    timeSlot: "7:00 PM - 8:00 PM",
    matchDate: "2026-07-28",
  },
  {
    status: "OPEN",
    homeTag: "NRYL",
    venue: "Eastside Arena",
    day: "THURSDAY",
    timeSlot: "8:30 PM - 9:30 PM",
    matchDate: "2026-07-30",
  },
];

const generatedSeed = buildGeneratedSeedData();

fakeUsers.push(...generatedSeed.users);
fakeFollows.push(...generatedSeed.follows);

for (
  const [tag, memberPhones] of Object.entries(
    generatedSeed.baseClanMembersByTag,
  )
) {
  const clan = fakeClans.find((candidate) => candidate.tag === tag);
  if (!clan) {
    throw new Error(`Missing base clan ${tag} for generated members.`);
  }
  clan.memberPhones.push(...memberPhones);
}

fakeClans.push(...generatedSeed.clans);
fakeFixtures.push(...generatedSeed.fixtures);

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
const fixtureIdsByKey = await seedFixtures(admin, clanIdsByTag);
await seedFixtureScorers(admin, clanIdsByTag, usersByPhone, fixtureIdsByKey);
await seedProfileDetails(admin, usersByPhone);
await seedFollows(admin, usersByPhone);

console.log("");
console.log("Seeded dev users:");
for (const fakeUser of fakeUsers.slice(0, 18)) {
  console.log(`  ${fakeUser.phone}  ${fakeUser.displayName}`);
}
if (fakeUsers.length > 18) {
  console.log(`  ... ${fakeUsers.length - 18} more users`);
}
console.log("");
console.log("Seeded dev clans:");
for (const fakeClan of fakeClans) {
  console.log(`  ${fakeClan.tag}  ${fakeClan.name}`);
}
console.log("");
console.log("Seeded dev fixtures:");
for (const fakeFixture of fakeFixtures.slice(0, 18)) {
  console.log(
    `  ${fakeFixture.status}  ${fakeFixture.homeTag} ${
      fakeFixture.awayTag ? "vs " + fakeFixture.awayTag : "open"
    }`,
  );
}
if (fakeFixtures.length > 18) {
  console.log(`  ... ${fakeFixtures.length - 18} more fixtures`);
}

type GeneratedSeedData = {
  users: FakeUser[];
  follows: FakeFollow[];
  clans: FakeClan[];
  fixtures: FakeFixture[];
  baseClanMembersByTag: Record<string, string[]>;
};

function buildGeneratedSeedData(): GeneratedSeedData {
  const users = buildGeneratedUsers(72);
  let cursor = 0;
  const takePhones = (count: number) => {
    const phones = users.slice(cursor, cursor + count).map((user) =>
      user.phone
    );
    cursor += count;
    return phones;
  };

  const baseClanMembersByTag: Record<string, string[]> = {
    NRYL: takePhones(6),
    MMAV: takePhones(6),
    CDRF: takePhones(7),
  };

  const generatedClanSpecs = [
    {
      name: "Pearl United",
      tag: "PEAR",
      motto: "Keep it sharp, keep it moving.",
      emblem: "\u{1F48E}",
      themeId: "pitch",
      patternId: "sash",
      skillRating: 1985,
      wins: 15,
      losses: 7,
    },
    {
      name: "Dilmun FC",
      tag: "DILM",
      motto: "Old roots, quick feet.",
      emblem: "\u{1F3DB}",
      themeId: "gold",
      patternId: "solid",
      skillRating: 1840,
      wins: 13,
      losses: 8,
    },
    {
      name: "Tide Runners",
      tag: "TIDE",
      motto: "Press high, recover faster.",
      emblem: "\u{1F30A}",
      themeId: "electric",
      patternId: "chevron",
      skillRating: 1710,
      wins: 12,
      losses: 10,
    },
    {
      name: "Riffa Raiders",
      tag: "RIFR",
      motto: "No easy touches.",
      emblem: "\u{1F6E1}",
      themeId: "shadow",
      patternId: "stripes",
      skillRating: 1545,
      wins: 10,
      losses: 10,
    },
    {
      name: "Saar City",
      tag: "SAAR",
      motto: "Win the middle, win the night.",
      emblem: "\u{1F3D9}",
      themeId: "mint",
      patternId: "pitch",
      skillRating: 1420,
      wins: 8,
      losses: 12,
    },
    {
      name: "Hidd Heat",
      tag: "HIDD",
      motto: "Fast starts, louder finishes.",
      emblem: "\u{1F525}",
      themeId: "sunset",
      patternId: "sash",
      skillRating: 1315,
      wins: 7,
      losses: 14,
    },
  ];

  const clans = generatedClanSpecs.map((spec) => {
    const memberPhones = takePhones(8);
    return {
      ...spec,
      ownerPhone: memberPhones[0],
      memberPhones,
    };
  });

  return {
    users,
    follows: buildGeneratedFollows(users),
    clans,
    fixtures: [],
    baseClanMembersByTag,
  };
}

function buildGeneratedUsers(count: number): FakeUser[] {
  const firstNames = [
    "Ali",
    "Noura",
    "Hamad",
    "Mariam",
    "Yousef",
    "Layla",
    "Faisal",
    "Dana",
    "Salman",
    "Reem",
    "Khalid",
    "Noor",
    "Rashid",
    "Sara",
    "Jassim",
    "Maya",
  ];
  const lastNames = [
    "Alawi",
    "Saleh",
    "Haddad",
    "Mansoor",
    "Khalifa",
    "Nasser",
    "Faraj",
    "Jaber",
    "Sayed",
    "Mahmood",
    "Qasim",
    "Habib",
  ];

  return Array.from({ length: count }, (_, index) => {
    const firstName = firstNames[index % firstNames.length];
    const lastName =
      lastNames[Math.floor(index / firstNames.length) % lastNames.length];
    const username = `bh_${firstName.toLowerCase()}_${
      (index + 1)
        .toString()
        .padStart(2, "0")
    }`;

    return {
      phone: generatedPhone(index),
      displayName: `${firstName} ${lastName}`,
      username,
      bio: "Dev league player. Seeded for match history.",
      avatarUrl:
        `https://ui-avatars.com/api/?name=${firstName}+${lastName}&background=10B981&color=fff&bold=true`,
      followingCount: 0,
      fansCount: 0,
    };
  });
}

function buildGeneratedFollows(users: FakeUser[]): FakeFollow[] {
  const follows: FakeFollow[] = [];

  for (let i = 0; i < users.length; i += 1) {
    for (const offset of [1, 3, 8]) {
      const target = users[(i + offset) % users.length];
      if (target.phone === users[i].phone) continue;
      follows.push({
        followerPhone: users[i].phone,
        followingPhone: target.phone,
      });
    }
  }

  return follows;
}

function generatedPhone(index: number) {
  return `+973${(38900001 + index).toString()}`;
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
    username: fakeUser.username,
    bio: fakeUser.bio,
    avatar_url: fakeUser.avatarUrl,
    following_count: countFollowing(fakeUser.phone),
    fans_count: countFans(fakeUser.phone),
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
  const seedClanIds = await loadSeedClanIds(admin, userIds, clanTags);

  await assertNoError(
    admin.from("profile_follows").delete().in("follower_id", userIds),
    "delete seed follows",
  );
  await assertNoError(
    admin.from("profile_follows").delete().in("following_id", userIds),
    "delete seed fans",
  );
  await assertNoError(
    admin.from("profile_highlights").delete().in("profile_id", userIds),
    "delete seed highlights",
  );
  await assertNoError(
    admin.from("profile_career_entries").delete().in("profile_id", userIds),
    "delete seed career entries",
  );
  await assertNoError(
    admin.from("fixtures").delete().in("created_by", userIds),
    "delete seed-created fixtures",
  );
  if (seedClanIds.length > 0) {
    await assertNoError(
      admin.from("fixtures").delete().in("home_clan_id", seedClanIds),
      "delete seed home fixtures",
    );
    await assertNoError(
      admin.from("fixtures").delete().in("away_clan_id", seedClanIds),
      "delete seed away fixtures",
    );
  }
  await assertNoError(
    admin.from("fixture_scorers").delete().in("profile_id", userIds),
    "delete seed scorer rows",
  );
  await assertNoError(
    admin.from("fixture_scorers").delete().in("assist_profile_id", userIds),
    "delete seed assist rows",
  );
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

async function loadSeedClanIds(
  admin: AdminClient,
  userIds: string[],
  clanTags: string[],
) {
  const ids = new Set<string>();

  const { data: clansByTag, error: tagError } = await admin
    .from("clans")
    .select("id")
    .in("tag", clanTags);

  if (tagError) {
    throw new Error(`load seed clans by tag: ${tagError.message}`);
  }

  for (const row of clansByTag ?? []) {
    const id = (row as { id?: string }).id;
    if (id) ids.add(id);
  }

  const { data: clansByOwner, error: ownerError } = await admin
    .from("clans")
    .select("id")
    .in("created_by", userIds);

  if (ownerError) {
    throw new Error(`load seed clans by owner: ${ownerError.message}`);
  }

  for (const row of clansByOwner ?? []) {
    const id = (row as { id?: string }).id;
    if (id) ids.add(id);
  }

  return [...ids];
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
        region: fakeClan.region ?? "bahrain",
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
  const fixtureIdsByKey = new Map<string, string>();

  for (const fixture of fakeFixtures) {
    const { data, error } = await admin
      .from("fixtures")
      .insert({
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
      })
      .select("id")
      .single();

    if (error) {
      throw error;
    }

    const fixtureId = (data as { id?: string }).id;
    if (!fixtureId) {
      throw new Error(`Could not read fixture id for ${fixtureKey(fixture)}.`);
    }
    fixtureIdsByKey.set(fixtureKey(fixture), fixtureId);
  }

  return fixtureIdsByKey;
}

async function seedFixtureScorers(
  admin: AdminClient,
  clanIdsByTag: Map<string, string>,
  userIdsByPhone: Map<string, string>,
  fixtureIdsByKey: Map<string, string>,
) {
  const rows = fakeFixtures.flatMap((fixture) => {
    const scorers = fixture.scorers ?? [];
    const fixtureId = fixtureIdsByKey.get(fixtureKey(fixture));

    if (scorers.length > 0 && !fixtureId) {
      throw new Error(`Missing seeded fixture id for ${fixtureKey(fixture)}.`);
    }

    return scorers.map((scorer) => ({
      fixture_id: fixtureId,
      clan_id: requireClanId(clanIdsByTag, scorer.clanTag),
      profile_id: requireUserId(userIdsByPhone, scorer.scorerPhone),
      assist_profile_id: scorer.assistPhone
        ? requireUserId(userIdsByPhone, scorer.assistPhone)
        : null,
      minute: scorer.minute,
    }));
  });

  if (rows.length === 0) return;

  await assertNoError(
    admin.from("fixture_scorers").insert(rows),
    "insert fixture scorers",
  );
}

async function seedProfileDetails(
  admin: AdminClient,
  userIdsByPhone: Map<string, string>,
) {
  const highlightRows = fakeUsers.flatMap((fakeUser) => {
    const profileId = requireUserId(userIdsByPhone, fakeUser.phone);
    return (fakeUser.highlights ?? []).map((highlight, index) => ({
      profile_id: profileId,
      title: highlight.title,
      thumbnail_url: highlight.thumbnailUrl,
      duration: highlight.duration,
      views: highlight.views,
      clan_tag: highlight.clanTag ?? null,
      sort_order: index,
    }));
  });

  if (highlightRows.length > 0) {
    await assertNoError(
      admin.from("profile_highlights").insert(highlightRows),
      "insert profile highlights",
    );
  }

  const careerRows = fakeUsers.flatMap((fakeUser) => {
    const profileId = requireUserId(userIdsByPhone, fakeUser.phone);
    return (fakeUser.career ?? []).map((entry, index) => ({
      profile_id: profileId,
      clan_name: entry.clanName,
      tag: entry.tag,
      emblem: entry.emblem,
      period: entry.period,
      apps: entry.apps,
      goals: entry.goals,
      is_current: entry.isCurrent ?? false,
      sort_order: index,
    }));
  });

  if (careerRows.length > 0) {
    await assertNoError(
      admin.from("profile_career_entries").insert(careerRows),
      "insert profile career entries",
    );
  }
}

async function seedFollows(
  admin: AdminClient,
  userIdsByPhone: Map<string, string>,
) {
  const rows = fakeFollows.map((follow) => ({
    follower_id: requireUserId(userIdsByPhone, follow.followerPhone),
    following_id: requireUserId(userIdsByPhone, follow.followingPhone),
  }));

  if (rows.length === 0) return;

  await assertNoError(
    admin.from("profile_follows").upsert(rows, {
      onConflict: "follower_id,following_id",
    }),
    "upsert profile follows",
  );
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

function fixtureKey(fixture: FakeFixture) {
  return [
    fixture.homeTag,
    fixture.awayTag ?? "OPEN",
    fixture.matchDate,
    fixture.timeSlot,
  ].join(":");
}

function countFollowing(phone: string) {
  return fakeFollows.filter((follow) => follow.followerPhone === phone).length;
}

function countFans(phone: string) {
  return fakeFollows.filter((follow) => follow.followingPhone === phone).length;
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
