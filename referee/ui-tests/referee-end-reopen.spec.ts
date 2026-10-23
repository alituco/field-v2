import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const env = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? env.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname;
const gameId = "d2000000-0000-4000-8000-000000000001";

async function match(page: Page, options: { final?: boolean; canReopen?: boolean; rejectFirst?: boolean; staleFirst?: boolean } = {}) {
  const writes: Record<string, unknown>[] = [];
  const game = {
    id: gameId, matchKind: "SOLO", ratingPolicyId: "field-sr-season0-v2", status: options.final ? "FINAL" : "LIVE",
    minimumPlayers: 2, participationRulesVersion: "s0-configurable-v1", capacity: 14,
    venue: "Saved Phoenix pitch", day: "SATURDAY", timeSlot: "6:00 PM - 7:00 PM", matchDate: "2030-01-12",
    scheduledDurationSeconds: 3600, operationalState: "NORMAL", operationalStateUpdatedAt: null,
    cancellationCode: null, cancellationReason: null, cancelledAt: null, cancelledBy: null,
    homeScore: 1, awayScore: 0, whiteAverageSr: null, blackAverageSr: null, matchAverageSr: null, teamSrSpread: null,
    teamsAssignedAt: "2030-01-12T12:00:00Z",
    homeClan: { id: "WHITE", name: "White Team", tag: "WHITE", emblem: "", skillRating: 0 },
    awayClan: { id: "BLACK", name: "Black Team", tag: "BLACK", emblem: "", skillRating: 0 },
    players: [
      { id: "white-player", clanId: "WHITE", displayName: "White Player", role: "ATT", username: "white", avatarUrl: null, ratingAtTeamAssignment: null },
      { id: "black-player", clanId: "BLACK", displayName: "Black Player", role: "ATT", username: "black", avatarUrl: null, ratingAtTeamAssignment: null },
    ],
    participantIds: ["white-player", "black-player"],
    clock: { status: options.final ? "ENDED" : "PAUSED", startedAt: null, accumulatedSeconds: 300, durationSeconds: 3600 },
    goals: [], events: [], blueCards: [], reliabilityContext: null, riskContext: { teams: [], players: [], guidance: "" },
  };
  const state = {
    game_id: gameId, revision: 3, lifecycle: options.final ? "FINAL" : "LIVE", rating_status: options.final ? "unranked" : "pending_review",
    settlement_status: options.final ? "NOT_RATED" : "UNSETTLED", referee_can_reopen: options.canReopen ?? Boolean(options.final),
    elapsed_seconds: 300, scheduled_seconds: 3600, server_now: "2030-01-12T18:05:00Z", observed_roster: [], events: [], audit: { players: {} },
  };
  await page.addInitScript(key => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } } })), `fieldrush-staff-${project}-auth-v1`);
  await page.route("**/*.supabase.co/**", route => route.fulfill({ json: {} }));
  await page.route("**/api/referee/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() === "POST") {
      const body = route.request().postDataJSON(); writes.push(body);
      if (writes.length === 1 && options.rejectFirst) return route.fulfill({ status: 503, json: { error: "Temporary connection failure. Retry the same request." } });
      if (writes.length === 1 && options.staleFirst) {
        state.revision++;
        return route.fulfill({ status: 400, json: { error: "Refresh the changed match before finishing." } });
      }
      const reopening = body.action === "reopen";
      game.status = reopening ? "LIVE" : "FINAL";
      game.clock.status = reopening ? "PAUSED" : "ENDED";
      state.revision++;
      state.lifecycle = game.status;
      state.rating_status = reopening ? "pending_review" : "unranked";
      state.settlement_status = reopening ? "HELD" : "NOT_RATED";
      state.referee_can_reopen = !reopening;
      return route.fulfill({ json: { ok: true, seasonZeroState: state } });
    }
    if (path === "/api/referee/fixtures") return route.fulfill({ json: { me: { profileId: "referee", displayName: "Preview Referee", role: "referee" }, fixtures: [game] } });
    if (path.endsWith("/participation")) return route.fulfill({ json: { state } });
    return route.fulfill({ json: { broadcast: null, device: null } });
  });
  await page.goto("/");
  return { writes, game };
}

test("referee ends early and reopens with the saved score and a paused clock", async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const { writes, game } = await match(page);
  await page.getByText("End match", { exact: true }).click();
  await expect(page.getByText(/finish before the agreed duration/)).toBeVisible();
  await expect(page.getByRole("button", { name: "Finish match", exact: true })).toBeEnabled();
  expect(writes).toHaveLength(0);
  await page.getByRole("button", { name: "Finish match", exact: true }).click();
  await page.getByText("Reopen match", { exact: true }).click();
  await expect(page.getByText(/clock stays paused/)).toBeVisible();
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.screenshot({ path: info.outputPath("referee-reopen-mobile.png"), fullPage: true });
  expect(writes).toHaveLength(1);
  await page.getByRole("button", { name: "Confirm reopen match", exact: true }).click();
  await expect(page.getByRole("button", { name: "Resume", exact: true })).toBeEnabled();
  expect(game.clock.accumulatedSeconds).toBe(300);
  expect([game.homeScore, game.awayScore]).toEqual([1, 0]);
  expect(writes).toEqual([
    { action: "finish", expectedRevision: 3, requestId: expect.stringMatching(/^[0-9a-f-]{36}$/) },
    { action: "reopen", expectedRevision: 4, requestId: expect.stringMatching(/^[0-9a-f-]{36}$/) },
  ]);
  expect(writes[0].requestId).not.toBe(writes[1].requestId);
});

test("an uncertain finish retries the same operation without losing its confirmed revision", async ({ page }) => {
  const { writes } = await match(page, { rejectFirst: true });
  await page.getByText("End match", { exact: true }).click();
  await page.getByRole("button", { name: "Finish match", exact: true }).click();
  await expect(page.getByText("Temporary connection failure. Retry the same request.", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Finish match", exact: true }).click();
  await expect.poll(() => writes.length).toBe(2);
  expect(writes[1]).toEqual(writes[0]);
});

test("a stale finish can refresh the revision before a newly confirmed request", async ({ page }) => {
  const { writes } = await match(page, { staleFirst: true });
  await page.getByText("End match", { exact: true }).click();
  await page.getByRole("button", { name: "Finish match", exact: true }).click();
  await expect(page.getByText("Refresh the changed match before finishing.", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Refresh match state", exact: true }).click();
  await page.getByRole("button", { name: "Finish match", exact: true }).click();
  await expect.poll(() => writes.length).toBe(2);
  expect(writes[0].expectedRevision).toBe(3);
  expect(writes[1].expectedRevision).toBe(4);
  expect(writes[0].requestId).not.toBe(writes[1].requestId);
});

test("organizer-controlled results cannot be reopened through referee controls", async ({ page }) => {
  const { writes } = await match(page, { final: true, canReopen: false });
  await page.getByText("Reopen match", { exact: true }).click();
  await expect(page.getByText("This result needs an organizer review before it can be reopened.", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Confirm reopen match", exact: true })).toBeDisabled();
  expect(writes).toHaveLength(0);
});
