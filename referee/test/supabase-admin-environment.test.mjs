import assert from "node:assert/strict";
import test from "node:test";

import {
  assertSupabaseAdminEnvironment,
  productionProjectRef,
  stagingProjectRef,
} from "../src/lib/app-environment.ts";

test("service-role initialization accepts only the matching production project", () => {
  assert.equal(
    assertSupabaseAdminEnvironment(
      `https://${productionProjectRef}.supabase.co`,
      "production",
    ).environment,
    "production",
  );

  assert.throws(
    () =>
      assertSupabaseAdminEnvironment(
        `https://${stagingProjectRef}.supabase.co`,
        "production",
      ),
    /Refusing Supabase service-role initialization.*Field Production/,
  );
});

test("service-role initialization rejects unknown and lookalike hosted projects", () => {
  for (
    const url of [
      "https://aaaaaaaaaaaaaaaaaaaa.supabase.co",
      `https://${stagingProjectRef}.other-domain.test`,
    ]
  ) {
    assert.throws(
      () => assertSupabaseAdminEnvironment(url, "staging"),
      /Refusing Supabase service-role initialization/,
    );
  }
});

test("service-role initialization preserves local and staging development", () => {
  assert.equal(
    assertSupabaseAdminEnvironment(
      "http://127.0.0.1:54321",
      "local",
    ).environment,
    "local",
  );
  assert.equal(
    assertSupabaseAdminEnvironment(
      `https://${stagingProjectRef}.supabase.co`,
      "staging",
    ).environment,
    "staging",
  );
});
