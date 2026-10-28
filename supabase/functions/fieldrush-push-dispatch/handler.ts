import {
  isExactFieldStagingSupabaseUrl,
  isLocalSupabaseUrl,
} from "../_shared/staging_guard.ts";
import {
  type FcmOutcome,
  fetchAccessToken,
  type Fetcher,
  parseServiceAccount,
  type PushPayload,
  sendFcm,
  type ServiceAccount,
} from "./fcm.ts";

type RpcResult = { data: unknown; error: unknown };
export type PushDb = {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<RpcResult>;
};
type Dependencies = {
  env(name: string): string | undefined;
  createDb(url: string, key: string): PushDb;
  fetcher?: Fetcher;
  now?: () => number;
  rpcTimeoutMs?: number;
};
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

function isExactFieldProductionSupabaseUrl(
  value: string | undefined,
): value is string {
  if (!value) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" &&
      url.hostname === "zjsjuuhborxrlmdcpvlj.supabase.co" &&
      url.port === "" && url.username === "" && url.password === "" &&
      url.pathname === "/" && url.search === "" && url.hash === "";
  } catch {
    return false;
  }
}
const approvedPreviewTypes = new Set([
  "PLAYER_CHECKOUT_CONFIRMED",
  "PLAYER_CHECKOUT_REFUND_PENDING",
  "PLAYER_CHECKOUT_REFUNDED",
  "PLAYER_CHECKOUT_AUTH_RELEASED",
  "SOLO_TEAM_READY",
  "SOLO_TEAM_CHANGED",
  "SOLO_GAME_CHANGED",
  "SOLO_GAME_CANCELLED",
  "SOLO_BOOKING_REMOVED",
  "SOLO_MATCH_REVIEW",
  "SOLO_MATCH_CORRECTED",
  "GAME_REMINDER",
  "OPEN_QUEUE_PARTY_INVITE",
  "RELIABILITY_OUTCOME",
  "RELIABILITY_SANCTION",
  "RELIABILITY_APPEAL_DECIDED",
  "PLAYER_RESTRICTION_LIFTED",
  "PLAYER_ACCOUNT_RESTRICTED",
]);

function previewText(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.trim().length > 0 &&
    value.length <= maximum && !/[\u0000-\u001f\u007f]/.test(value);
}
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });

export async function matchesWorkerSecret(
  supplied: string,
  expected: string,
): Promise<boolean> {
  if (supplied.length > 512 || !expected) return false;
  const encoder = new TextEncoder();
  const [left, right] = await Promise.all(
    [supplied, expected].map((value) =>
      crypto.subtle.digest("SHA-256", encoder.encode(value))
    ),
  );
  const a = new Uint8Array(left);
  const b = new Uint8Array(right);
  let different = 0;
  for (let index = 0; index < a.length; index++) {
    different |= a[index] ^ b[index];
  }
  return different === 0;
}

function parsePayload(
  value: unknown,
  deliveryId: string,
  projectId: string,
): PushPayload {
  const data = value as Record<string, unknown> | null;
  if (
    !data || data.delivery_id !== deliveryId ||
    typeof data.notification_id !== "string" ||
    !uuid.test(data.notification_id) ||
    data.firebase_project_id !== projectId ||
    !["ios", "android"].includes(String(data.platform)) ||
    typeof data.token !== "string" || data.token.length < 20 ||
    data.token.length > 4096 || /\s/.test(data.token)
  ) throw new Error();
  let preview: PushPayload["preview"];
  if (data.preview_version !== undefined) {
    if (
      data.preview_version !== 1 ||
      !approvedPreviewTypes.has(String(data.notification_type)) ||
      !previewText(data.title, 120) || !previewText(data.body, 500)
    ) throw new Error();
    preview = { title: data.title, body: data.body };
  }
  const expiresAt = data.expires_at === undefined
    ? undefined
    : typeof data.expires_at === "string"
    ? Date.parse(data.expires_at)
    : NaN;
  if (expiresAt !== undefined && !Number.isFinite(expiresAt)) throw new Error();
  return {
    deliveryId,
    notificationId: data.notification_id,
    token: data.token,
    platform: data.platform as "ios" | "android",
    preview,
    expiresAt,
  };
}

async function boundedRpc(
  db: PushDb,
  name: string,
  args: Record<string, unknown>,
  timeoutMs: number,
): Promise<unknown> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const result = await Promise.race([
      Promise.resolve(db.rpc(name, args)),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error()), timeoutMs);
      }),
    ]);
    if (result.error) throw new Error();
    return result.data;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

export function createPushDispatchHandler(deps: Dependencies) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return json({ error: "Method not allowed." }, 405);
    }
    const url = deps.env("SUPABASE_URL");
    const environment = deps.env("FIELD_ENVIRONMENT");
    const allowedEnvironment =
      environment === "staging" && isExactFieldStagingSupabaseUrl(url) ||
      environment === "production" && isExactFieldProductionSupabaseUrl(url) ||
      environment === "local" && isLocalSupabaseUrl(url);
    if (!allowedEnvironment || deps.env("PUSH_DELIVERY_ENABLED") !== "true") {
      return json({ error: "Push delivery is not enabled." }, 503);
    }
    const secret = deps.env("PUSH_WORKER_SECRET");
    if (!secret || !/^[!-~]{32,512}$/.test(secret)) {
      return json({ error: "Push worker is not configured." }, 503);
    }
    const bearer =
      request.headers.get("authorization")?.match(/^Bearer ([^\s]{1,512})$/i)
        ?.[1] ?? "";
    if (!await matchesWorkerSecret(bearer, secret)) {
      return json({ error: "Worker authorization required." }, 401);
    }
    try {
      const body = await request.text();
      if (body.length > 1024 || body.trim() && (body.trim() !== "{}")) {
        return json(
          { error: "No push payload may be supplied by the caller." },
          400,
        );
      }
    } catch {
      return json({ error: "Invalid request." }, 400);
    }
    let account: ServiceAccount;
    let accessToken: string;
    const fetcher = deps.fetcher ?? fetch;
    const now = deps.now ?? Date.now;
    const key = deps.env("FIELD_SUPABASE_SECRET_KEY") ??
      deps.env("SUPABASE_SERVICE_ROLE_KEY");
    if (!key || key.length < 20) {
      return json({ error: "Push worker is not configured." }, 503);
    }
    try {
      account = parseServiceAccount(deps.env("FIREBASE_SERVICE_ACCOUNT_JSON"));
      const expectedProject = deps.env("PUSH_FIREBASE_PROJECT_ID");
      if (
        (environment === "production" && !expectedProject) ||
        (expectedProject !== undefined && expectedProject !== account.projectId)
      ) throw new Error();
      // Validate credentials and get OAuth before consuming any database lease.
      accessToken = await fetchAccessToken(account, fetcher, now());
    } catch {
      return json(
        { error: "Push provider authentication is unavailable." },
        503,
      );
    }
    const claimId = crypto.randomUUID();
    const timeout = deps.rpcTimeoutMs ?? 5000;
    let db: PushDb;
    let deliveries: { id: string }[];
    try {
      db = deps.createDb(url!, key);
      const claimed = await boundedRpc(db, "claim_push_deliveries", {
        batch_size: 50,
        claim_id_to_use: claimId,
      }, timeout);
      if (
        !Array.isArray(claimed) || claimed.length > 50 || claimed.some((item) =>
          !item || typeof item.id !== "string" || !uuid.test(item.id)
        ) ||
        new Set(claimed.map((item) =>
            item.id
          )).size !== claimed.length
      ) throw new Error();
      deliveries = claimed;
    } catch {
      return json({ error: "Push delivery queue is unavailable." }, 503);
    }
    const counts = {
      claimed: deliveries.length,
      providerAccepted: 0,
      retry: 0,
      invalidToken: 0,
      failed: 0,
      skipped: 0,
      completionUnknown: 0,
    };
    let next = 0;
    async function dispatchOne(id: string) {
      let result: FcmOutcome;
      let dispatchedToken: string | undefined;
      try {
        const value = await boundedRpc(db, "get_push_delivery_payload", {
          delivery_id_to_use: id,
          claim_id_to_use: claimId,
        }, timeout);
        if (value === null) {
          counts.skipped++;
          return;
        }
        let payload: PushPayload;
        try {
          payload = parsePayload(value, id, account.projectId);
        } catch {
          result = {
            outcome: "FAILED",
            errorCode: "INVALID_DELIVERY_CONFIGURATION",
          };
          return await finish(id, result);
        }
        dispatchedToken = payload.token;
        result = await sendFcm(account, accessToken, payload, fetcher, now());
      } catch {
        result = { outcome: "RETRY", errorCode: "PAYLOAD_UNAVAILABLE" };
      }
      await finish(id, result, dispatchedToken);
    }
    async function finish(
      id: string,
      result: FcmOutcome,
      dispatchedToken?: string,
    ) {
      try {
        await boundedRpc(db, "complete_push_delivery", {
          delivery_id_to_use: id,
          claim_id_to_use: claimId,
          outcome_to_use: result.outcome,
          provider_message_id_to_use: result.messageId ?? null,
          error_code_to_use: result.errorCode ?? null,
          retry_after_seconds_to_use: result.retryAfterSeconds ?? null,
          // Token refresh can race an older provider send. Retire only the
          // exact rejected token, never a newer token on the same binding.
          registration_token_to_invalidate: result.outcome === "INVALID_TOKEN"
            ? dispatchedToken ?? null
            : null,
        }, timeout);
        if (result.outcome === "SENT") counts.providerAccepted++;
        else if (result.outcome === "RETRY") counts.retry++;
        else if (result.outcome === "INVALID_TOKEN") counts.invalidToken++;
        else counts.failed++;
      } catch {
        // Sending and acknowledging are not atomic. Never resend immediately;
        // the lease must expire. FCM/APNs collapse identifiers reduce duplicates
        // but cannot promise exactly-once delivery after a lost acknowledgement.
        counts.completionUnknown++;
      }
    }
    // Twenty workers process fifty devices in at most three waves of 5s payload
    // + 10s provider + 5s completion, inside the two-minute lease and scheduled
    // HTTP timeout. Each source is rechecked immediately before its send.
    await Promise.all(
      Array.from({ length: Math.min(20, deliveries.length) }, async () => {
        while (next < deliveries.length) {
          await dispatchOne(deliveries[next++].id);
        }
      }),
    );
    return json(counts);
  };
}
