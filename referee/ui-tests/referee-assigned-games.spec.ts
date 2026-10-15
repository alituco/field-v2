import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const env = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? env.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname.split(".")[0];

function game(id: string, status = "OPEN", overrides: Record<string, unknown> = {}) {
  return {
    id, matchKind: "SOLO", status, ratingPolicyId: "LEGACY",
    venue: `Pitch ${id}`, day: "SATURDAY", timeSlot: "4:30 PM - 5:40 PM", matchDate: "2030-01-12", timezone: "America/Phoenix",
    scheduledDurationSeconds: 4200, operationalState: null, operationalStateUpdatedAt: null,
    cancellationCode: null, cancellationReason: null, cancelledAt: null, cancelledBy: null,
    homeScore: null, awayScore: null, whiteAverageSr: null, blackAverageSr: null, matchAverageSr: null,
    teamSrSpread: null, teamsAssignedAt: null,
    homeClan: { id: "WHITE", name: "White Team", tag: "WHITE", emblem: "", skillRating: 0 },
    awayClan: { id: "BLACK", name: "Black Team", tag: "BLACK", emblem: "", skillRating: 0 },
    players: [], participantIds: [], clock: null, goals: [], events: [], blueCards: [], reliabilityContext: null,
    riskContext: { teams: [], players: [], guidance: "" }, ...overrides,
  };
}

async function mockAssignments(page: Page, fixtures: ReturnType<typeof game>[]) {
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  let reads = 0;
  await page.addInitScript((key) => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated" } })), `sb-${project}-auth-token`);
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({ json: {} }));
  await page.route("**/api/referee/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    let data: unknown = {};
    if (route.request().method() !== "GET") {
      writes.push({ path, body: route.request().postDataJSON() });
      data = { ok: true };
    } else if (path === "/api/referee/fixtures") {
      reads++;
      data = { me: { profileId: "00000000-0000-4000-8000-000000000001", displayName: "Preview Referee", role: "admin" }, fixtures };
    } else if (path.includes("broadcast")) data = { broadcast: null, device: null };
    await route.fulfill({ json: data });
  });
  return { writes, get reads() { return reads; } };
}

test("an assigned OPEN game appears before it fills without enabling legacy kickoff", async ({ page }, info) => {
  const state = await mockAssignments(page, [game("open")]);
  await page.goto("/");
  await expect(page.locator(".referee-kickoff-details")).toContainText("Pitch open");
  await expect(page.getByRole("heading", { name: "No match assigned" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Start game", exact: true })).toBeDisabled();
  await expect(page.getByText("This solo game must be full before it can start.", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Goal Scorer and assist" })).toBeDisabled();
  expect(state.writes).toEqual([]);
  await page.screenshot({ path: info.outputPath("assigned-open-game.png"), fullPage: true });
});

test("all assigned states remain selectable, including history and pending opposition", async ({ page }) => {
  const fixtures = [
    game("live", "LIVE"), game("open"), game("full", "FULL"),
    game("clan", "OPEN", { matchKind: "CLAN", awayClan: { id: "", name: "Opponent pending", tag: "TBD", emblem: "", skillRating: 0 } }),
    game("final", "FINAL", { matchDate: "2000-01-01" }),
    game("cancelled", "CANCELLED", { matchDate: "2000-01-02" }),
  ];
  await mockAssignments(page, fixtures);
  await page.goto("/");
  const select = page.getByLabel("Choose assigned match");
  await expect(select.locator("option")).toHaveCount(fixtures.length);
  for (const fixture of fixtures) {
    await select.selectOption(`${fixture.matchKind}:${fixture.id}`);
    await expect(page.locator(".referee-kickoff-details")).toContainText(`Pitch ${fixture.id}`);
  }
  await select.selectOption("CLAN:clan");
  await expect(select).toContainText("WHITE vs TBD");
  await expect(page.getByRole("button", { name: "Start game", exact: true })).toBeDisabled();
});

test("clan and solo matches sharing an id remain distinct, and selection survives refresh", async ({ page }) => {
  const state = await mockAssignments(page, [
    game("shared", "OPEN", { venue: "Solo pitch" }),
    game("shared", "SCHEDULED", { matchKind: "CLAN", venue: "Clan pitch" }),
  ]);
  await page.goto("/");
  const select = page.getByLabel("Choose assigned match");
  await expect(select).toHaveValue("SOLO:shared");
  await select.selectOption("CLAN:shared");
  await expect(page.locator(".referee-kickoff-details")).toContainText("Clan pitch");
  await page.getByText("Match timeline", { exact: true }).click();
  const reads = state.reads;
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await expect.poll(() => state.reads).toBeGreaterThan(reads);
  await expect(select).toHaveValue("CLAN:shared");
  await expect(page.locator(".referee-kickoff-details")).toContainText("Clan pitch");
  await select.selectOption("SOLO:shared");
  await expect(page.locator(".referee-kickoff-details")).toContainText("Solo pitch");
});

for (const clockStatus of ["RUNNING", "PAUSED"] as const) {
  test(`cancelled history with a stale ${clockStatus} clock stays read-only`, async ({ page }) => {
    const state = await mockAssignments(page, [game("cancelled", "CANCELLED", {
      matchDate: "2000-01-01",
      clock: { status: clockStatus, startedAt: "2000-01-01T00:00:00Z", accumulatedSeconds: 0, durationSeconds: 3600 },
      blueCards: [{ id: "old-card", fixtureId: "cancelled", clanId: "WHITE", profileId: "player", status: "ACTIVE", expiresAt: "2000-01-01T00:02:00Z", startedAt: "2000-01-01T00:00:00Z", durationSeconds: 120, minute: 0, second: 0 }],
    })]);
    await page.goto("/");
    await expect(page.getByRole("button", { name: "Cancelled", exact: true })).toBeDisabled();
    for (const label of ["Start game", "Pause", "Resume", "Finish match", "Returned"]) {
      await expect(page.getByRole("button", { name: label, exact: true })).toHaveCount(0);
    }
    await expect(page.getByText("Correct match time", { exact: true })).toHaveCount(0);
    expect(state.writes).toEqual([]);
  });
}

test("opening an overdue LIVE assignment never auto-finishes it", async ({ page }) => {
  await page.clock.install({ time: new Date("2030-01-12T18:00:00Z") });
  await page.clock.pauseAt(new Date("2030-01-12T18:00:00Z"));
  const state = await mockAssignments(page, [game("old-live", "LIVE", {
    matchDate: "2000-01-01",
    clock: { status: "RUNNING", startedAt: "2000-01-01T00:00:00Z", accumulatedSeconds: 0, durationSeconds: 3600 },
  })]);
  await page.goto("/");
  await expect(page.getByRole("button", { name: "Pause", exact: true })).toBeVisible();
  await page.clock.runFor(3_000);
  expect(state.writes).toEqual([]);
});

test("a LIVE clock observed crossing the safety cap still finishes once", async ({ page }) => {
  await page.clock.install({ time: new Date("2030-01-12T18:00:00Z") });
  await page.clock.pauseAt(new Date("2030-01-12T18:00:00Z"));
  const state = await mockAssignments(page, [game("live-cap", "LIVE", {
    clock: { status: "RUNNING", startedAt: "2030-01-12T15:00:01Z", accumulatedSeconds: 0, durationSeconds: 3600 },
  })]);
  await page.goto("/");
  await expect(page.getByRole("button", { name: "Pause", exact: true })).toBeVisible();
  await page.clock.runFor(3_000);
  await expect.poll(() => state.writes.length).toBe(1);
  expect(state.writes[0]).toEqual({ path: "/api/referee/open-queue-games/live-cap/action", body: { action: "finish" } });
});

test("cancelled attendance stays visible without check-in or finalize controls", async ({ page }) => {
  const state = await mockAssignments(page, [game("cancelled", "CANCELLED", {
    reliabilityContext: {
      serverNow: "2030-01-12T18:00:00Z", policyVersionId: "policy", kickoffAt: null,
      checkInDeadlineAt: null, noShowCutoffAt: null, canCheckIn: true, canFinalizeAttendance: true,
      attendanceFinalized: false, expectedCount: 1, checkedInCount: 0, onTimeCount: 0, lateCount: 0, missingCount: 1,
      verifiedInjuries: [], openShorthandedPeriods: [], players: [{
        profileId: "player", displayName: "Booked Player", role: "ATT", teamName: "WHITE", side: "WHITE",
        status: "MISSING", isCheckedIn: false, checkInEligible: true, canRemoveCheckIn: false,
      }],
    },
  })]);
  await page.goto("/");
  await page.getByRole("button", { name: "Players", exact: false }).click();
  await expect(page.getByText("This match was cancelled. Attendance is visible for reference and cannot be changed here.", { exact: true })).toBeVisible();
  await page.getByText("Player list", { exact: true }).click();
  await expect(page.getByText("Booked Player", { exact: true })).toBeVisible();
  for (const label of ["Check in", "Finalize", "Remove"]) {
    await expect(page.getByRole("button", { name: label, exact: true })).toHaveCount(0);
  }
  expect(state.writes).toEqual([]);
});
