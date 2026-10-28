import {
  createClient,
  type SupabaseClient,
  type User,
} from "https://esm.sh/@supabase/supabase-js@2.86.0";

import {
  assertSafeDevDataTarget,
  FIELD_STAGING_PROJECT_REF,
  type SafeDevDataTarget,
} from "../_shared/environment_guard.ts";

export const E2E_SCHEMA_VERSION = 2;
export const E2E_VENUE_PREFIX = "[FIELD E2E";
export const E2E_PROFILE_PREFIX = "[E2E]";
export const E2E_DEFAULT_BIRTH_DATE = "2000-01-01";
export const E2E_DEFAULT_BOOTSTRAP_PHONE = "+97339009098";
export const E2E_DEFAULT_OTP_CODE = "000000";
export const E2E_STAFF_EMAIL = "field_e2e_staff@fieldrush-e2e.example";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const RUN_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

export type AdminClient = SupabaseClient<any, "public", any>;

export type E2EAccount = {
  profileId: string;
  phone: string;
  displayName: string;
  username: string;
  /** Only the synthetic staff fixture has an Auth key distinct from its actor key. */
  authUserId?: string;
  email?: string;
};

export type E2EGame = {
  id: string;
  venue: string;
  startsAt: string;
  endsAt: string;
  mainRole: "DEF" | "ATT";
  capacity: 14;
  seededConfirmedCount: number;
};

export type E2EManifest = {
  schemaVersion: typeof E2E_SCHEMA_VERSION;
  runId: string;
  createdAt: string;
  target: {
    environment: SafeDevDataTarget["environment"];
    supabaseUrl: string;
    projectRef: string | null;
  };
  login: {
    bootstrapPhone: string;
    otpCode: string;
    adminProfileId: string;
    adminPhone: string;
    adminAuthUserId?: string;
    adminEmail?: string;
  };
  accounts: {
    main: E2EAccount;
    partyTarget: E2EAccount;
    onboarding: E2EAccount;
    admin: E2EAccount;
    players: E2EAccount[];
  };
  games: {
    match: E2EGame;
    cancellation: E2EGame;
  };
  markers: {
    venuePrefix: string;
    reportDetails: string;
    supportDetails: string;
    supportContext: {
      field_e2e: true;
      e2e_run_id: string;
    };
  };
  ratingsBefore: Record<string, number>;
};

export type E2EConfig = {
  supabaseUrl: string;
  serviceRoleKey: string;
  target: SafeDevDataTarget;
  runId: string;
  manifestPath: string;
  testPassword: string;
  onboardingPhone: string;
  bootstrapPhone: string;
  otpCode: string;
};

export type ManifestConfig = {
  supabaseUrl: string;
  serviceRoleKey: string;
  target: SafeDevDataTarget;
  manifestPath: string;
  manifest: E2EManifest;
};

export function loadSetupConfig(operation: string): E2EConfig {
  const supabaseUrl = requireEnv("SUPABASE_URL");
  const target = assertAndConfirmTarget(supabaseUrl, operation);
  const runId = normalizeRunId(
    Deno.env.get("E2E_RUN_ID") ??
      Deno.env.get("GITHUB_RUN_ID") ??
      `local-${Date.now()}`,
  );
  const manifestPath = requireEnv("E2E_MANIFEST_PATH");
  const testPassword = requireEnv("E2E_TEST_PASSWORD");

  if (!/^[A-Za-z0-9_-]{32,256}$/.test(testPassword)) {
    throw new Error(
      "E2E_TEST_PASSWORD must be a generated 32–256 character run capability.",
    );
  }

  return {
    supabaseUrl,
    serviceRoleKey: requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
    target,
    runId,
    manifestPath,
    testPassword,
    onboardingPhone: normalizePhone(requireEnv("E2E_ONBOARDING_PHONE")),
    bootstrapPhone: normalizePhone(
      Deno.env.get("E2E_BOOTSTRAP_PHONE") ??
        E2E_DEFAULT_BOOTSTRAP_PHONE,
    ),
    otpCode: requireSafeOtpCode(
      Deno.env.get("E2E_DEV_OTP_CODE") ?? E2E_DEFAULT_OTP_CODE,
    ),
  };
}

export async function loadManifestConfig(
  operation: string,
): Promise<ManifestConfig> {
  const supabaseUrl = requireEnv("SUPABASE_URL");
  const target = assertAndConfirmTarget(supabaseUrl, operation);
  const manifestPath = requireEnv("E2E_MANIFEST_PATH");
  const manifest = parseManifest(
    JSON.parse(await Deno.readTextFile(manifestPath)),
  );

  if (manifest.target.supabaseUrl !== supabaseUrl) {
    throw new Error(
      `Refusing ${operation}: the manifest target does not match SUPABASE_URL.`,
    );
  }
  if (
    manifest.target.environment !== target.environment ||
    manifest.target.projectRef !== targetProjectRef(target)
  ) {
    throw new Error(
      `Refusing ${operation}: the manifest environment does not match the target.`,
    );
  }
  if (
    Deno.env.get("E2E_RUN_ID") &&
    normalizeRunId(requireEnv("E2E_RUN_ID")) !== manifest.runId
  ) {
    throw new Error(
      `Refusing ${operation}: E2E_RUN_ID does not match the manifest.`,
    );
  }

  return {
    supabaseUrl,
    serviceRoleKey: requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
    target,
    manifestPath,
    manifest,
  };
}

export function createAdminClient(
  supabaseUrl: string,
  serviceRoleKey: string,
): AdminClient {
  return createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  }) as AdminClient;
}

/** Test users still complete signup through the authenticated production RPCs. */
export async function createE2EUserClient(supabaseUrl: string, phone: string) {
  assertAndConfirmTarget(supabaseUrl, "authenticate isolated E2E account");
  const client = createClient(
    supabaseUrl,
    requireEnv("SUPABASE_PUBLISHABLE_KEY"),
    {
      auth: { autoRefreshToken: false, persistSession: false },
    },
  );
  const { error } = await client.auth.signInWithPassword({
    phone,
    password: requireEnv("E2E_TEST_PASSWORD"),
  });
  if (error) throw new Error(`authenticate E2E account: ${error.message}`);
  return client;
}

export async function createE2EStaffClient(supabaseUrl: string, email: string) {
  assertAndConfirmTarget(supabaseUrl, "authenticate isolated E2E staff");
  if (email !== E2E_STAFF_EMAIL) {
    throw new Error(
      "Only the reserved synthetic staff email can use E2E password authentication.",
    );
  }
  const client = createClient(
    supabaseUrl,
    requireEnv("SUPABASE_PUBLISHABLE_KEY"),
    {
      auth: { autoRefreshToken: false, persistSession: false },
    },
  );
  const { error } = await client.auth.signInWithPassword({
    email,
    password: requireEnv("E2E_TEST_PASSWORD"),
  });
  if (error) throw new Error(`authenticate E2E staff: ${error.message}`);
  return client;
}

export function requireIndependentE2EStaff(manifest: E2EManifest) {
  const authUserId = requireUuid(
    manifest.login?.adminAuthUserId,
    "independent E2E staff Auth id",
  );
  if (
    manifest.login.adminEmail !== E2E_STAFF_EMAIL ||
    manifest.accounts?.admin?.email !== E2E_STAFF_EMAIL ||
    manifest.accounts.admin.authUserId !== authUserId ||
    authUserId === manifest.accounts.admin.profileId ||
    !Array.isArray(manifest.accounts.players) ||
    manifest.accounts.players.some((player) =>
      player.profileId === authUserId
    ) ||
    manifest.accounts.onboarding?.profileId === authUserId
  ) {
    throw new Error(
      "The E2E manifest is missing an independent reserved staff identity.",
    );
  }
  return { authUserId, email: E2E_STAFF_EMAIL };
}

export async function listAuthUsers(
  supabaseUrl: string,
  serviceRoleKey: string,
  page: number,
  perPage: number,
): Promise<User[]> {
  const payload = await authAdminRequest(
    supabaseUrl,
    serviceRoleKey,
    `users?page=${page}&per_page=${perPage}`,
  );
  if (!isRecord(payload) || !Array.isArray(payload.users)) {
    throw new Error("Auth Admin list-users response was malformed.");
  }
  return payload.users as User[];
}

export async function getAuthUser(
  supabaseUrl: string,
  serviceRoleKey: string,
  userId: string,
): Promise<User> {
  return authUserFromPayload(
    await authAdminRequest(supabaseUrl, serviceRoleKey, `users/${userId}`),
  );
}

export async function createAuthUser(
  supabaseUrl: string,
  serviceRoleKey: string,
  attributes: Record<string, unknown>,
): Promise<User> {
  return authUserFromPayload(
    await authAdminRequest(supabaseUrl, serviceRoleKey, "users", {
      method: "POST",
      body: JSON.stringify(attributes),
    }),
  );
}

export async function updateAuthUser(
  supabaseUrl: string,
  serviceRoleKey: string,
  userId: string,
  attributes: Record<string, unknown>,
): Promise<User> {
  return authUserFromPayload(
    await authAdminRequest(supabaseUrl, serviceRoleKey, `users/${userId}`, {
      method: "PUT",
      body: JSON.stringify(attributes),
    }),
  );
}

async function authAdminRequest(
  supabaseUrl: string,
  serviceRoleKey: string,
  path: string,
  init: RequestInit = {},
): Promise<unknown> {
  const url = `${supabaseUrl.replace(/\/$/, "")}/auth/v1/admin/${path}`;
  let lastMessage = "Auth Admin request failed.";

  for (let attempt = 1; attempt <= 5; attempt += 1) {
    const response = await fetch(url, {
      ...init,
      headers: {
        apikey: serviceRoleKey,
        authorization: `Bearer ${serviceRoleKey}`,
        "content-type": "application/json",
        ...init.headers,
      },
    });
    const text = await response.text();
    let payload: unknown = null;
    if (text.length > 0) {
      try {
        payload = JSON.parse(text);
      } catch {
        payload = text;
      }
    }

    if (response.ok) return payload;

    lastMessage = authErrorMessage(payload, response.status);
    // Supabase Auth can report a transient signing-key cache miss as either a
    // 5xx or a 401. Retry only that exact failure; ordinary authorization
    // errors must still fail immediately.
    const signingKeyCacheMiss = lastMessage.includes("unrecognized JWT kid") &&
      lastMessage.includes("token is unverifiable");
    if (!signingKeyCacheMiss || attempt === 5) break;
    await new Promise((resolve) =>
      setTimeout(resolve, 1000 * 2 ** (attempt - 1))
    );
  }

  throw new Error(lastMessage);
}

function authUserFromPayload(payload: unknown): User {
  if (!isRecord(payload)) {
    throw new Error("Auth Admin user response was malformed.");
  }
  const candidate = isRecord(payload.user) ? payload.user : payload;
  if (typeof candidate.id !== "string") {
    throw new Error("Auth Admin user response did not include an id.");
  }
  return candidate as unknown as User;
}

function authErrorMessage(payload: unknown, status: number): string {
  if (isRecord(payload)) {
    for (const key of ["msg", "message", "error_description", "error"]) {
      if (typeof payload[key] === "string" && payload[key].length > 0) {
        return payload[key];
      }
    }
  }
  return `Auth Admin request failed with HTTP ${status}.`;
}

export async function writeManifest(
  path: string,
  manifest: E2EManifest,
): Promise<void> {
  await Deno.writeTextFile(path, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`FIELD_E2E_MANIFEST_PATH=${path}`);
  console.log(`FIELD_E2E_RUN_ID=${manifest.runId}`);
}

export function parseManifest(value: unknown): E2EManifest {
  if (!isRecord(value)) throw new Error("The E2E manifest must be an object.");
  if (value.schemaVersion !== E2E_SCHEMA_VERSION) {
    throw new Error(
      `Unsupported E2E manifest schema version: ${value.schemaVersion}.`,
    );
  }
  if (typeof value.runId !== "string" || !RUN_ID_PATTERN.test(value.runId)) {
    throw new Error("The E2E manifest run id is invalid.");
  }

  const manifest = value as unknown as E2EManifest;
  if (
    manifest.login?.adminAuthUserId !== undefined ||
    manifest.login?.adminEmail !== undefined ||
    manifest.accounts?.admin?.authUserId !== undefined ||
    manifest.accounts?.admin?.email !== undefined
  ) {
    requireIndependentE2EStaff(manifest);
  }
  const accounts = [
    ...(Array.isArray(manifest.accounts?.players)
      ? manifest.accounts.players
      : []),
    manifest.accounts?.onboarding,
    manifest.accounts?.admin,
  ];
  for (
    const id of [
      manifest.login?.adminProfileId,
      manifest.accounts?.main?.profileId,
      manifest.accounts?.partyTarget?.profileId,
      manifest.accounts?.onboarding?.profileId,
      manifest.accounts?.admin?.profileId,
      manifest.games?.match?.id,
      manifest.games?.cancellation?.id,
      ...accounts.map((account) => account?.profileId),
    ]
  ) {
    if (typeof id !== "string" || !UUID_PATTERN.test(id)) {
      throw new Error("The E2E manifest contains an invalid identifier.");
    }
  }
  if (
    !Array.isArray(manifest.accounts.players) ||
    manifest.accounts.players.length !== 14
  ) {
    throw new Error("The E2E manifest must contain exactly 14 test players.");
  }
  if (
    accounts.some((account) =>
      !account ||
      !account.displayName.startsWith(E2E_PROFILE_PREFIX) ||
      !account.username.startsWith("field_e2e_") ||
      !/^\+[1-9][0-9]{7,14}$/.test(account.phone)
    )
  ) {
    throw new Error("The E2E manifest contains an untagged test account.");
  }
  if (
    new Set(accounts.map((account) => account.profileId)).size !==
      accounts.length ||
    new Set(accounts.map((account) => account.phone)).size !== accounts.length
  ) {
    throw new Error("The E2E manifest contains duplicate test accounts.");
  }
  const mainRosterAccount = manifest.accounts.players.find((account) =>
    account.profileId === manifest.accounts.main.profileId
  );
  const partyRosterAccount = manifest.accounts.players.find((account) =>
    account.profileId === manifest.accounts.partyTarget.profileId
  );
  if (!mainRosterAccount || !partyRosterAccount) {
    throw new Error(
      "The E2E main and party accounts must belong to the roster.",
    );
  }
  const ratingProfileIds = Object.keys(manifest.ratingsBefore ?? {});
  if (
    ratingProfileIds.length !== manifest.accounts.players.length ||
    new Set(ratingProfileIds).size !== ratingProfileIds.length ||
    manifest.accounts.players.some((account) =>
      !Number.isFinite(manifest.ratingsBefore[account.profileId]) ||
      manifest.ratingsBefore[account.profileId] < 0
    )
  ) {
    throw new Error(
      "The E2E manifest must contain one safe rating baseline per player.",
    );
  }
  if (
    !sameAccount(mainRosterAccount, manifest.accounts.main) ||
    !sameAccount(partyRosterAccount, manifest.accounts.partyTarget) ||
    manifest.login.adminProfileId !== manifest.accounts.admin.profileId ||
    manifest.login.adminPhone !== manifest.accounts.admin.phone
  ) {
    throw new Error("The E2E manifest account aliases are inconsistent.");
  }
  const expectedVenuePrefix = `${E2E_VENUE_PREFIX} ${
    shortRunId(manifest.runId)
  }]`;
  if (
    manifest.markers?.venuePrefix !== expectedVenuePrefix ||
    manifest.markers?.reportDetails !==
      `[FIELD E2E ${manifest.runId}] Automated player report verification.` ||
    manifest.markers?.supportDetails !==
      `[FIELD E2E ${manifest.runId}] Automated support request verification.`
  ) {
    throw new Error("The E2E manifest text markers are invalid.");
  }
  if (
    manifest.games.match.id === manifest.games.cancellation.id ||
    !manifest.games.match.venue.startsWith(
      `${manifest.markers.venuePrefix} `,
    ) ||
    !manifest.games.cancellation.venue.startsWith(
      `${manifest.markers.venuePrefix} `,
    )
  ) {
    throw new Error("The E2E manifest games are not safely run-tagged.");
  }
  if (
    manifest.markers?.supportContext?.field_e2e !== true ||
    manifest.markers.supportContext.e2e_run_id !== manifest.runId
  ) {
    throw new Error("The E2E manifest markers are invalid.");
  }
  return manifest;
}

export function normalizeRunId(value: string): string {
  const normalized = value.trim().replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
  if (!RUN_ID_PATTERN.test(normalized)) {
    throw new Error("E2E_RUN_ID must contain a letter or number.");
  }
  return normalized;
}

export function shortRunId(runId: string): string {
  return runId.slice(0, 28);
}

export function selectRotatingIndex(runId: string, count: number): number {
  let hash = 2166136261;
  for (const byte of new TextEncoder().encode(runId)) {
    hash ^= byte;
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0) % count;
}

export function normalizePhone(value: string): string {
  const normalized = value.trim();
  if (!/^\+[1-9][0-9]{7,14}$/.test(normalized)) {
    throw new Error(`Invalid E2E phone number: ${normalized || "(empty)"}.`);
  }
  return normalized;
}

export async function assertNoError(
  query: PromiseLike<{ error: { message: string } | null }>,
  action: string,
): Promise<void> {
  const { error } = await query;
  if (error) throw new Error(`${action}: ${error.message}`);
}

export function unwrapRpcRow(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) {
    const first = value[0];
    return isRecord(first) ? first : {};
  }
  return isRecord(value) ? value : {};
}

export function requireUuid(value: unknown, label: string): string {
  const id = String(value ?? "");
  if (!UUID_PATTERN.test(id)) throw new Error(`Missing valid ${label}.`);
  return id;
}

export function isTerminalGameStatus(status: string): boolean {
  return status === "FINAL" || status === "CANCELLED";
}

export function logStep(message: string): void {
  console.error(`[field-e2e] ${message}`);
}

function assertAndConfirmTarget(
  supabaseUrl: string,
  operation: string,
): SafeDevDataTarget {
  const target = assertSafeDevDataTarget(supabaseUrl, operation);
  const configuredEnvironment = Deno.env.get("FIELD_ENVIRONMENT")?.trim()
    .toLowerCase();

  if (target.environment === "staging") {
    if (configuredEnvironment !== "staging") {
      throw new Error(
        `Refusing ${operation}: FIELD_ENVIRONMENT must be staging.`,
      );
    }
    if (Deno.env.get("E2E_CONFIRM_TARGET") !== "FIELD_STAGING_E2E") {
      throw new Error(
        `Refusing ${operation}: set E2E_CONFIRM_TARGET=FIELD_STAGING_E2E.`,
      );
    }
  } else if (
    configuredEnvironment &&
    !["local", "development", "dev"].includes(configuredEnvironment)
  ) {
    throw new Error(
      `Refusing ${operation}: local Supabase cannot use ` +
        `FIELD_ENVIRONMENT=${configuredEnvironment}.`,
    );
  }

  return target;
}

function requireSafeOtpCode(value: string): string {
  const normalized = value.trim();
  if (!/^[0-9]{6}$/.test(normalized)) {
    throw new Error("E2E_DEV_OTP_CODE must contain exactly six digits.");
  }
  return normalized;
}

function requireEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing required environment variable ${name}.`);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sameAccount(left: E2EAccount, right: E2EAccount): boolean {
  return left.profileId === right.profileId &&
    left.phone === right.phone &&
    left.displayName === right.displayName &&
    left.username === right.username;
}

export function targetProjectRef(target: SafeDevDataTarget): string | null {
  return target.environment === "staging" ? FIELD_STAGING_PROJECT_REF : null;
}
