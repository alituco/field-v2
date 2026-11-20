import { expect, test, type Page } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import { loadAdminGameSettings } from "../src/lib/admin-game-detail";

const config = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? config.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname;
const gameId = "10000000-0000-4000-8000-000000000001";
const detailUrl = `/api/referee/admin/games/solo/${gameId}`;

async function openGame(page: Page, status = "FINAL", endsAt = "2020-01-01T12:00:00Z", supportsVisibility = true) {
  let fixturesHiddenAt: string | null = null;
  await page.addInitScript(key => localStorage.setItem(key, JSON.stringify({
    access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800,
    user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } },
  })), `fieldrush-staff-${project}-auth-v1`);
  await page.route("**/*.supabase.co/**", route => route.fulfill({ json: {} }));
  await page.route(`**${detailUrl}`, route => route.fulfill({ json: { detail: {
    ...(supportsVisibility ? { fixturesHiddenAt } : {}), currency: "USD", pricing: null, formation: null,
    fixture: {
      id: gameId, matchKind: "SOLO", venue: "Diablo", status, endsAt, matchDate: endsAt.slice(0, 10), events: [],
      homeClan: { name: "White", tag: "WHT" }, awayClan: { name: "Black", tag: "BLK" },
    },
    participants: { matchKind: "SOLO", capacity: 14, capacityPerSide: 7, registeredPlayers: [], actualPlayers: [], withdrawnPlayers: [], counts: { registered: 0, actual: 0, withdrawn: 0 } },
    reserves: { active: [], history: [] }, ratingSummary: { kind: "SOLO" },
    assignedReferee: null, resolutionCase: null, audit: [], reports: [], stoppages: [],
  } } }));
  await page.route(`**${detailUrl}/fixture-visibility`, route => {
    expect(route.request().method()).toBe("PATCH");
    expect(route.request().headers().authorization).toBe("Bearer ui-test-token");
    const { hidden } = route.request().postDataJSON();
    expect(typeof hidden).toBe("boolean");
    fixturesHiddenAt = hidden ? new Date().toISOString() : null;
    return route.fulfill({ json: { fixturesHiddenAt } });
  });
  await page.goto(`/admin/games/solo/${gameId}`);
  await expect(page.getByRole("heading", { name: "Game state" })).toBeVisible();
}

test("a pre-migration schema keeps game currency and disables the visibility control", async ({ page }) => {
  const selects: string[] = [];
  const db = createClient("http://127.0.0.1:54321", "test-key", { global: { fetch: async input => {
    const url = new URL(input instanceof Request ? input.url : input);
    selects.push(url.searchParams.get("select") ?? "");
    if (selects.length === 1) {
      return Response.json({
        code: "PGRST200",
        message: "Could not find a relationship between 'open_queue_games' and 'solo_fixture_visibility' in the schema cache",
      }, { status: 400 });
    }
    return Response.json({ currency: "BHD" });
  } } });
  expect(await loadAdminGameSettings(db, "SOLO", gameId)).toEqual({ currency: "BHD" });
  expect(selects).toEqual(["currency,solo_fixture_visibility(hidden_at)", "currency"]);
  await openGame(page, "FINAL", "2020-01-01T12:00:00Z", false);
  await expect(page.getByRole("button", { name: "Hide from Fixtures" })).toHaveCount(0);
  await expect(page.getByText("Player Fixtures page")).toHaveCount(0);
});

test("unrelated database errors stay visible without retrying the settings read", async () => {
  for (const error of [
    { code: "PGRST200", message: "Could not find a relationship to 'other_table'" },
    { code: "42501", message: "Permission denied for 'solo_fixture_visibility'" },
  ]) {
    let requests = 0;
    const db = createClient("http://127.0.0.1:54321", "test-key", { global: { fetch: async () => {
      requests++;
      return Response.json(error, { status: 400 });
    } } });
    await expect(loadAdminGameSettings(db, "SOLO", gameId)).rejects.toThrow(error.message);
    expect(requests).toBe(1);
  }
});

test("a past game can be hidden, reopened in admin, and restored", async ({ page }) => {
  await openGame(page);
  await page.getByRole("button", { name: "Hide from Fixtures" }).click();
  await expect(page.getByRole("main").getByRole("status")).toContainText("Game hidden from Fixtures.");
  await page.reload();
  await expect(page.getByText("Hidden", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Show on Fixtures" }).click();
  await expect(page.getByRole("main").getByRole("status")).toContainText("Game restored to Fixtures.");
  await expect(page.getByRole("button", { name: "Hide from Fixtures" })).toBeEnabled();
});

test("a rejected change leaves the game visible and allows retry", async ({ page }) => {
  await openGame(page);
  await page.route(`**${detailUrl}/fixture-visibility`, route => route.fulfill({ status: 409, json: { error: "Game is still live." } }));
  await page.getByRole("button", { name: "Hide from Fixtures" }).click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText("Game is still live.");
  await expect(page.getByRole("button", { name: "Hide from Fixtures" })).toBeEnabled();
});

for (const [status, endsAt] of [["OPEN", "2099-01-01T12:00:00Z"], ["LIVE", "2020-01-01T12:00:00Z"]]) {
  test(`${status} game is protected while upcoming or live`, async ({ page }) => {
    await openGame(page, status, endsAt);
    await expect(page.getByRole("button", { name: "Hide from Fixtures" })).toHaveCount(0);
  });
}
