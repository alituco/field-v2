import {
  E2E_SCHEMA_VERSION,
  E2E_STAFF_EMAIL,
  type E2EAccount,
  type E2EManifest,
  normalizeRunId,
  parseManifest,
  requireIndependentE2EStaff,
  selectRotatingIndex,
} from "./_shared.ts";

Deno.test("parses the versioned, tagged E2E manifest contract", () => {
  const manifest = validManifest();
  const parsed = parseManifest(manifest);

  assertEquals(parsed.runId, "test-run-42");
  assertEquals(parsed.accounts.players.length, 14);
  assertEquals(
    parsed.accounts.main.profileId,
    manifest.accounts.main.profileId,
  );
});

Deno.test("staff Auth and actor keys are separate and alias fields are exact", () => {
  const valid = validManifest();
  assertEquals(requireIndependentE2EStaff(valid).email, E2E_STAFF_EMAIL);
  for (
    const mutate of [
      (m: E2EManifest) => {
        m.login.adminAuthUserId = m.login.adminProfileId;
      },
      (m: E2EManifest) => {
        m.login.adminEmail = "real@example.test";
      },
      (m: E2EManifest) => {
        m.accounts.admin.authUserId = m.accounts.main.profileId;
      },
      (m: E2EManifest) => {
        m.accounts.admin.email = "other@example.test";
      },
    ]
  ) {
    const manifest = validManifest();
    mutate(manifest);
    assertThrows(
      () => parseManifest(manifest),
      "independent reserved staff identity",
    );
  }
});

Deno.test("older schema-2 mobile manifests parse but cannot authorize new staff setup or cleanup", () => {
  const manifest = validManifest();
  delete manifest.login.adminAuthUserId;
  delete manifest.login.adminEmail;
  delete manifest.accounts.admin.authUserId;
  delete manifest.accounts.admin.email;
  assertEquals(parseManifest(manifest).schemaVersion, 2);
  assertThrows(
    () => requireIndependentE2EStaff(manifest),
    "independent E2E staff Auth id",
  );
});

Deno.test("rejects an untagged account before cleanup can mutate it", () => {
  const manifest = validManifest();
  manifest.accounts.players[3].displayName = "Real Player";

  assertThrows(
    () => parseManifest(manifest),
    "untagged test account",
  );
});

Deno.test("rejects a marker that does not belong to the manifest run", () => {
  const manifest = validManifest();
  manifest.markers.supportDetails = "[FIELD E2E another-run] Wrong marker.";

  assertThrows(
    () => parseManifest(manifest),
    "text markers are invalid",
  );
});

Deno.test("rejects an untagged game before cleanup can cancel it", () => {
  const manifest = validManifest();
  manifest.games.cancellation.venue = "A real staging venue";

  assertThrows(
    () => parseManifest(manifest),
    "games are not safely run-tagged",
  );
});

Deno.test("rejects an incomplete player rating baseline", () => {
  const manifest = validManifest();
  delete manifest.ratingsBefore[manifest.accounts.players[0].profileId];

  assertThrows(
    () => parseManifest(manifest),
    "one safe rating baseline per player",
  );
});

Deno.test("normalizes CI run identifiers and rotates deterministically", () => {
  assertEquals(normalizeRunId("  action / attempt #2  "), "action-attempt-2");
  assertEquals(
    selectRotatingIndex("same-run", 14),
    selectRotatingIndex("same-run", 14),
  );
});

function validManifest(): E2EManifest {
  const runId = "test-run-42";
  const players = Array.from(
    { length: 14 },
    (_, index) =>
      account(
        index + 1,
        `+973390090${String(index + 1).padStart(2, "0")}`,
        `field_e2e_${String(index + 1).padStart(2, "0")}`,
      ),
  );
  const onboarding = account(
    15,
    "+97339009100",
    "field_e2e_onboarding",
  );
  const admin = account(16, "+97339009099", "field_e2e_admin");
  admin.authUserId = uuid(17);
  admin.email = E2E_STAFF_EMAIL;

  return {
    schemaVersion: E2E_SCHEMA_VERSION,
    runId,
    createdAt: "2026-07-18T00:00:00.000Z",
    target: {
      environment: "staging",
      supabaseUrl: "https://nfdkdhdevpstfspazbfn.supabase.co",
      projectRef: "nfdkdhdevpstfspazbfn",
    },
    login: {
      bootstrapPhone: "+97339009098",
      otpCode: "000000",
      adminProfileId: admin.profileId,
      adminPhone: admin.phone,
      adminAuthUserId: admin.authUserId,
      adminEmail: admin.email,
    },
    accounts: {
      main: players[0],
      partyTarget: players[1],
      onboarding,
      admin,
      players,
    },
    games: {
      match: {
        id: uuid(20),
        venue: "[FIELD E2E test-run-42] Match",
        startsAt: "2026-07-29T03:30:00.000Z",
        endsAt: "2026-07-29T04:30:00.000Z",
        mainRole: "DEF",
        capacity: 14,
        seededConfirmedCount: 13,
      },
      cancellation: {
        id: uuid(21),
        venue: "[FIELD E2E test-run-42] Cancel",
        startsAt: "2026-08-01T03:30:00.000Z",
        endsAt: "2026-08-01T04:30:00.000Z",
        mainRole: "ATT",
        capacity: 14,
        seededConfirmedCount: 0,
      },
    },
    markers: {
      venuePrefix: "[FIELD E2E test-run-42]",
      reportDetails:
        "[FIELD E2E test-run-42] Automated player report verification.",
      supportDetails:
        "[FIELD E2E test-run-42] Automated support request verification.",
      supportContext: {
        field_e2e: true,
        e2e_run_id: runId,
      },
    },
    ratingsBefore: Object.fromEntries(
      players.map((player) => [player.profileId, 1200]),
    ),
  };
}

function account(index: number, phone: string, username: string): E2EAccount {
  return {
    profileId: uuid(index),
    phone,
    displayName: `[E2E] Player ${index}`,
    username,
  };
}

function uuid(index: number): string {
  return `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
}

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, received ${
        JSON.stringify(actual)
      }.`,
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
