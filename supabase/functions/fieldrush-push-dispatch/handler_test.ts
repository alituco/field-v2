import {
  classifyFcmFailure,
  parseServiceAccount,
  retryAfterSeconds,
  serviceAccountAssertion,
} from "./fcm.ts";
import {
  createPushDispatchHandler,
  matchesWorkerSecret,
  type PushDb,
} from "./handler.ts";

function assert(ok: unknown, message = "Push assertion failed."): asserts ok {
  if (!ok) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    "Push values did not match.",
  );
}
const now = Date.parse("2026-10-15T12:00:00Z");
const project = "fieldrush-push-fixture";
const secret = crypto.randomUUID() + crypto.randomUUID();
const serviceKey = crypto.randomUUID() + crypto.randomUUID();
const accessToken = crypto.randomUUID();
const token = crypto.randomUUID() + crypto.randomUUID();
const notificationId = crypto.randomUUID();
const deliveryId = crypto.randomUUID();
const pair = await crypto.subtle.generateKey(
  {
    name: "RSASSA-PKCS1-v1_5",
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
    hash: "SHA-256",
  },
  true,
  ["sign", "verify"],
);
const der = new Uint8Array(
  await crypto.subtle.exportKey("pkcs8", pair.privateKey),
);
const pem = `-----BEGIN PRIVATE KEY-----\n${
  btoa(String.fromCharCode(...der))
}\n-----END PRIVATE KEY-----\n`;
const serviceAccount = {
  type: "service_account",
  project_id: project,
  client_email: `push-fixture@${project}.iam.gserviceaccount.com`,
  private_key: pem,
  token_uri: "https://oauth2.googleapis.com/token",
};

function fixture(options: {
  env?: Record<string, string | undefined>;
  claimed?: unknown;
  payload?: unknown;
  oauthFailure?: boolean;
  oauthBody?: unknown;
  sendResponse?: () => Response | Promise<Response>;
  completeFails?: boolean;
  payloadFails?: boolean;
  payloadTimeout?: boolean;
  claimFails?: boolean;
} = {}) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const sends: { url: string; init: RequestInit }[] = [];
  const env: Record<string, string | undefined> = {
    SUPABASE_URL: "https://nfdkdhdevpstfspazbfn.supabase.co",
    FIELD_ENVIRONMENT: "staging",
    PUSH_DELIVERY_ENABLED: "true",
    PUSH_WORKER_SECRET: secret,
    SUPABASE_SERVICE_ROLE_KEY: serviceKey,
    FIREBASE_SERVICE_ACCOUNT_JSON: JSON.stringify(serviceAccount),
    ...options.env,
  };
  let dbCreated = 0;
  const db: PushDb = {
    rpc: (name, args) => {
      calls.push({ name, args });
      if (name === "claim_push_deliveries") {
        return Promise.resolve({
          data: options.claimed === undefined
            ? [{ id: deliveryId }]
            : options.claimed,
          error: options.claimFails ? {} : null,
        });
      }
      if (
        name === "get_push_delivery_payload" && options.payloadTimeout
      ) return new Promise(() => {});
      if (name === "get_push_delivery_payload") {
        return Promise.resolve({
          data: options.payload === undefined
            ? {
              delivery_id: args.delivery_id_to_use,
              notification_id: notificationId,
              token,
              firebase_project_id: project,
              platform: "ios",
              title: "Do not use private provider title",
              body: "Do not use private provider body",
            }
            : options.payload,
          error: options.payloadFails ? {} : null,
        });
      }
      if (name === "complete_push_delivery") {
        return Promise.resolve({
          data: null,
          error: options.completeFails ? {} : null,
        });
      }
      throw new Error("Unexpected RPC.");
    },
  };
  const handler = createPushDispatchHandler({
    env: (name) => env[name],
    now: () => now,
    rpcTimeoutMs: options.payloadTimeout ? 1 : undefined,
    createDb: (url, key) => {
      equal(url, env.SUPABASE_URL);
      equal(key, serviceKey);
      dbCreated++;
      return db;
    },
    fetcher: (url, init) => {
      if (url === "https://oauth2.googleapis.com/token") {
        if (options.oauthFailure) {
          return Promise.resolve(
            new Response("private OAuth diagnostic", { status: 401 }),
          );
        }
        return Promise.resolve(
          Response.json(
            options.oauthBody ??
              {
                access_token: accessToken,
                token_type: "Bearer",
                expires_in: 3600,
              },
          ),
        );
      }
      assert(
        url ===
          `https://fcm.googleapis.com/v1/projects/${project}/messages:send`,
        "Only the fixed FCM URL is allowed.",
      );
      sends.push({ url, init });
      return Promise.resolve(
        options.sendResponse?.() ??
          Response.json({
            name: `projects/${project}/messages/fixture-message`,
          }),
      );
    },
  });
  return {
    handler,
    calls,
    sends,
    dbCreated: () => dbCreated,
    run: (authorization = `Bearer ${secret}`, body = "{}", method = "POST") =>
      handler(
        new Request("http://localhost/worker", {
          method,
          headers: { Authorization: authorization },
          ...(method === "POST" ? { body } : {}),
        }),
      ),
  };
}

Deno.test("service-account assertions use a verifiable RS256 signature and the exact limited FCM scope", async () => {
  const assertion = await serviceAccountAssertion(
    parseServiceAccount(JSON.stringify(serviceAccount)),
    now,
  );
  const [header, body, signature] = assertion.split(".");
  const decode = (value: string) =>
    Uint8Array.from(
      atob(value.replaceAll("-", "+").replaceAll("_", "/")),
      (c) => c.charCodeAt(0),
    );
  equal(JSON.parse(new TextDecoder().decode(decode(header))), {
    alg: "RS256",
    typ: "JWT",
  });
  const claims = JSON.parse(new TextDecoder().decode(decode(body)));
  equal(claims.iss, serviceAccount.client_email);
  equal(claims.scope, "https://www.googleapis.com/auth/firebase.messaging");
  equal(claims.aud, "https://oauth2.googleapis.com/token");
  equal(claims.exp - claims.iat, 3600);
  assert(
    await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      pair.publicKey,
      decode(signature),
      new TextEncoder().encode(`${header}.${body}`),
    ),
  );
});

Deno.test("disabled, production and lookalike environments never contact a provider or claim work", async () => {
  for (
    const env of [{ PUSH_DELIVERY_ENABLED: "false" }, {
      FIELD_ENVIRONMENT: "production",
      SUPABASE_URL: "https://zjsjuuhborxrlmdcpvlj.supabase.co",
    }, {
      SUPABASE_URL: "https://nfdkdhdevpstfspazbfn.supabase.co.evil.example",
    }, { FIELD_ENVIRONMENT: "local" }]
  ) {
    const test = fixture({ env });
    equal((await test.run()).status, 503);
    equal(test.calls.length, 0);
    equal(test.sends.length, 0);
    equal(test.dbCreated(), 0);
  }
});

Deno.test("worker authorization requires a matching secret without accepting a Supabase bearer instead", async () => {
  assert(await matchesWorkerSecret(secret, secret));
  assert(!await matchesWorkerSecret(secret.slice(1), secret));
  for (
    const authorization of [
      "",
      `Bearer ${serviceKey}`,
      `Bearer ${secret} extra`,
    ]
  ) {
    const test = fixture();
    equal((await test.run(authorization)).status, 401);
    equal(test.calls.length, 0);
    equal(test.sends.length, 0);
  }
});

Deno.test("malformed credentials, redirected OAuth endpoints and failed OAuth do not consume leases", async () => {
  for (
    const options of [
      { env: { FIREBASE_SERVICE_ACCOUNT_JSON: "not-json" } },
      {
        env: {
          FIREBASE_SERVICE_ACCOUNT_JSON: JSON.stringify({
            ...serviceAccount,
            token_uri: "https://evil.example/token",
          }),
        },
      },
      {
        env: {
          FIREBASE_SERVICE_ACCOUNT_JSON: JSON.stringify({
            ...serviceAccount,
            private_key: "not-a-key",
          }),
        },
      },
      { oauthFailure: true },
      {
        oauthBody: {
          access_token: accessToken,
          token_type: "Bearer",
          expires_in: 0,
        },
      },
    ]
  ) {
    const test = fixture(options);
    const result = await test.run();
    equal(result.status, 503);
    equal(test.calls.length, 0);
    equal(test.dbCreated(), 0);
    const text = await result.text();
    assert(
      !text.includes(pem) && !text.includes(accessToken) &&
        !text.includes("private OAuth diagnostic"),
    );
  }
});

Deno.test("callers cannot inject recipients, tokens, project IDs or notification text", async () => {
  const test = fixture();
  equal(
    (await test.run(
      `Bearer ${secret}`,
      JSON.stringify({ token, body: "forged" }),
    )).status,
    400,
  );
  equal(test.calls.length, 0);
  equal(test.sends.length, 0);
  equal((await test.run(`Bearer ${secret}`, "", "GET")).status, 405);
});

Deno.test("dispatch claims fifty at most, rereads eligibility, preserves generic legacy content and acknowledges the same lease", async () => {
  const test = fixture();
  const result = await test.run();
  equal(result.status, 200);
  equal(test.calls.map((call) => call.name), [
    "claim_push_deliveries",
    "get_push_delivery_payload",
    "complete_push_delivery",
  ]);
  equal(test.calls[0].args.batch_size, 50);
  equal(test.calls[0].args.claim_id_to_use, test.calls[1].args.claim_id_to_use);
  equal(test.calls[1].args.claim_id_to_use, test.calls[2].args.claim_id_to_use);
  equal(test.calls[2].args.outcome_to_use, "SENT");
  const message = JSON.parse(test.sends[0].init.body as string).message;
  equal(message.notification, {
    title: "Fieldrush",
    body: "You have a new update. Open Fieldrush to view it.",
  });
  equal(message.data, { notification_id: notificationId });
  equal(message.android.collapse_key, undefined);
  equal(message.android.notification.tag, notificationId);
  equal(message.apns.headers["apns-collapse-id"], notificationId);
  equal(test.sends[0].init.redirect, "error");
  const text = await result.text();
  for (
    const sensitive of [
      token,
      secret,
      serviceKey,
      pem,
      accessToken,
      notificationId,
    ]
  ) assert(!text.includes(sensitive), "Responses must contain counters only.");
});

function approvedPayload(overrides: Record<string, unknown> = {}) {
  return {
    delivery_id: deliveryId,
    notification_id: notificationId,
    token,
    firebase_project_id: project,
    platform: "ios",
    preview_version: 1,
    notification_type: "GAME_REMINDER",
    title: "Check-in deadline approaching",
    body: "Check in with the referee before 5:20 PM.",
    expires_at: new Date(now + 120000).toISOString(),
    ...overrides,
  };
}

Deno.test("approved canonical preview reaches the phone and expires at the check-in deadline", async () => {
  const test = fixture({ payload: approvedPayload() });
  const response = await test.run();
  equal((await response.json()).providerAccepted, 1);
  const message = JSON.parse(test.sends[0].init.body as string).message;
  equal(message.notification, {
    title: "Check-in deadline approaching",
    body: "Check in with the referee before 5:20 PM.",
  });
  equal(message.data, { notification_id: notificationId });
  equal(message.android.ttl, "120s");
  equal(message.apns.headers["apns-expiration"], String(now / 1000 + 120));
});

Deno.test("expired notices never reach FCM and long-lived notices have at most one hour provider storage", async () => {
  for (const expiresAt of [now - 1, now, now + 500]) {
    const test = fixture({
      payload: approvedPayload({
        expires_at: new Date(expiresAt).toISOString(),
      }),
    });
    await test.run();
    equal(test.sends.length, 0);
    equal(test.calls.at(-1)?.args.error_code_to_use, "DELIVERY_EXPIRED");
  }
  const test = fixture({
    payload: approvedPayload({
      expires_at: new Date(now + 86400000).toISOString(),
    }),
  });
  await test.run();
  const message = JSON.parse(test.sends[0].init.body as string).message;
  equal(message.android.ttl, "3600s");
  equal(message.apns.headers["apns-expiration"], String(now / 1000 + 3600));
});

Deno.test("unapproved types, malformed preview text and invalid deadlines fail closed", async () => {
  for (
    const override of [
      { notification_type: "NEWS_AND_OFFERS" },
      { notification_type: "FORGED_PLAYER_EVENT" },
      { preview_version: 2 },
      { title: "" },
      { title: "a".repeat(121) },
      { body: "a".repeat(501) },
      { body: "private\nadmin note" },
      { expires_at: "tomorrow" },
    ]
  ) {
    const test = fixture({ payload: approvedPayload(override) });
    await test.run();
    equal(test.sends.length, 0);
    equal(
      test.calls.at(-1)?.args.error_code_to_use,
      "INVALID_DELIVERY_CONFIGURATION",
    );
  }
});

Deno.test("rebound, revoked, dismissed or disabled recipients return null and are never sent", async () => {
  const test = fixture({ payload: null });
  const result = await test.run();
  equal((await result.json()).skipped, 1);
  equal(test.sends.length, 0);
  equal(test.calls.length, 2);
});

Deno.test("a wrong Firebase project or malformed payload fails closed without exposing or sending its token", async () => {
  for (
    const payload of [{
      delivery_id: deliveryId,
      notification_id: notificationId,
      token,
      platform: "ios",
      firebase_project_id: "wrong-project",
    }, { token }]
  ) {
    const test = fixture({ payload });
    await test.run();
    equal(test.sends.length, 0);
    equal(test.calls.at(-1)?.args.outcome_to_use, "FAILED");
    equal(
      test.calls.at(-1)?.args.error_code_to_use,
      "INVALID_DELIVERY_CONFIGURATION",
    );
  }
});

Deno.test("only explicit FCM UNREGISTERED errors deactivate a device token", () => {
  const detail = (errorCode: string) => ({
    error: {
      details: [{
        "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
        errorCode,
      }],
    },
  });
  equal(
    classifyFcmFailure(404, detail("UNREGISTERED")).outcome,
    "INVALID_TOKEN",
  );
  for (
    const [status, body] of [[404, {}], [400, detail("INVALID_ARGUMENT")], [
      403,
      detail("SENDER_ID_MISMATCH"),
    ], [401, detail("THIRD_PARTY_AUTH_ERROR")]] as const
  ) {
    assert(classifyFcmFailure(status, body).outcome !== "INVALID_TOKEN");
  }
});

Deno.test("invalid-token acknowledgement identifies only the exact token dispatched", async () => {
  const test = fixture({
    sendResponse: () =>
      Response.json({
        error: {
          details: [{
            "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
            errorCode: "UNREGISTERED",
          }],
        },
      }, { status: 404 }),
  });
  await test.run();
  equal(test.calls.at(-1)?.args.outcome_to_use, "INVALID_TOKEN");
  equal(test.calls.at(-1)?.args.registration_token_to_invalidate, token);
  const successful = fixture();
  await successful.run();
  equal(successful.calls.at(-1)?.args.registration_token_to_invalidate, null);
});

Deno.test("provider quotas and Retry-After produce sanitized retries, never raw Google messages", async () => {
  const test = fixture({
    sendResponse: () =>
      Response.json({ error: { message: "private token diagnostic" } }, {
        status: 429,
        headers: { "Retry-After": "120" },
      }),
  });
  await test.run();
  equal(test.calls.at(-1)?.args.outcome_to_use, "RETRY");
  equal(test.calls.at(-1)?.args.retry_after_seconds_to_use, 120);
  equal(test.calls.at(-1)?.args.error_code_to_use, "QUOTA_EXCEEDED");
  equal(classifyFcmFailure(429, {}, 1).retryAfterSeconds, 60);
  equal(retryAfterSeconds(new Date(now + 150000).toUTCString(), now), 150);
  equal(retryAfterSeconds("9999999", now), 86400);
  equal(retryAfterSeconds("invalid", now), undefined);
});

Deno.test("lost acknowledgements do not resend within an invocation or claim exactly-once success", async () => {
  const test = fixture({ completeFails: true });
  const result = await test.run();
  const counts = await result.json();
  equal(counts.completionUnknown, 1);
  equal(counts.providerAccepted, 0);
  equal(test.sends.length, 1);
  equal(
    test.calls.filter((call) => call.name === "claim_push_deliveries").length,
    1,
  );
});

Deno.test("malformed provider success and network errors retry without accepting a false acknowledgement", async () => {
  for (
    const sendResponse of [
      () => Response.json({ name: "wrong-project/message" }),
      () => {
        throw new Error("private network diagnostic");
      },
    ]
  ) {
    const test = fixture({ sendResponse });
    const response = await test.run();
    equal(response.status, 200);
    equal(test.calls.at(-1)?.args.outcome_to_use, "RETRY");
    assert(
      !JSON.stringify(test.calls.at(-1)?.args).includes(
        "private network diagnostic",
      ),
    );
  }
});

Deno.test("claim errors and duplicated or oversized claim batches never send", async () => {
  for (
    const options of [{ claimFails: true }, {
      claimed: [{ id: deliveryId }, { id: deliveryId }],
    }, {
      claimed: Array.from({ length: 51 }, () => ({ id: crypto.randomUUID() })),
    }]
  ) {
    const test = fixture(options);
    equal((await test.run()).status, 503);
    equal(test.sends.length, 0);
  }
});

Deno.test("a fifty-device batch uses at most twenty provider calls concurrently within its bounded lease budget", async () => {
  let active = 0;
  let maximum = 0;
  const test = fixture({
    claimed: Array.from({ length: 50 }, () => ({ id: crypto.randomUUID() })),
    sendResponse: async () => {
      active++;
      maximum = Math.max(active, maximum);
      await new Promise((resolve) => setTimeout(resolve, 1));
      active--;
      return Response.json({
        name: `projects/${project}/messages/fixture-message`,
      });
    },
  });
  const result = await test.run();
  equal((await result.json()).providerAccepted, 50);
  equal(test.sends.length, 50);
  equal(maximum, 20);
});

Deno.test("payload transport timeouts release claims as retries without sending", async () => {
  const test = fixture({ payloadTimeout: true });
  await test.run();
  equal(test.sends.length, 0);
  equal(test.calls.at(-1)?.args.outcome_to_use, "RETRY");
  equal(test.calls.at(-1)?.args.error_code_to_use, "PAYLOAD_UNAVAILABLE");
});

Deno.test("non-JSON quota responses still preserve the Retry-After minimum", async () => {
  const test = fixture({
    sendResponse: () =>
      new Response("private quota diagnostic", {
        status: 429,
        headers: { "Retry-After": "300" },
      }),
  });
  await test.run();
  equal(test.calls.at(-1)?.args.retry_after_seconds_to_use, 300);
  equal(test.calls.at(-1)?.args.error_code_to_use, "QUOTA_EXCEEDED");
});
