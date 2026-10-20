import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const config = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? config.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname.split(".")[0];
const id = "d1000000-0000-4000-8000-000000000001";

type Options = {
  fixture?: Record<string, unknown>;
  firstConflict?: boolean;
  malformed?: "wrong-game" | "partial";
};

async function mockGame(page: Page, options: Options = {}) {
  const writes: Record<string, unknown>[] = [];
  let reads = 0;
  let filled = false;
  await page.addInitScript(({ key }) => localStorage.setItem(key, JSON.stringify({
    access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800,
    user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated" },
  })), { key: `sb-${project}-auth-token` });
  await page.route("**/*.supabase.co/**", route => route.fulfill({ json: {} }));
  await page.route("**/api/referee/**", async route => {
    const request = route.request();
    if (request.method() === "POST") {
      expect(new URL(request.url()).pathname).toBe(`/api/referee/admin/games/solo/${id}/fill-bots`);
      expect(request.headers().authorization).toBe("Bearer ui-test-token");
      const body = request.postDataJSON();
      writes.push(body);
      if (options.firstConflict && writes.length === 1) {
        await route.fulfill({ status: 409, json: { error: "An active checkout reserves positions in this game." } });
        return;
      }
      if (!options.malformed) filled = true;
      await route.fulfill({ json: {
        gameId: options.malformed === "wrong-game" ? "other-game" : id,
        requestId: body.requestId,
        createdBots: options.malformed === "partial" ? 10 : 11,
        confirmedCount: options.malformed === "partial" ? 13 : 14,
        capacity: 14, alreadyFilled: false,
      } });
      return;
    }
    reads++;
    const fixture = {
      matchKind: "SOLO", id, status: filled ? "FULL" : "OPEN", operationalState: "NORMAL",
      teamsAssignedAt: null, venue: "Encanto Park · Pitch 1", day: "Saturday", timeSlot: "8:30 PM", matchDate: "2099-07-25",
      homeScore: null, awayScore: null, clock: null, events: [],
      homeClan: { id: "white", name: "White team", tag: "WHT", emblem: "W" },
      awayClan: { id: "black", name: "Black team", tag: "BLK", emblem: "B" },
      ...options.fixture,
    };
    const count = filled ? 14 : 3;
    const players = Array.from({ length: count }, (_, index) => ({
      profileId: `player-${index}`, displayName: index < 3 ? `Existing player ${index + 1}` : `[BOT] Test player ${index - 2}`,
      username: null, avatarUrl: null, side: null, role: index === 0 ? "GK" : "ATT", checkedInAt: null, ratingAtTeamAssignment: null,
    }));
    await route.fulfill({ json: { detail: {
      fixture, currency: "USD", pricing: null, formation: null,
      participants: { matchKind: "SOLO", matchId: id, status: fixture.status, capacity: 14, capacityPerSide: 7,
        registeredPlayers: players, actualPlayers: [], withdrawnPlayers: [], counts: { registered: count, actual: 0, withdrawn: 0 } },
      reserves: { active: [], history: [] }, assignedReferee: null,
      ratingSummary: { kind: "SOLO", whiteAverageSr: null, blackAverageSr: null, matchAverageSr: null, teamSrSpread: null, ratedPlayers: 0 },
      audit: [], reports: [], stoppages: [], resolutionCase: null,
    } } });
  });
  await page.goto(`/admin/games/solo/${id}`);
  await expect(page.getByText("Existing player 1", { exact: true })).toBeVisible();
  return { writes, get reads() { return reads; } };
}

test("staging bot fill explains the limited action and can be cancelled without writing", async ({ page }) => {
  const calls = await mockGame(page);
  await page.getByRole("button", { name: "Fill game with bots", exact: true }).click();
  await expect(page.getByText(/Existing players stay booked\. No one is charged, checked in, or assigned to a team/)).toBeVisible();
  await expect(page.getByRole("button", { name: "Confirm fill with bots", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Cancel bot fill" }).click();
  await expect(page.getByRole("button", { name: "Fill game with bots", exact: true })).toBeVisible();
  expect(calls.writes).toHaveLength(0);
});

test("confirmed fill refreshes the roster and leaves team locking and check-in separate", async ({ page }, info) => {
  const calls = await mockGame(page);
  await page.getByRole("button", { name: "Fill game with bots", exact: true }).click();
  await page.getByRole("button", { name: "Confirm fill with bots", exact: true }).click();
  await expect(page.getByRole("main").getByRole("status")).toContainText("Added 11 staging bots. 14 / 14 places are booked.");
  await expect(page.getByText("[BOT] Test player 11", { exact: true })).toBeVisible();
  await expect(page.getByText("Existing player 1", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Lock teams", exact: true })).toBeEnabled();
  await expect(page.getByText("Checked in", { exact: true })).toHaveCount(0);
  expect(calls.writes).toHaveLength(1);
  expect(Object.keys(calls.writes[0]).sort()).toEqual(["confirmation", "requestId"]);
  expect(calls.writes[0].confirmation).toBe("FILL_WITH_BOTS");
  expect(calls.writes[0].requestId).toMatch(/^[0-9a-f-]{36}$/);
  expect(calls.reads).toBe(2);
  await page.screenshot({ path: info.outputPath("staging-bots-filled.png"), fullPage: true });
});

test("retry preserves its request ID after a booking conflict", async ({ page }) => {
  const calls = await mockGame(page, { firstConflict: true });
  await page.getByRole("button", { name: "Fill game with bots", exact: true }).click();
  await page.getByRole("button", { name: "Confirm fill with bots", exact: true }).click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText("An active checkout reserves positions");
  expect(calls.reads).toBe(1);
  await page.getByRole("button", { name: "Confirm fill with bots", exact: true }).click();
  await expect(page.getByRole("main").getByRole("status")).toContainText("Added 11 staging bots");
  expect(calls.writes).toHaveLength(2);
  expect(calls.writes[0].requestId).toBe(calls.writes[1].requestId);
  expect(calls.reads).toBe(2);
});

for (const malformed of ["wrong-game", "partial"] as const) {
  test(`${malformed} success reply never refreshes or claims a completed fill`, async ({ page }) => {
    const calls = await mockGame(page, { malformed });
    await page.getByRole("button", { name: "Fill game with bots", exact: true }).click();
    await page.getByRole("button", { name: "Confirm fill with bots", exact: true }).click();
    await expect(page.getByRole("main").getByRole("alert")).toContainText("The bot fill could not be confirmed");
    await expect(page.getByRole("main").getByRole("status")).toHaveCount(0);
    expect(calls.writes).toHaveLength(1);
    expect(calls.reads).toBe(1);
  });
}

for (const [label, fixture] of [
  ["live", { status: "LIVE" }], ["finished", { status: "FINAL" }],
  ["under review", { operationalState: "UNDER_REVIEW" }],
  ["teams locked", { teamsAssignedAt: "2026-10-20T00:00:00Z" }],
  ["started clock", { clock: { status: "PAUSED", startedAt: null, accumulatedSeconds: 30 } }],
] as const) {
  test(`${label} games hide the staging bot action`, async ({ page }) => {
    const calls = await mockGame(page, { fixture });
    await expect(page.getByRole("button", { name: "Fill game with bots", exact: true })).toHaveCount(0);
    expect(calls.writes).toHaveLength(0);
  });
}
