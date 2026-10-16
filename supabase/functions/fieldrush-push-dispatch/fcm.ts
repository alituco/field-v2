// FCM HTTP v1 and Google's service-account JWT bearer grant. Provider URLs,
// scope and signing algorithm are fixed; credentials never determine an URL.
// https://developers.google.com/identity/protocols/oauth2/service-account
// https://firebase.google.com/docs/cloud-messaging/error-codes
const tokenUrl = "https://oauth2.googleapis.com/token";
const messagingScope = "https://www.googleapis.com/auth/firebase.messaging";
export type Fetcher = (url: string, init: RequestInit) => Promise<Response>;
export type ServiceAccount = {
  projectId: string;
  email: string;
  privateKey: string;
  keyId?: string;
};
export type PushPayload = {
  deliveryId: string;
  notificationId: string;
  token: string;
  platform: "ios" | "android";
};
export type FcmOutcome = {
  outcome: "SENT" | "RETRY" | "INVALID_TOKEN" | "FAILED";
  messageId?: string;
  errorCode?: string;
  retryAfterSeconds?: number;
};

export function parseServiceAccount(raw: string | undefined): ServiceAccount {
  try {
    const value = JSON.parse(raw ?? "");
    if (
      value.type !== "service_account" ||
      typeof value.project_id !== "string" ||
      !/^[a-z][a-z0-9-]{4,62}$/.test(value.project_id) ||
      typeof value.client_email !== "string" ||
      !/^[a-z0-9][a-z0-9._-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$/.test(
        value.client_email,
      ) ||
      !value.client_email.endsWith(
        `@${value.project_id}.iam.gserviceaccount.com`,
      ) ||
      typeof value.private_key !== "string" ||
      value.private_key.length > 16384 ||
      !value.private_key.startsWith("-----BEGIN PRIVATE KEY-----") ||
      (value.token_uri !== undefined && value.token_uri !== tokenUrl) ||
      (value.private_key_id !== undefined &&
        (typeof value.private_key_id !== "string" ||
          !/^[a-zA-Z0-9_-]{1,128}$/.test(value.private_key_id)))
    ) throw new Error();
    return {
      projectId: value.project_id,
      email: value.client_email,
      privateKey: value.private_key,
      keyId: value.private_key_id,
    };
  } catch {
    throw new Error("Push credentials are not configured.");
  }
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll(
    "/",
    "_",
  ).replaceAll("=", "");
}

export async function serviceAccountAssertion(
  account: ServiceAccount,
  nowMs: number,
): Promise<string> {
  try {
    const encoded = account.privateKey.replace(
      "-----BEGIN PRIVATE KEY-----",
      "",
    )
      .replace("-----END PRIVATE KEY-----", "").replace(/\s/g, "");
    if (!/^[a-zA-Z0-9+/]+={0,2}$/.test(encoded)) throw new Error();
    const keyBytes = Uint8Array.from(
      atob(encoded),
      (value) => value.charCodeAt(0),
    );
    const key = await crypto.subtle.importKey(
      "pkcs8",
      keyBytes,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    if ((key.algorithm as RsaHashedKeyAlgorithm).modulusLength < 2048) {
      throw new Error();
    }
    const iat = Math.floor(nowMs / 1000);
    const encode = (value: unknown) =>
      base64url(new TextEncoder().encode(JSON.stringify(value)));
    const unsigned = `${
      encode({
        alg: "RS256",
        typ: "JWT",
        ...(account.keyId ? { kid: account.keyId } : {}),
      })
    }.${
      encode({
        iss: account.email,
        scope: messagingScope,
        aud: tokenUrl,
        iat,
        exp: iat + 3600,
      })
    }`;
    const signature = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(unsigned),
    );
    return `${unsigned}.${base64url(new Uint8Array(signature))}`;
  } catch {
    throw new Error("Push credentials are not configured.");
  }
}

export async function fetchAccessToken(
  account: ServiceAccount,
  fetcher: Fetcher,
  nowMs: number,
): Promise<string> {
  try {
    const assertion = await serviceAccountAssertion(account, nowMs);
    const response = await fetcher(tokenUrl, {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(15000),
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }).toString(),
    });
    if (!response.ok) throw new Error();
    const value = await response.json();
    if (
      typeof value.access_token !== "string" ||
      value.access_token.length < 10 ||
      value.access_token.length > 4096 || /\s/.test(value.access_token) ||
      value.token_type?.toLowerCase() !== "bearer" ||
      !Number.isInteger(value.expires_in) || value.expires_in < 60
    ) throw new Error();
    return value.access_token;
  } catch {
    throw new Error("Push provider authentication is unavailable.");
  }
}

export function retryAfterSeconds(
  value: string | null,
  nowMs: number,
): number | undefined {
  if (!value) return undefined;
  const seconds = /^\d+$/.test(value.trim())
    ? Number(value.trim())
    : (Date.parse(value) - nowMs) / 1000;
  return Number.isFinite(seconds) && seconds >= 0
    ? Math.min(86400, Math.ceil(seconds))
    : undefined;
}

export function classifyFcmFailure(
  status: number,
  body: unknown,
  retryAfter?: number,
): FcmOutcome {
  const error = (body as { error?: { details?: unknown[] } } | null)?.error;
  const detail = Array.isArray(error?.details)
    ? error.details.find((entry) =>
      entry && typeof entry === "object" &&
      (entry as Record<string, unknown>)["@type"] ===
        "type.googleapis.com/google.firebase.fcm.v1.FcmError"
    ) as Record<string, unknown> | undefined
    : undefined;
  const code = detail?.errorCode;
  if (status === 404 && code === "UNREGISTERED") {
    return { outcome: "INVALID_TOKEN", errorCode: "UNREGISTERED" };
  }
  if (status === 429 || code === "QUOTA_EXCEEDED") {
    return {
      outcome: "RETRY",
      errorCode: "QUOTA_EXCEEDED",
      retryAfterSeconds: Math.max(60, retryAfter ?? 60),
    };
  }
  if (status >= 500 || status === 408) {
    return {
      outcome: "RETRY",
      errorCode: "PROVIDER_UNAVAILABLE",
      retryAfterSeconds: retryAfter,
    };
  }
  if (status === 401 || code === "THIRD_PARTY_AUTH_ERROR") {
    return {
      outcome: "RETRY",
      errorCode: "PROVIDER_AUTH_ERROR",
      retryAfterSeconds: Math.max(60, retryAfter ?? 60),
    };
  }
  if (code === "SENDER_ID_MISMATCH") {
    return { outcome: "FAILED", errorCode: "SENDER_ID_MISMATCH" };
  }
  // INVALID_ARGUMENT can describe a bad payload, not an invalid device token.
  // Never disable a token on a generic 400, 403 or unrecognized provider error.
  if (status === 400) {
    return { outcome: "FAILED", errorCode: "INVALID_ARGUMENT" };
  }
  if (status === 403) {
    return { outcome: "FAILED", errorCode: "PROVIDER_PERMISSION_DENIED" };
  }
  return {
    outcome: "RETRY",
    errorCode: "UNEXPECTED_PROVIDER_RESPONSE",
    retryAfterSeconds: retryAfter,
  };
}

export async function sendFcm(
  account: ServiceAccount,
  accessToken: string,
  payload: PushPayload,
  fetcher: Fetcher,
  nowMs: number,
): Promise<FcmOutcome> {
  try {
    const response = await fetcher(
      `https://fcm.googleapis.com/v1/projects/${account.projectId}/messages:send`,
      {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.timeout(10000),
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          message: {
            token: payload.token,
            // Deliberately no names, game/party details, or caller-supplied preview.
            notification: {
              title: "Fieldrush",
              body: "You have a new update. Open Fieldrush to view it.",
            },
            data: { notification_id: payload.notificationId },
            android: {
              priority: "HIGH",
              ttl: "3600s",
              collapse_key: "fieldrush_updates",
              notification: { tag: payload.notificationId },
            },
            apns: {
              headers: {
                "apns-push-type": "alert",
                "apns-priority": "10",
                "apns-collapse-id": payload.notificationId,
                "apns-expiration": String(Math.floor(nowMs / 1000) + 3600),
              },
              payload: { aps: { sound: "default" } },
            },
          },
        }),
      },
    );
    let value: unknown = null;
    try {
      value = await response.json();
    } catch { /* Classify non-JSON 429/503 by HTTP status and Retry-After. */ }
    if (!response.ok) {
      return classifyFcmFailure(
        response.status,
        value,
        retryAfterSeconds(response.headers.get("retry-after"), nowMs),
      );
    }
    const name = (value as { name?: unknown } | null)?.name;
    const prefix = `projects/${account.projectId}/messages/`;
    if (
      typeof name !== "string" || name.length > 255 ||
      !name.startsWith(prefix) ||
      !/^[a-zA-Z0-9%:_-]+$/.test(name.slice(prefix.length))
    ) return { outcome: "RETRY", errorCode: "INVALID_PROVIDER_RESPONSE" };
    return { outcome: "SENT", messageId: name };
  } catch {
    return { outcome: "RETRY", errorCode: "PROVIDER_NETWORK_ERROR" };
  }
}
