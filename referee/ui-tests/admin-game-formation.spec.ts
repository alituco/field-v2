import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import type { AdminGameFormation } from "../src/lib/admin-game-formation";

const config = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? config.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname;
const id = "d1000000-0000-4000-8000-000000000001";
const reason = "More attacking places for the Saturday match.";

async function mockGame(page: Page, options: { locked?: boolean; conflict?: boolean } = {}) {
  const writes: Record<string, unknown>[] = [];
  let formation: AdminGameFormation = { goalkeepersPerSide: 1, defendersPerSide: 3, attackersPerSide: 3, canEdit: !options.locked, lockedReason: options.locked ? "Formation is locked after the first booking or payment attempt. Create a new game to use a different formation." : null };
  await page.addInitScript(({ key }) => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } } })), { key: `fieldrush-staff-${project}-auth-v1` });
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({ json: {} }));
  await page.route("**/api/referee/**", async (route) => {
    if (route.request().method() === "PATCH") {
      expect(new URL(route.request().url()).pathname).toBe(`/api/referee/admin/games/solo/${id}/formation`);
      const body = route.request().postDataJSON(); writes.push(body);
      if (options.conflict) { await route.fulfill({ status: 409, json: { error: "Formation is locked after the first booking or payment attempt." } }); return; }
      formation = { ...formation, ...body };
      await route.fulfill({ json: { formation } }); return;
    }
    const fixture = { matchKind: "SOLO", id, status: "OPEN", operationalState: "NORMAL", venue: "Encanto Park · Pitch 1", day: "Saturday", timeSlot: "8:30 PM", matchDate: "2099-07-25", homeScore: null, awayScore: null, clock: null, events: [], homeClan: { id: "white", name: "White team", tag: "WHT", emblem: "W" }, awayClan: { id: "black", name: "Black team", tag: "BLK", emblem: "B" } };
    await route.fulfill({ json: { detail: { fixture, currency: "USD", pricing: null, formation,
      participants: { matchKind: "SOLO", matchId: id, status: "OPEN", capacity: 14, capacityPerSide: 7, registeredPlayers: [], actualPlayers: [], withdrawnPlayers: [], counts: { registered: 0, actual: 0, withdrawn: 0 } }, reserves: { active: [], history: [] }, assignedReferee: null,
      ratingSummary: { kind: "SOLO", whiteAverageSr: null, blackAverageSr: null, matchAverageSr: null, teamSrSpread: null, ratedPlayers: 0 }, audit: [], reports: [], stoppages: [], resolutionCase: null,
    } } });
  });
  await page.goto(`/admin/games/solo/${id}`);
  return writes;
}

test("formation controls keep seven players, require an audit reason and refresh the game after saving", async ({ page }, info) => {
  const writes = await mockGame(page);
  const panel = page.getByRole("region", { name: "Team formation" });
  await expect(panel.getByText("1 keeper · 3 defenders · 3 attackers", { exact: false })).toBeVisible();
  await panel.getByRole("button", { name: "Edit formation" }).click();
  await expect(panel.getByLabel("Goalkeepers per team")).toBeDisabled();
  await panel.getByLabel("Defenders per team").selectOption("2");
  await expect(panel.getByLabel("Attackers per team")).toHaveValue("4");
  await expect(panel.getByRole("button", { name: "Save formation" })).toBeDisabled();
  await panel.getByLabel("Reason for the formation change").fill(reason);
  await page.screenshot({ path: info.outputPath("formation-editor.png"), fullPage: true });
  await panel.getByRole("button", { name: "Save formation" }).click();
  await expect(panel.getByText("1 keeper · 2 defenders · 4 attackers", { exact: false })).toBeVisible();
  await expect(panel.getByRole("form", { name: "Edit game formation" })).toHaveCount(0);
  expect(writes).toEqual([{ goalkeepersPerSide: 1, defendersPerSide: 2, attackersPerSide: 4, reason }]);
});

test("booked games show their saved formation and a clear locked explanation", async ({ page }) => {
  const writes = await mockGame(page, { locked: true });
  const panel = page.getByRole("region", { name: "Team formation" });
  await expect(panel.getByText(/locked after the first booking or payment attempt/)).toBeVisible();
  await expect(panel.getByRole("button", { name: "Edit formation" })).toHaveCount(0);
  expect(writes).toHaveLength(0);
});

test("a concurrent booking blocks save and retains the admin’s draft and reason", async ({ page }) => {
  const writes = await mockGame(page, { conflict: true });
  const panel = page.getByRole("region", { name: "Team formation" });
  await panel.getByRole("button", { name: "Edit formation" }).click();
  await panel.getByLabel("Attackers per team").selectOption("4");
  await expect(panel.getByLabel("Defenders per team")).toHaveValue("2");
  await panel.getByLabel("Reason for the formation change").fill(reason);
  await panel.getByRole("button", { name: "Save formation" }).click();
  await expect(panel.getByRole("alert")).toHaveText("Formation is locked after the first booking or payment attempt.");
  await expect(panel.getByLabel("Reason for the formation change")).toHaveValue(reason);
  await expect(panel.getByLabel("Attackers per team")).toHaveValue("4");
  expect(writes).toHaveLength(1);
});
