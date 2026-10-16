import { readFile } from "node:fs/promises";

import type { BrowserContext } from "@playwright/test";

type JsonRecord = Record<string, unknown>;

const FIELD_STAGING_SUPABASE_URL =
  "https://nfdkdhdevpstfspazbfn.supabase.co";

export type StagingManifest = {
  schemaVersion: number;
  runId: string;
  login: {
    bootstrapPhone: string;
    otpCode: string;
    adminProfileId: string;
  };
  accounts: {
    main: {
      profileId: string;
      displayName: string;
    };
  };
  games: {
    match: {
      id: string;
      venue: string;
      capacity: number;
    };
  };
  markers: {
    reportDetails: string;
    supportDetails: string;
  };
};

export type StagingSession = {
  accessToken: string;
};

export async function loadStagingManifest(): Promise<StagingManifest> {
  const path = requiredEnv("E2E_MANIFEST_PATH");
  const parsed = JSON.parse(await readFile(path, "utf8")) as unknown;
  if (!isRecord(parsed)) {
    throw new Error("The staging E2E manifest is not an object.");
  }

  const manifest = parsed as unknown as StagingManifest;
  if (
    manifest.schemaVersion !== 2 ||
    !manifest.runId ||
    !manifest.login?.bootstrapPhone ||
    !manifest.login?.otpCode ||
    !isUuid(manifest.login?.adminProfileId) ||
    !isUuid(manifest.accounts?.main?.profileId) ||
    !manifest.accounts?.main?.displayName ||
    !isUuid(manifest.games?.match?.id) ||
    !manifest.games?.match?.venue ||
    manifest.games?.match?.capacity !== 14 ||
    !manifest.markers?.reportDetails ||
    !manifest.markers?.supportDetails
  ) {
    throw new Error("The staging E2E manifest is incomplete or invalid.");
  }
  return manifest;
}

export async function installAdminSession(
  context: BrowserContext,
  manifest: StagingManifest,
): Promise<StagingSession> {
  const supabaseUrl = normalizedSupabaseUrl(requiredEnv("SUPABASE_URL"));
  const publishableKey = requiredEnv("SUPABASE_PUBLISHABLE_KEY");

  const bootstrap = await postJson<{
    access_token?: unknown;
  }>(
    `${supabaseUrl}/functions/v1/dev-phone-login`,
    {
      phone: manifest.login.bootstrapPhone,
      token: manifest.login.otpCode,
    },
    {
      apikey: publishableKey,
      authorization: `Bearer ${publishableKey}`,
      "x-fieldrush-e2e-secret": requiredEnv("E2E_TEST_PASSWORD"),
    },
    "create the staging bootstrap session",
  );
  const bootstrapAccessToken = requiredString(
    bootstrap.access_token,
    "bootstrap access token",
  );

  const switched = await postJson<{
    access_token?: unknown;
    refresh_token?: unknown;
    expires_at?: unknown;
  }>(
    `${supabaseUrl}/functions/v1/dev-switch-user`,
    { profile_id: manifest.login.adminProfileId },
    {
      apikey: publishableKey,
      authorization: `Bearer ${bootstrapAccessToken}`,
      "x-fieldrush-e2e-secret": requiredEnv("E2E_TEST_PASSWORD"),
    },
    "switch to the isolated staging admin",
  );
  const accessToken = requiredString(
    switched.access_token,
    "admin access token",
  );
  const refreshToken = requiredString(
    switched.refresh_token,
    "admin refresh token",
  );

  const userResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: {
      apikey: publishableKey,
      authorization: `Bearer ${accessToken}`,
    },
  });
  if (!userResponse.ok) {
    throw new Error(
      `Could not load the switched staging user (${userResponse.status}).`,
    );
  }
  const user = await userResponse.json() as unknown;
  if (!isRecord(user) || !isUuid(user.id)) {
    throw new Error("The switched staging session returned an invalid user.");
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  const expiresAt = typeof switched.expires_at === "number"
    ? switched.expires_at
    : nowSeconds + 3600;
  const persistedSession = {
    access_token: accessToken,
    refresh_token: refreshToken,
    token_type: "bearer",
    expires_at: expiresAt,
    expires_in: Math.max(60, expiresAt - nowSeconds),
    user,
  };
  const storageKey = `sb-${projectRef(supabaseUrl)}-auth-token`;

  await context.addInitScript(
    ({ key, session }) => {
      window.localStorage.setItem(key, JSON.stringify(session));
    },
    { key: storageKey, session: persistedSession },
  );

  return { accessToken };
}

async function postJson<T extends JsonRecord>(
  url: string,
  body: JsonRecord,
  headers: Record<string, string>,
  operation: string,
): Promise<T> {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      ...headers,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const payload = await response.json().catch(() => null) as unknown;
  if (!response.ok) {
    const detail = isRecord(payload) && typeof payload.error === "string"
      ? ` ${payload.error}`
      : "";
    throw new Error(
      `Could not ${operation} (${response.status}).${detail}`,
    );
  }
  if (!isRecord(payload)) {
    throw new Error(`Could not ${operation}: response was not JSON.`);
  }
  return payload as T;
}

function normalizedSupabaseUrl(value: string): string {
  const url = new URL(value);
  if (url.origin !== FIELD_STAGING_SUPABASE_URL || url.href !== `${url.origin}/`) {
    throw new Error(
      "Refusing referee E2E: SUPABASE_URL is not the exact Field Staging origin.",
    );
  }
  return url.origin;
}

function projectRef(supabaseUrl: string): string {
  const ref = new URL(supabaseUrl).hostname.split(".")[0];
  if (!/^[a-z0-9]{20}$/.test(ref)) {
    throw new Error("Could not derive the Supabase project ref.");
  }
  return ref;
}

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required for staging E2E.`);
  return value;
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`The staging login response omitted the ${label}.`);
  }
  return value;
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value);
}
