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
  blueCards?: FakeBlueCard[];
};

type FakeScorer = {
  clanTag: string;
  scorerPhone: string;
  minute: number;
  assistPhone?: string;
};

type FakeBlueCard = {
  clanTag: string;
  playerPhone: string;
  minute: number;
  second?: number;
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
  {
    phone: "+97338883679",
    displayName: "Madeline Coffey",
    username: "madeline_coffey",
    bio: "Free agent. Ready for the next match.",
    avatarUrl: "",
    followingCount: 0,
    fansCount: 0,
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
    timeSlot: "8:30 PM - 9:30 PM",
    matchDate: "2026-07-16",
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
await seedExistingClanMembers(
  admin,
  usersByPhone,
  clanIdsByTag,
  generatedSeed.existingClanMembersByTag,
);
await seedJoinRequests(
  admin,
  usersByPhone,
  clanIdsByTag,
  generatedSeed.joinRequests,
);
await refreshClanRecord(admin, requireClanId(clanIdsByTag, "TTR"));
const clanOwnerIdsByTag = await loadClanOwnerIds(admin, clanIdsByTag);
const fixtureIdsByKey = await seedFixtures(
  admin,
  clanIdsByTag,
  clanOwnerIdsByTag,
);
await seedFixtureScorers(admin, clanIdsByTag, usersByPhone, fixtureIdsByKey);
await seedFixtureMatchControl(
  admin,
  clanIdsByTag,
  usersByPhone,
  fixtureIdsByKey,
);
await refreshClanRecord(admin, requireClanId(clanIdsByTag, "TTR"));
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
  existingClanMembersByTag: Record<string, string[]>;
  joinRequests: Array<{ clanTag: string; profilePhone: string }>;
};

function buildGeneratedSeedData(): GeneratedSeedData {
  const users = buildGeneratedUsers(82);
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

  const tempeMemberPhones = takePhones(10);
  const joinRequests = users.slice(cursor, cursor + 3).map((user) => ({
    clanTag: "TTR",
    profilePhone: user.phone,
  }));
  const existingClanMembersByTag = { TTR: tempeMemberPhones };
  const memberPhonesByTag: Record<string, string[]> = {
    NRYL: [
      "+97338883671",
      "+97338883672",
      "+97338883673",
      ...baseClanMembersByTag.NRYL,
    ],
    MMAV: [
      "+97338883674",
      "+97338883675",
      "+97338883676",
      ...baseClanMembersByTag.MMAV,
    ],
    CDRF: [
      "+97338883677",
      "+97338883678",
      ...baseClanMembersByTag.CDRF,
    ],
    TTR: tempeMemberPhones,
    ...Object.fromEntries(
      clans.map((clan) => [clan.tag, clan.memberPhones]),
    ),
  };
  const tempeFixtures = buildTempeHistory(memberPhonesByTag);
  const fixtures = [
    ...tempeFixtures,
    ...buildSeasonLeagueHistory(
      memberPhonesByTag,
      [...fakeFixtures, ...tempeFixtures],
    ),
  ];
  const tempeHistory = fixtures.filter((fixture) =>
    fixture.homeTag === "TTR" || fixture.awayTag === "TTR"
  );

  for (const phone of tempeMemberPhones) {
    const user = users.find((candidate) => candidate.phone === phone);
    if (!user) continue;
    user.bio = "Tempe Tempuras player. Quick football, louder sidelines.";
    user.career = [
      {
        clanName: "Tempe Tempuras",
        tag: "TTR",
        emblem: "\u{1F42C}",
        period: "2026 - Present",
        apps: tempeHistory.length,
        goals: fixtures.reduce(
          (total, fixture) =>
            total +
            (fixture.scorers ?? []).filter(
              (scorer) =>
                scorer.clanTag === "TTR" && scorer.scorerPhone === phone,
            ).length,
          0,
        ),
        isCurrent: true,
      },
    ];
  }

  return {
    users,
    follows: buildGeneratedFollows(users),
    clans,
    fixtures,
    baseClanMembersByTag,
    existingClanMembersByTag,
    joinRequests,
  };
}

function buildTempeHistory(
  memberPhonesByTag: Record<string, string[]>,
): FakeFixture[] {
  const matchDates = [
    "2026-04-28",
    "2026-04-30",
    "2026-05-05",
    "2026-05-07",
    "2026-05-12",
    "2026-05-14",
    "2026-05-19",
    "2026-05-21",
    "2026-05-26",
    "2026-05-28",
    "2026-06-02",
    "2026-06-04",
    "2026-06-09",
    "2026-06-11",
    "2026-06-16",
    "2026-06-18",
    "2026-06-23",
    "2026-06-25",
    "2026-06-30",
    "2026-07-02",
    "2026-07-07",
  ];
  const opponents = [
    "RIFR",
    "MMAV",
    "PEAR",
    "TIDE",
    "CDRF",
    "DILM",
    "SAAR",
    "NRYL",
    "HIDD",
  ];
  const scorelines = [
    [3, 1],
    [2, 2],
    [1, 2],
    [4, 2],
    [0, 1],
    [3, 0],
    [1, 1],
    [2, 3],
    [5, 2],
    [2, 0],
    [1, 3],
    [3, 2],
    [0, 0],
    [2, 1],
    [1, 4],
    [4, 3],
    [2, 2],
    [3, 1],
    [0, 2],
    [2, 1],
    [3, 3],
  ];
  const venues = [
    "Central Sports Complex",
    "Riverside Park",
    "Eastside Arena",
    "Sunset Pitch",
  ];

  return matchDates.map((matchDate, index) => {
    const opponentTag = opponents[index % opponents.length];
    const [tempeGoals, opponentGoals] = scorelines[index];
    const tempeIsHome = index % 2 === 0;
    const homeTag = tempeIsHome ? "TTR" : opponentTag;
    const awayTag = tempeIsHome ? opponentTag : "TTR";
    const homeScore = tempeIsHome ? tempeGoals : opponentGoals;
    const awayScore = tempeIsHome ? opponentGoals : tempeGoals;
    const winnerTag = homeScore === awayScore
      ? undefined
      : homeScore > awayScore
      ? homeTag
      : awayTag;
    const date = new Date(`${matchDate}T00:00:00Z`);
    const scorers = [
      ...buildSeedScorers(
        "TTR",
        tempeGoals,
        memberPhonesByTag.TTR,
        index,
      ),
      ...buildSeedScorers(
        opponentTag,
        opponentGoals,
        memberPhonesByTag[opponentTag],
        index + 5,
      ),
    ].sort((first, second) => first.minute - second.minute);
    const blueCards: FakeBlueCard[] = [
      {
        clanTag: index % 3 === 0 ? "TTR" : opponentTag,
        playerPhone: memberPhonesByTag[index % 3 === 0 ? "TTR" : opponentTag][
          index %
          memberPhonesByTag[index % 3 === 0 ? "TTR" : opponentTag].length
        ],
        minute: 17 + (index % 12),
        second: (index * 7) % 60,
      },
    ];

    if (index % 5 === 0) {
      blueCards.push({
        clanTag: opponentTag,
        playerPhone: memberPhonesByTag[opponentTag][
          (index + 2) % memberPhonesByTag[opponentTag].length
        ],
        minute: 42 + (index % 8),
        second: (index * 11) % 60,
      });
    }

    return {
      status: "FINAL",
      homeTag,
      awayTag,
      venue: venues[index % venues.length],
      day: date.getUTCDay() === 2 ? "TUESDAY" : "THURSDAY",
      timeSlot: index % 2 === 0 ? "7:00 PM - 8:00 PM" : "8:30 PM - 9:30 PM",
      matchDate,
      homeScore,
      awayScore,
      winnerTag,
      scorers,
      blueCards,
    };
  });
}

function buildSeasonLeagueHistory(
  memberPhonesByTag: Record<string, string[]>,
  existingFixtures: FakeFixture[],
): FakeFixture[] {
  const seasonStartsOn = "2026-06-01";
  const historyEndsOn = "2026-07-09";
  const timeSlots: FakeFixture["timeSlot"][] = [
    "7:00 PM - 8:00 PM",
    "8:30 PM - 9:30 PM",
  ];
  const occupiedSlots = new Set(
    existingFixtures.map((fixture) =>
      `${fixture.matchDate}|${fixture.timeSlot}`
    ),
  );
  const availableSlots: Array<{
    matchDate: string;
    day: FakeFixture["day"];
    timeSlot: FakeFixture["timeSlot"];
  }> = [];
  const date = new Date(`${seasonStartsOn}T00:00:00Z`);
  const lastDate = new Date(`${historyEndsOn}T00:00:00Z`);

  while (date <= lastDate) {
    const day = date.getUTCDay();
    if (day === 2 || day === 4) {
      const matchDate = date.toISOString().slice(0, 10);
      for (const timeSlot of timeSlots) {
        if (!occupiedSlots.has(`${matchDate}|${timeSlot}`)) {
          availableSlots.push({
            matchDate,
            day: day === 2 ? "TUESDAY" : "THURSDAY",
            timeSlot,
          });
        }
      }
    }
    date.setUTCDate(date.getUTCDate() + 1);
  }

  const clanTags = Object.keys(memberPhonesByTag);
  const tagOrder = new Map(clanTags.map((tag, index) => [tag, index]));
  const gamesByTag = new Map(clanTags.map((tag) => [tag, 0]));
  const pairCounts = new Map<string, number>();

  for (const fixture of existingFixtures) {
    if (
      fixture.status !== "FINAL" ||
      fixture.matchDate < seasonStartsOn ||
      fixture.matchDate > historyEndsOn ||
      !fixture.awayTag
    ) {
      continue;
    }
    gamesByTag.set(
      fixture.homeTag,
      (gamesByTag.get(fixture.homeTag) ?? 0) + 1,
    );
    gamesByTag.set(
      fixture.awayTag,
      (gamesByTag.get(fixture.awayTag) ?? 0) + 1,
    );
    const pairKey = [fixture.homeTag, fixture.awayTag].sort().join("|");
    pairCounts.set(pairKey, (pairCounts.get(pairKey) ?? 0) + 1);
  }

  const scorelines = [
    [2, 1],
    [1, 1],
    [3, 0],
    [1, 2],
    [4, 2],
    [0, 0],
    [2, 3],
    [3, 2],
  ];
  const venues = [
    "Central Sports Complex",
    "Riverside Park",
    "Eastside Arena",
    "Sunset Pitch",
  ];
  const fixtures: FakeFixture[] = [];

  for (const [slotIndex, slot] of availableSlots.entries()) {
    if (
      clanTags.every((tag) => (gamesByTag.get(tag) ?? 0) >= 4)
    ) {
      break;
    }

    const rotation = slotIndex % clanTags.length;
    const rotatedOrder = (tag: string) =>
      ((tagOrder.get(tag) ?? 0) - rotation + clanTags.length) %
      clanTags.length;
    const ordered = [...clanTags].sort((first, second) =>
      (gamesByTag.get(first) ?? 0) - (gamesByTag.get(second) ?? 0) ||
      rotatedOrder(first) - rotatedOrder(second)
    );
    const firstTag = ordered[0];
    const secondTag = ordered.slice(1).sort((first, second) => {
      const gamesCompare = (gamesByTag.get(first) ?? 0) -
        (gamesByTag.get(second) ?? 0);
      if (gamesCompare !== 0) return gamesCompare;
      const firstPair = [firstTag, first].sort().join("|");
      const secondPair = [firstTag, second].sort().join("|");
      const pairCompare = (pairCounts.get(firstPair) ?? 0) -
        (pairCounts.get(secondPair) ?? 0);
      if (pairCompare !== 0) return pairCompare;
      return rotatedOrder(first) - rotatedOrder(second);
    })[0];
    const homeTag = slotIndex % 2 === 0 ? firstTag : secondTag;
    const awayTag = slotIndex % 2 === 0 ? secondTag : firstTag;
    const [homeScore, awayScore] = scorelines[slotIndex % scorelines.length];
    const winnerTag = homeScore === awayScore
      ? undefined
      : homeScore > awayScore
      ? homeTag
      : awayTag;
    const gameIndex = 100 + slotIndex;
    const scorers = [
      ...buildSeedScorers(
        homeTag,
        homeScore,
        memberPhonesByTag[homeTag],
        gameIndex,
      ),
      ...buildSeedScorers(
        awayTag,
        awayScore,
        memberPhonesByTag[awayTag],
        gameIndex + 7,
      ),
    ].sort((first, second) => first.minute - second.minute);
    const cardTag = slotIndex % 2 === 0 ? homeTag : awayTag;
    const cardRoster = memberPhonesByTag[cardTag];

    fixtures.push({
      status: "FINAL",
      homeTag,
      awayTag,
      venue: venues[slotIndex % venues.length],
      day: slot.day,
      timeSlot: slot.timeSlot,
      matchDate: slot.matchDate,
      homeScore,
      awayScore,
      winnerTag,
      scorers,
      blueCards: slotIndex % 3 === 1 ? [] : [{
        clanTag: cardTag,
        playerPhone: cardRoster[gameIndex % cardRoster.length],
        minute: 14 + (slotIndex % 28),
        second: (slotIndex * 17) % 60,
      }],
    });

    gamesByTag.set(homeTag, (gamesByTag.get(homeTag) ?? 0) + 1);
    gamesByTag.set(awayTag, (gamesByTag.get(awayTag) ?? 0) + 1);
    const pairKey = [homeTag, awayTag].sort().join("|");
    pairCounts.set(pairKey, (pairCounts.get(pairKey) ?? 0) + 1);
  }

  const unqualifiedTags = clanTags.filter((tag) =>
    (gamesByTag.get(tag) ?? 0) < 4
  );
  if (unqualifiedTags.length > 0) {
    throw new Error(
      `Not enough S0 history slots for: ${unqualifiedTags.join(", ")}`,
    );
  }

  return fixtures;
}

function buildSeedScorers(
  clanTag: string,
  goalCount: number,
  roster: string[],
  gameIndex: number,
): FakeScorer[] {
  return Array.from({ length: goalCount }, (_, goalIndex) => {
    const scorerIndex = (gameIndex + (goalIndex * 2)) % roster.length;
    const assistIndex = (scorerIndex + 1 + (goalIndex % 2)) % roster.length;
    const minute = 4 + ((gameIndex * 5 + goalIndex * 11) % 54);
    return {
      clanTag,
      scorerPhone: roster[scorerIndex],
      minute,
      assistPhone: (gameIndex + goalIndex) % 4 === 0
        ? undefined
        : roster[assistIndex],
    };
  });
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
    avatar_url: fakeUser.avatarUrl || null,
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
    admin.from("clan_join_requests").delete().in("profile_id", userIds),
    "delete seed join requests",
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
      left_at: null,
      removed_by: null,
      removal_reason: null,
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

async function seedExistingClanMembers(
  admin: AdminClient,
  userIdsByPhone: Map<string, string>,
  clanIdsByTag: Map<string, string>,
  memberPhonesByTag: Record<string, string[]>,
) {
  for (const [tag, memberPhones] of Object.entries(memberPhonesByTag)) {
    const { data: clan, error } = await admin
      .from("clans")
      .select("id")
      .eq("tag", tag)
      .single();

    if (error) {
      throw new Error(`load existing clan ${tag}: ${error.message}`);
    }

    const clanId = (clan as { id?: string }).id;
    if (!clanId) throw new Error(`Could not read existing clan id for ${tag}.`);
    clanIdsByTag.set(tag, clanId);

    const rows = memberPhones.map((phone) => ({
      clan_id: clanId,
      profile_id: requireUserId(userIdsByPhone, phone),
      role: "member",
      left_at: null,
      removed_by: null,
      removal_reason: null,
    }));
    await assertNoError(
      admin.from("clan_members").upsert(rows, {
        onConflict: "clan_id,profile_id",
      }),
      `upsert members for existing clan ${tag}`,
    );
  }
}

async function seedJoinRequests(
  admin: AdminClient,
  userIdsByPhone: Map<string, string>,
  clanIdsByTag: Map<string, string>,
  requests: Array<{ clanTag: string; profilePhone: string }>,
) {
  if (requests.length === 0) return;

  const rows = requests.map((request, index) => ({
    clan_id: requireClanId(clanIdsByTag, request.clanTag),
    profile_id: requireUserId(userIdsByPhone, request.profilePhone),
    status: "PENDING",
    requested_at: new Date(Date.now() - (index + 1) * 3_600_000).toISOString(),
    reviewed_at: null,
    reviewed_by: null,
    cancellation_code: null,
    cancellation_reason: null,
    cancelled_at: null,
    cancelled_by: null,
    cancellation_context: {},
  }));

  await assertNoError(
    admin.from("clan_join_requests").upsert(rows, {
      onConflict: "clan_id,profile_id",
    }),
    "upsert dev clan join requests",
  );
}

async function loadClanOwnerIds(
  admin: AdminClient,
  clanIdsByTag: Map<string, string>,
) {
  const { data, error } = await admin
    .from("clan_members")
    .select("clan_id,profile_id")
    .eq("role", "owner")
    .is("left_at", null)
    .in("clan_id", [...clanIdsByTag.values()]);

  if (error) throw new Error(`load clan owners: ${error.message}`);

  const tagsByClanId = new Map(
    [...clanIdsByTag.entries()].map(([tag, clanId]) => [clanId, tag]),
  );
  const ownerIdsByTag = new Map<string, string>();
  for (const row of data ?? []) {
    const clanId = (row as { clan_id?: string }).clan_id;
    const tag = clanId ? tagsByClanId.get(clanId) : undefined;
    const ownerId = (row as { profile_id?: string }).profile_id;
    if (tag && ownerId) ownerIdsByTag.set(tag, ownerId);
  }
  return ownerIdsByTag;
}

async function seedFixtures(
  admin: AdminClient,
  clanIdsByTag: Map<string, string>,
  clanOwnerIdsByTag: Map<string, string>,
) {
  const fixtureIdsByKey = new Map<string, string>();
  const { data: clanRows, error: clanError } = await admin
    .from("clans")
    .select("tag,skill_rating")
    .in("id", [...clanIdsByTag.values()]);
  if (clanError) throw new Error(`load clan ratings: ${clanError.message}`);
  const ratingsByTag = new Map<string, number>();
  for (const row of clanRows ?? []) {
    ratingsByTag.set(
      String((row as { tag?: string }).tag),
      Number((row as { skill_rating?: number }).skill_rating ?? 1500),
    );
  }
  const { data: activeRows, error: activeError } = await admin
    .from("fixtures")
    .select("match_date,time_slot")
    .in("status", ["OPEN", "SCHEDULED", "LIVE"]);
  if (activeError) {
    throw new Error(`load active fixture slots: ${activeError.message}`);
  }
  const activeSlots = new Set(
    (activeRows ?? []).map((row) =>
      `${String(row.match_date)}|${String(row.time_slot)}`
    ),
  );
  const fixturesToSeed = [...fakeFixtures].sort((first, second) =>
    `${first.matchDate}:${first.timeSlot}`.localeCompare(
      `${second.matchDate}:${second.timeSlot}`,
    )
  );

  for (const fixture of fixturesToSeed) {
    const activeSlotKey = `${fixture.matchDate}|${fixture.timeSlot}`;
    if (
      fixture.status !== "FINAL" &&
      activeSlots.has(activeSlotKey)
    ) {
      console.warn(
        `Skipping ${fixture.status} ${fixture.homeTag} on ${activeSlotKey}; ` +
          "the slot is already booked.",
      );
      continue;
    }

    let homeSrChange = fixture.homeSrChange ?? null;
    let awaySrChange = fixture.awaySrChange ?? null;
    if (
      fixture.status === "FINAL" &&
      fixture.awayTag &&
      fixture.homeScore != null &&
      fixture.awayScore != null
    ) {
      const delta = await calculateSrDelta(
        admin,
        requireRating(ratingsByTag, fixture.homeTag),
        requireRating(ratingsByTag, fixture.awayTag),
        fixture.homeScore,
        fixture.awayScore,
      );
      homeSrChange = delta.homeChange;
      awaySrChange = delta.awayChange;
      ratingsByTag.set(
        fixture.homeTag,
        Math.max(
          0,
          requireRating(ratingsByTag, fixture.homeTag) + homeSrChange,
        ),
      );
      ratingsByTag.set(
        fixture.awayTag,
        Math.max(
          0,
          requireRating(ratingsByTag, fixture.awayTag) + awaySrChange,
        ),
      );
    }
    const winnerTag = fixture.winnerTag ?? winnerTagFor(fixture);
    const homePayerId = requireMapValue(
      clanOwnerIdsByTag,
      fixture.homeTag,
      "clan owner",
    );
    const awayPayerId = fixture.awayTag
      ? requireMapValue(clanOwnerIdsByTag, fixture.awayTag, "clan owner")
      : null;
    const paidAt = fixtureTimestamp(fixture, -7 * 24 * 60, 0);
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
        winner_clan_id: winnerTag
          ? requireClanId(clanIdsByTag, winnerTag)
          : null,
        home_sr_change: homeSrChange,
        away_sr_change: awaySrChange,
        video_url: fixture.videoUrl ?? null,
        created_by: homePayerId,
        home_paid_by: homePayerId,
        away_paid_by: awayPayerId,
        home_paid_at: paidAt,
        away_paid_at: awayPayerId == null ? null : paidAt,
        created_at: paidAt,
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
    if (fixture.status !== "FINAL") activeSlots.add(activeSlotKey);
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

    return scorers.map((scorer, index) => ({
      fixture_id: fixtureId,
      clan_id: requireClanId(clanIdsByTag, scorer.clanTag),
      profile_id: requireUserId(userIdsByPhone, scorer.scorerPhone),
      assist_profile_id: scorer.assistPhone
        ? requireUserId(userIdsByPhone, scorer.assistPhone)
        : null,
      minute: scorer.minute,
      created_at: fixtureTimestamp(fixture, scorer.minute, index * 7),
    }));
  });

  if (rows.length === 0) return;

  await assertNoError(
    admin.from("fixture_scorers").insert(rows),
    "insert fixture scorers",
  );
}

async function seedFixtureMatchControl(
  admin: AdminClient,
  clanIdsByTag: Map<string, string>,
  userIdsByPhone: Map<string, string>,
  fixtureIdsByKey: Map<string, string>,
) {
  const finalFixtures = fakeFixtures.filter((fixture) =>
    fixture.status === "FINAL"
  );
  if (finalFixtures.length === 0) return;

  const clockRows = finalFixtures.map((fixture) => ({
    fixture_id: requireFixtureId(fixtureIdsByKey, fixture),
    status: "ENDED",
    started_at: null,
    accumulated_seconds: 3600,
    duration_seconds: 3600,
  }));
  await assertNoError(
    admin.from("fixture_clock_states").upsert(clockRows, {
      onConflict: "fixture_id",
    }),
    "upsert final fixture clocks",
  );

  const eventRows: Record<string, unknown>[] = [];
  for (const fixture of finalFixtures) {
    const fixtureId = requireFixtureId(fixtureIdsByKey, fixture);
    eventRows.push(
      fixtureEventRow(fixtureId, fixture, "MATCH_STARTED", 0, 0),
      fixtureEventRow(fixtureId, fixture, "MATCH_PAUSED", 30, 0),
      fixtureEventRow(fixtureId, fixture, "MATCH_RESUMED", 30, 45),
      fixtureEventRow(fixtureId, fixture, "MATCH_ENDED", 60, 0),
    );

    for (const [index, scorer] of (fixture.scorers ?? []).entries()) {
      eventRows.push(
        fixtureEventRow(
          fixtureId,
          fixture,
          "GOAL",
          scorer.minute,
          (index * 13) % 60,
          {
            clan_id: requireClanId(clanIdsByTag, scorer.clanTag),
            profile_id: requireUserId(userIdsByPhone, scorer.scorerPhone),
            assist_profile_id: scorer.assistPhone
              ? requireUserId(userIdsByPhone, scorer.assistPhone)
              : null,
          },
        ),
      );
    }

    for (const card of fixture.blueCards ?? []) {
      const second = card.second ?? 0;
      const startedAt = fixtureTimestamp(fixture, card.minute, second);
      const expiresAt = new Date(
        new Date(startedAt).getTime() + (120 * 1000),
      ).toISOString();
      const { data: cardRow, error: cardError } = await admin
        .from("fixture_blue_cards")
        .insert({
          fixture_id: fixtureId,
          clan_id: requireClanId(clanIdsByTag, card.clanTag),
          profile_id: requireUserId(userIdsByPhone, card.playerPhone),
          started_at: startedAt,
          expires_at: expiresAt,
          duration_seconds: 120,
          status: "CLEARED",
          minute: card.minute,
          second,
          created_at: startedAt,
        })
        .select("id")
        .single();
      if (cardError) {
        throw new Error(`insert fixture blue card: ${cardError.message}`);
      }
      const blueCardId = (cardRow as { id?: string }).id;
      if (!blueCardId) throw new Error("Could not read seeded blue card id.");

      eventRows.push(
        fixtureEventRow(
          fixtureId,
          fixture,
          "BLUE_CARD",
          card.minute,
          second,
          {
            clan_id: requireClanId(clanIdsByTag, card.clanTag),
            profile_id: requireUserId(userIdsByPhone, card.playerPhone),
            blue_card_id: blueCardId,
          },
        ),
        fixtureEventRow(
          fixtureId,
          fixture,
          "BLUE_CARD_EXPIRED",
          card.minute + 2,
          second,
          {
            clan_id: requireClanId(clanIdsByTag, card.clanTag),
            profile_id: requireUserId(userIdsByPhone, card.playerPhone),
            blue_card_id: blueCardId,
          },
        ),
      );
    }
  }

  eventRows.sort((first, second) =>
    String(first.created_at).localeCompare(String(second.created_at))
  );
  await assertNoError(
    admin.from("fixture_events").insert(eventRows),
    "insert fixture timeline events",
  );
}

function fixtureEventRow(
  fixtureId: string,
  fixture: FakeFixture,
  eventType: string,
  minute: number,
  second: number,
  values: Record<string, unknown> = {},
) {
  return {
    fixture_id: fixtureId,
    event_type: eventType,
    clan_id: null,
    profile_id: null,
    assist_profile_id: null,
    blue_card_id: null,
    minute,
    second,
    note: "",
    created_at: fixtureTimestamp(fixture, minute, second),
    ...values,
  };
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
    const profilesWithSeededCareers = fakeUsers
      .filter((fakeUser) => (fakeUser.career?.length ?? 0) > 0)
      .map((fakeUser) => requireUserId(userIdsByPhone, fakeUser.phone));
    await assertNoError(
      admin
        .from("profile_career_entries")
        .delete()
        .in("profile_id", profilesWithSeededCareers),
      "replace generated career entries",
    );
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

async function calculateSrDelta(
  admin: AdminClient,
  homeRating: number,
  awayRating: number,
  homeScore: number,
  awayScore: number,
) {
  const { data, error } = await admin.rpc("calculate_fixture_sr_delta", {
    home_rating: homeRating,
    away_rating: awayRating,
    home_score: homeScore,
    away_score: awayScore,
  });
  if (error) throw new Error(`calculate fixture SR: ${error.message}`);
  const row = Array.isArray(data) ? data[0] : data;
  const homeChange = Number((row as { home_change?: number }).home_change);
  const awayChange = Number((row as { away_change?: number }).away_change);
  if (!Number.isFinite(homeChange) || !Number.isFinite(awayChange)) {
    throw new Error("Could not read calculated fixture SR.");
  }
  return { homeChange, awayChange };
}

async function refreshClanRecord(admin: AdminClient, clanId: string) {
  const { data, error } = await admin
    .from("fixtures")
    .select(
      "home_clan_id,away_clan_id,home_score,away_score,home_sr_change,away_sr_change",
    )
    .eq("status", "FINAL")
    .or(`home_clan_id.eq.${clanId},away_clan_id.eq.${clanId}`);
  if (error) throw new Error(`load clan record: ${error.message}`);

  let wins = 0;
  let losses = 0;
  let skillRating = 1500;
  for (const row of data ?? []) {
    const isHome = row.home_clan_id === clanId;
    const myScore = Number(isHome ? row.home_score : row.away_score);
    const opponentScore = Number(isHome ? row.away_score : row.home_score);
    const srChange = Number(
      isHome ? row.home_sr_change ?? 0 : row.away_sr_change ?? 0,
    );
    if (myScore > opponentScore) wins += 1;
    if (myScore < opponentScore) losses += 1;
    skillRating = Math.max(0, skillRating + srChange);
  }

  await assertNoError(
    admin.from("clans").update({
      wins,
      losses,
      skill_rating: skillRating,
    }).eq("id", clanId),
    "refresh clan record",
  );
}

function winnerTagFor(fixture: FakeFixture) {
  if (
    !fixture.awayTag ||
    fixture.homeScore == null ||
    fixture.awayScore == null ||
    fixture.homeScore === fixture.awayScore
  ) {
    return undefined;
  }
  return fixture.homeScore > fixture.awayScore
    ? fixture.homeTag
    : fixture.awayTag;
}

function fixtureTimestamp(
  fixture: FakeFixture,
  minute: number,
  second: number,
) {
  const startTime = fixture.timeSlot.startsWith("7:00")
    ? "16:00:00Z"
    : "17:30:00Z";
  const timestamp = new Date(`${fixture.matchDate}T${startTime}`);
  timestamp.setUTCSeconds(timestamp.getUTCSeconds() + minute * 60 + second);
  return timestamp.toISOString();
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

function requireFixtureId(
  fixtureIdsByKey: Map<string, string>,
  fixture: FakeFixture,
) {
  const fixtureId = fixtureIdsByKey.get(fixtureKey(fixture));
  if (!fixtureId) {
    throw new Error(`Missing seeded fixture id for ${fixtureKey(fixture)}.`);
  }
  return fixtureId;
}

function requireRating(ratingsByTag: Map<string, number>, tag: string) {
  const rating = ratingsByTag.get(tag);
  if (rating == null) throw new Error(`Missing seeded rating for ${tag}.`);
  return rating;
}

function requireMapValue(
  values: Map<string, string>,
  key: string,
  label: string,
) {
  const value = values.get(key);
  if (!value) throw new Error(`Missing seeded ${label} for ${key}.`);
  return value;
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
