import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const config = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? config.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname;
const id = "d1000000-0000-4000-8000-000000000001";
const newWhite = "e1000000-0000-4000-8000-000000000013";
const newBlack = "e1000000-0000-4000-8000-000000000014";

async function mockGame(page: Page, { firstConflict = false, status = "FULL", operationalState = "NORMAL", started = false } = {}) {
  const writes: { requestId: string; assignments: { profileId: string; team: string }[] }[] = [];
  let reads = 0;
  let saved = false;
  await page.addInitScript(({ key }) => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } } })), { key: `fieldrush-staff-${project}-auth-v1` });
  await page.route("**/*.supabase.co/**", route => route.fulfill({ json: {} }));
  await page.route("**/api/referee/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() === "POST") {
      expect(path).toBe(`/api/referee/admin/games/solo/${id}/assign-players`);
      expect(route.request().headers().authorization).toBe("Bearer ui-test-token");
      const body = route.request().postDataJSON(); writes.push(body);
      if (firstConflict && writes.length === 1) {
        await route.fulfill({ status: 409, json: { error: "This player has already been assigned. Refresh the roster before placing players." } }); return;
      }
      saved = true;
      await route.fulfill({ json: { ok: true, assignment: { game_id: id, request_id: body.requestId, action: "ASSIGN_UNASSIGNED", assigned_count: body.assignments.length } } }); return;
    }
    if (path.endsWith("/rating-review")) { await route.fulfill({ json: { state: null } }); return; }
    const players = Array.from({ length: 14 }, (_, index) => ({
      id: index === 12 ? newWhite : index === 13 ? newBlack : `e1000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
      displayName: index === 12 ? "New White Player" : index === 13 ? "New Black Player" : `Existing player ${index + 1}`,
      username: null, avatarUrl: null, role: index >= 12 ? "ATT" : index % 6 === 0 ? "GK" : index % 6 < 3 ? "DEF" : "ATT", ratingAtTeamAssignment: 1200,
      clanId: index < 6 ? "WHITE" : index < 12 ? "BLACK" : saved ? index === 12 ? "WHITE" : "BLACK" : "UNASSIGNED",
    }));
    if (path === `/api/referee/admin/games/solo/${id}`) reads++;
    const fixture = { matchKind: "SOLO", id, status, operationalState, ratingPolicyId: "field-sr-season0-v2", capacity: 14,
      teamsAssignedAt: saved ? "2099-07-25T19:00:00Z" : null, players,
      venue: "Encanto Park · Pitch 1", day: "Saturday", timeSlot: "8:30 PM", matchDate: "2099-07-25",
      homeScore: null, awayScore: null, clock: started ? { status: "PAUSED", startedAt: "2099-07-25T20:30:00Z", accumulatedSeconds: 20 } : null, events: [],
      homeClan: { id: "WHITE", name: "White team", tag: "WHT", emblem: "W" }, awayClan: { id: "BLACK", name: "Black team", tag: "BLK", emblem: "B" } };
    await route.fulfill({ json: { detail: { fixture, currency: "USD", pricing: null, formation: null,
      participants: { matchKind: "SOLO", matchId: id, status, capacity: 14, capacityPerSide: 7,
        registeredPlayers: players.map(player => ({ ...player, profileId: player.id, side: player.clanId === "UNASSIGNED" ? null : player.clanId, checkedInAt: null })),
        actualPlayers: [], withdrawnPlayers: [], counts: { registered: 14, actual: 0, withdrawn: 0 } },
      reserves: { active: [], history: [] }, assignedReferee: null,
      ratingSummary: { kind: "SOLO", whiteAverageSr: 1200, blackAverageSr: 1200, matchAverageSr: 1200, teamSrSpread: 0, ratedPlayers: 0 },
      audit: [], reports: [], stoppages: [], resolutionCase: null,
    } } });
  });
  await page.goto(`/admin/games/solo/${id}`);
  await expect(page.getByText("Existing player 1", { exact: true })).toBeVisible();
  return { writes, get reads() { return reads; } };
}

test("admin overview places all new players without including existing teams in the write", async ({ page }, info) => {
  const calls = await mockGame(page);
  const panel = page.getByRole("region", { name: "Unassigned players", exact: true });
  await expect(panel.getByRole("combobox")).toHaveCount(2);
  const save = panel.getByRole("button", { name: "Save player assignments" });
  await expect(save).toBeDisabled();
  await panel.getByLabel("Team for New White Player").selectOption("WHITE");
  await expect(save).toBeDisabled();
  await expect(panel.getByLabel("Team for New Black Player").locator('option[value="WHITE"]')).toHaveAttribute("disabled", "");
  await panel.getByLabel("Team for New Black Player").selectOption("BLACK");
  await expect(panel.getByText("White 7 / 7 · Black 7 / 7.", { exact: false })).toBeVisible();
  await page.screenshot({ path: info.outputPath("admin-unassigned-placement.png"), fullPage: true });
  await save.click();
  await expect(panel).toHaveCount(0);
  await expect(page.getByRole("main").getByRole("status")).toContainText("Existing teams have been preserved");
  expect(calls.writes).toHaveLength(1);
  expect(calls.writes[0].assignments).toEqual([{ profileId: newWhite, team: "WHITE" }, { profileId: newBlack, team: "BLACK" }]);
  expect(calls.writes[0].requestId).toMatch(/^[0-9a-f-]{36}$/);
  expect(calls.reads).toBe(2);
});

test("an assignment conflict keeps the selections and retry ID", async ({ page }) => {
  const calls = await mockGame(page, { firstConflict: true });
  const panel = page.getByRole("region", { name: "Unassigned players", exact: true });
  await panel.getByLabel("Team for New White Player").selectOption("WHITE");
  await panel.getByLabel("Team for New Black Player").selectOption("BLACK");
  await panel.getByRole("button", { name: "Save player assignments" }).click();
  await expect(panel.getByRole("alert")).toContainText("already been assigned");
  await expect(panel.getByLabel("Team for New White Player")).toHaveValue("WHITE");
  await panel.getByRole("button", { name: "Save player assignments" }).click();
  await expect(panel).toHaveCount(0);
  expect(calls.writes).toHaveLength(2);
  expect(calls.writes[0].requestId).toBe(calls.writes[1].requestId);
});

for (const [label, options] of [["live", { status: "LIVE" }], ["already started", { started: true }]] as const) {
  test(`${label} games offer no unassigned player placement`, async ({ page }) => {
    const calls = await mockGame(page, options);
    await expect(page.getByRole("region", { name: "Unassigned players", exact: true })).toHaveCount(0);
    expect(calls.writes).toHaveLength(0);
  });
}

test("review locks placement while keeping the unassigned roster visible", async ({ page }) => {
  const calls = await mockGame(page, { operationalState: "UNDER_REVIEW" });
  const panel = page.getByRole("region", { name: "Unassigned players", exact: true });
  await expect(panel.getByLabel("Team for New White Player")).toBeDisabled();
  await expect(panel.getByRole("button", { name: "Save player assignments" })).toBeDisabled();
  expect(calls.writes).toHaveLength(0);
});
