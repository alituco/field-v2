import assert from "node:assert/strict";
import test from "node:test";

import {
  productionProjectRef,
  resolveFieldEnvironment,
  stagingProjectRef,
} from "../src/lib/app-environment.ts";

test("the hosted staging project is visibly identified", () => {
  assert.deepEqual(
    resolveFieldEnvironment(
      "staging",
      `https://${stagingProjectRef}.supabase.co`,
    ),
    {
      environment: "staging",
      label: "STAGING",
      error: null,
    },
  );
});

test("the environment can be inferred for an existing staging setup", () => {
  assert.equal(
    resolveFieldEnvironment(
      undefined,
      `https://${stagingProjectRef}.supabase.co`,
    ).label,
    "STAGING",
  );
});

test("production refuses to point at staging", () => {
  assert.match(
    resolveFieldEnvironment(
      "production",
      `https://${stagingProjectRef}.supabase.co`,
    ).error ?? "",
    /Field Production/,
  );
});

test("production accepts only the guarded production project", () => {
  assert.deepEqual(
    resolveFieldEnvironment(
      "production",
      `https://${productionProjectRef}.supabase.co`,
    ),
    {
      environment: "production",
      label: null,
      error: null,
    },
  );
});

test("a hosted lookalike domain cannot impersonate Field Staging", () => {
  assert.match(
    resolveFieldEnvironment(
      "staging",
      `https://${stagingProjectRef}.other-domain.test`,
    ).error ?? "",
    /Field Staging/,
  );
});

test("hosted environments require the exact bare Supabase origin", () => {
  for (const url of [
    `https://${stagingProjectRef}.supabase.co/rest/v1`,
    `https://${stagingProjectRef}.supabase.co?preview=true`,
    `https://${stagingProjectRef}.supabase.co#preview`,
    `https://user:pass@${stagingProjectRef}.supabase.co`,
  ]) {
    assert.match(
      resolveFieldEnvironment("staging", url).error ?? "",
      /Field Staging/,
    );
  }
});

test("an unknown environment fails closed instead of looking like production", () => {
  assert.match(
    resolveFieldEnvironment("", "").error ?? "",
    /Set NEXT_PUBLIC_APP_ENV/,
  );
});

test("local must use a loopback Supabase URL", () => {
  assert.match(
    resolveFieldEnvironment(
      "local",
      `https://${stagingProjectRef}.supabase.co`,
    ).error ?? "",
    /local Supabase/,
  );
});

test("local requires plain HTTP on a bare loopback origin", () => {
  for (const url of [
    "https://localhost:54321",
    "http://localhost:54321/rest/v1",
    "http://user:pass@localhost:54321",
  ]) {
    assert.match(
      resolveFieldEnvironment("local", url).error ?? "",
      /local Supabase/,
    );
  }
});
