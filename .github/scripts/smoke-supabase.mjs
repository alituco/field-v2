const required = (name) => {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required.`);
  }
  return value;
};

const knownProjectRefs = {
  staging: "nfdkdhdevpstfspazbfn",
  production: "zjsjuuhborxrlmdcpvlj",
};

const environment = required("FIELD_ENVIRONMENT");
const expectedProjectRef = required("SUPABASE_PROJECT_REF");
const supabaseUrl = required("SUPABASE_URL").replace(/\/+$/, "");
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
const apiKey =
  serviceRoleKey || required("SUPABASE_PUBLISHABLE_KEY");

if (!(environment in knownProjectRefs)) {
  throw new Error("FIELD_ENVIRONMENT must be staging or production.");
}
if (expectedProjectRef !== knownProjectRefs[environment]) {
  throw new Error(
    `${environment} is configured with an unexpected Supabase project ref.`,
  );
}

const url = new URL(supabaseUrl);
if (
  url.protocol !== "https:" ||
  url.hostname !== `${expectedProjectRef}.supabase.co` ||
  url.port !== "" ||
  url.username !== "" ||
  url.password !== "" ||
  url.pathname !== "/" ||
  url.search !== "" ||
  url.hash !== ""
) {
  throw new Error("SUPABASE_URL does not match the guarded project ref.");
}

const headers = {
  apikey: apiKey,
  Authorization: `Bearer ${apiKey}`,
};

async function request(path, init = {}) {
  const response = await fetch(`${supabaseUrl}${path}`, {
    ...init,
    headers: {
      ...headers,
      ...init.headers,
    },
  });
  if (!response.ok) {
    throw new Error(`${path} failed with HTTP ${response.status}.`);
  }
  return response;
}

async function assertAnonymousAccessDenied(table) {
  const response = await fetch(
    `${supabaseUrl}/rest/v1/${table}?select=id&limit=1`,
    { headers },
  );
  if (response.ok) {
    throw new Error(
      `${table} unexpectedly allowed anonymous reads; check grants and RLS.`,
    );
  }
  if (![401, 403].includes(response.status)) {
    throw new Error(
      `${table} returned unexpected HTTP ${response.status} during the RLS check.`,
    );
  }
}

function exactCount(response) {
  const contentRange = response.headers.get("content-range");
  const rawCount = contentRange?.split("/").pop();
  const count = Number.parseInt(rawCount ?? "", 10);
  if (!Number.isFinite(count)) {
    throw new Error("Supabase did not return an exact row count.");
  }
  return count;
}

const health = await request("/auth/v1/health");
const healthPayload = await health.json();
if (typeof healthPayload !== "object" || healthPayload === null) {
  throw new Error("Auth health returned an invalid payload.");
}

const tables = [
  "clans",
  "open_queue_games",
];
if (serviceRoleKey) {
  tables.push(
    "profiles",
    "fixtures",
    "season_zero_waitlist",
    "reliability_policy_versions",
  );
}

if (!serviceRoleKey) {
  // Fieldrush deliberately exposes public profile columns only to signed-in
  // users. An anonymous profile read succeeding is a privacy regression.
  await assertAnonymousAccessDenied("profiles");
  await assertAnonymousAccessDenied("season_zero_waitlist");
  await assertAnonymousAccessDenied("reliability_policy_versions");
}
const counts = {};

for (const table of tables) {
  const response = await request(
    `/rest/v1/${table}?select=id&limit=1`,
    { headers: { Prefer: "count=exact" } },
  );
  counts[table] = exactCount(response);
}

if (
  serviceRoleKey &&
  counts.reliability_policy_versions < 1
) {
  throw new Error("No reliability policy exists after migration.");
}

console.log(
  `Supabase ${environment} smoke check passed for ${expectedProjectRef}.`,
);
for (const table of tables) {
  console.log(`${table}: ${counts[table]} row(s)`);
}
