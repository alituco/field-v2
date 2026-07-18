import {
  assertSafeDevDataTarget,
  FIELD_PRODUCTION_PROJECT_REF,
  FIELD_STAGING_PROJECT_REF,
} from "./environment_guard.ts";

Deno.test("allows the exact Field Staging project over HTTPS", () => {
  const target = assertSafeDevDataTarget(
    `https://${FIELD_STAGING_PROJECT_REF}.supabase.co`,
    "test seed",
  );

  assertEquals(target.environment, "staging");
});

Deno.test("allows true IPv4, IPv6, and named loopback URLs", () => {
  for (
    const url of [
      "http://localhost:54321",
      "http://127.0.0.1:54321",
      "http://[::1]:54321",
      "https://localhost:54321",
    ]
  ) {
    const target = assertSafeDevDataTarget(url, "test seed");
    assertEquals(target.environment, "local");
  }
});

Deno.test("hard-denies the exact Field Production project", () => {
  assertThrows(
    () =>
      assertSafeDevDataTarget(
        `https://${FIELD_PRODUCTION_PROJECT_REF}.supabase.co`,
        "test seed",
      ),
    "Field Production",
  );
});

Deno.test("fails closed for unknown hosted Supabase projects", () => {
  assertThrows(
    () =>
      assertSafeDevDataTarget(
        "https://aaaaaaaaaaaaaaaaaaaa.supabase.co",
        "test seed",
      ),
    "is not Field Staging",
  );
});

Deno.test("rejects a non-default or credentialed staging origin", () => {
  for (
    const url of [
      `https://${FIELD_STAGING_PROJECT_REF}.supabase.co:8443`,
      `https://user:password@${FIELD_STAGING_PROJECT_REF}.supabase.co`,
      `https://${FIELD_STAGING_PROJECT_REF}.supabase.co/rest/v1`,
      `https://${FIELD_STAGING_PROJECT_REF}.supabase.co?preview=true`,
      `https://${FIELD_STAGING_PROJECT_REF}.supabase.co#preview`,
    ]
  ) {
    assertThrows(
      () => assertSafeDevDataTarget(url, "test seed"),
      url.includes(":8443") ? "is not Field Staging" : "bare origin",
    );
  }
});

Deno.test("rejects credentialed or non-bare loopback URLs", () => {
  for (
    const url of [
      "http://user:password@localhost:54321",
      "http://localhost:54321/rest/v1",
      "http://localhost:54321?preview=true",
      "http://localhost:54321#preview",
    ]
  ) {
    assertThrows(
      () => assertSafeDevDataTarget(url, "test seed"),
      "bare origin",
    );
  }
});

Deno.test("does not mistake a lookalike hostname for loopback", () => {
  assertThrows(
    () =>
      assertSafeDevDataTarget(
        "https://localhost.example.com",
        "test seed",
      ),
    "is not Field Staging",
  );
});

Deno.test("requires a valid absolute URL", () => {
  assertThrows(
    () => assertSafeDevDataTarget("/localhost:54321", "test seed"),
    "valid absolute URL",
  );
  assertThrows(
    () => assertSafeDevDataTarget("localhost:54321", "test seed"),
    "must use HTTP or HTTPS",
  );
});

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, received ${
        JSON.stringify(actual)
      }`,
    );
  }
}

function assertThrows(run: () => unknown, expectedMessage: string): void {
  let thrown: unknown;
  try {
    run();
  } catch (error) {
    thrown = error;
  }

  if (!(thrown instanceof Error)) {
    throw new Error("Expected the operation to throw an Error.");
  }
  if (!thrown.message.includes(expectedMessage)) {
    throw new Error(
      `Expected error containing ${JSON.stringify(expectedMessage)}, got ` +
        JSON.stringify(thrown.message),
    );
  }
}
