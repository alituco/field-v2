import assert from "node:assert/strict";
import test from "node:test";

import {
  finishFailureMessage,
  isSoloFinishAction,
} from "../e2e/support/finish-solo-match.ts";

test("finalization diagnostics match the exact selected solo finish request", () => {
  const path = "/api/referee/open-queue-games/game-one/action";
  assert.equal(isSoloFinishAction("POST", path, { action: "finish" }, "game-one"), true);
  for (const [method, url, body] of [
    ["GET", path, { action: "finish" }],
    ["POST", path, { action: "goal" }],
    ["POST", path, null],
    ["POST", path, [{ action: "finish" }]],
    ["POST", "/api/referee/open-queue-games/game-two/action", { action: "finish" }],
    ["POST", "/api/referee/fixtures/game-one/action", { action: "finish" }],
    ["POST", `${path}/other`, { action: "finish" }],
  ]) {
    assert.equal(isSoloFinishAction(method, url, body, "game-one"), false);
  }
});

test("finalization failure reports the database error, not a status poll timeout", () => {
  assert.equal(
    finishFailureMessage(400, { error: "Could not finalize solo game: canceling statement due to statement timeout" }),
    "Solo match finalization failed (HTTP 400): Could not finalize solo game: canceling statement due to statement timeout",
  );
});

test("finalization diagnostics omit all payload data except a sanitized error", () => {
  const message = finishFailureMessage(400, {
    error: "Database failure\nBearer fake-auth-header access_token=fake-access refresh-token='fake-refresh' apikey=fake-api service_role_key=fake-service sk_test_fakeStripeKey sb_secret_fakeSupabaseKey eyJfake.payload.signature postgres://user:fake-password@localhost/database",
    authorization: "fake-authorization-metadata",
    access_token: "fake-payload-token",
    details: { headers: { authorization: "fake-nested-auth" } },
  });
  assert.match(message, /^Solo match finalization failed \(HTTP 400\): Database failure /);
  assert.doesNotMatch(message, /fake-|fakeStripe|fakeSupabase|eyJfake|\n/);
  assert.match(message, /\[redacted\]/);
});

test("malformed error payloads produce a safe bounded fallback", () => {
  for (const payload of [null, [], "private body", { error: { token: "private body" } }, { details: "private body" }]) {
    const message = finishFailureMessage(500, payload);
    assert.match(message, /HTTP 500/);
    assert.match(message, /did not return a successful finalization acknowledgement/);
    assert.doesNotMatch(message, /private body/);
  }
  assert.ok(finishFailureMessage(400, { error: "x".repeat(2000) }).length < 700);
});
