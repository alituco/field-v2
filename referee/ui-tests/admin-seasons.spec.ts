import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import type { AdminSeasonCatalog, AdminSeasonReward } from "../src/lib/admin-seasons";

const publicConfig = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const supabaseUrl = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? publicConfig.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co");
const project = supabaseUrl.hostname.split(".")[0];
const actor = "00000000-0000-4000-8000-000000000001";

async function mockAdmin(page: Page, failSave = false) {
  const writes: Array<{ path: string; body: Record<string, unknown> }> = [];
  const catalog: AdminSeasonCatalog = {
    today: "2026-10-13",
    seasons: [
      { id: "s0", label: "Season 0", startsOn: "2026-06-01", endsOn: "2026-09-30", minimumRatedGames: 2, revision: 1, editable: false, publishedRewardsLocked: true },
      { id: "s1", label: "Season 1", startsOn: "2026-10-01", endsOn: "2026-12-31", minimumRatedGames: 2, revision: 1, editable: false, publishedRewardsLocked: false },
      { id: "s2", label: "Season 2", startsOn: "2027-01-01", endsOn: "2027-03-31", minimumRatedGames: 2, revision: 1, editable: true, publishedRewardsLocked: false },
    ],
    cities: [
      { id: "phoenix", displayName: "Phoenix", state: "AZ", countryCode: "US", timezone: "America/Phoenix", active: true },
      { id: "new-york", displayName: "New York", state: "NY", countryCode: "US", timezone: "America/New_York", active: false },
    ],
    rewards: [], audit: [],
  };
  catalog.rewards = catalog.seasons.flatMap((season) => catalog.cities.flatMap((city) => (["OUTFIELD", "GOALKEEPER"] as const).map((track) => ({ seasonId: season.id, cityId: city.id, ratingTrack: track, currency: "USD" as const, firstPrizeCents: 15000, secondPrizeCents: 10000, thirdPrizeCents: 5000, status: season.id === "s0" ? "PUBLISHED" as const : "DRAFT" as const, revision: 1, publishedAt: season.id === "s0" ? "2026-06-01T00:00:00Z" : null }))));
  await page.addInitScript(({ key, actor }) => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: actor, aud: "authenticated" } })), { key: `sb-${project}-auth-token`, actor });
  await page.route(`${supabaseUrl.origin}/**`, (route) => route.fulfill({ status: 200, contentType: "application/json", body: "{}" }));
  await page.route("**/api/referee/**", async (route) => {
    const request = route.request(); const path = new URL(request.url()).pathname;
    let data: unknown = {}; let status = 200;
    if (request.method() !== "GET") {
      const body = request.postDataJSON(); writes.push({ path, body });
      if (failSave) { status = 409; data = { error: "These settings changed in another session. Refresh before saving again." }; }
      else if (path.includes("/rewards/")) {
        const parts = path.split("/"); const seasonId = parts[5]; const cityId = parts[7]; const track = parts[8];
        const previous = catalog.rewards.find((reward) => reward.seasonId === seasonId && reward.cityId === cityId && reward.ratingTrack === track)!;
        const updated: AdminSeasonReward = { ...previous, firstPrizeCents: Math.round(Number(body.firstPrizeUsd) * 100), secondPrizeCents: Math.round(Number(body.secondPrizeUsd) * 100), thirdPrizeCents: Math.round(Number(body.thirdPrizeUsd) * 100), status: body.action === "SAVE" ? "DRAFT" : "PUBLISHED", revision: previous.revision + 1, publishedAt: body.action === "SAVE" ? null : "2026-10-13T12:00:00Z" };
        catalog.rewards = catalog.rewards.map((reward) => reward === previous ? updated : reward);
        if (body.action !== "SAVE") catalog.seasons = catalog.seasons.map((season) => season.id === seasonId ? { ...season, editable: false, publishedRewardsLocked: true } : season);
        catalog.audit.unshift({ id: String(catalog.audit.length + 1), seasonId, cityId, ratingTrack: updated.ratingTrack, action: `REWARD_${body.action}`, actorAdminId: actor, reason: body.reason, createdAt: "2026-10-13T12:00:00Z", beforeState: { first_prize_cents: previous.firstPrizeCents, second_prize_cents: previous.secondPrizeCents, third_prize_cents: previous.thirdPrizeCents, status: previous.status }, afterState: { first_prize_cents: updated.firstPrizeCents, second_prize_cents: updated.secondPrizeCents, third_prize_cents: updated.thirdPrizeCents, status: updated.status } });
        data = { reward: updated };
      } else {
        const id = path.split("/").at(-1)!;
        const previous = catalog.seasons.find((season) => season.id === id);
        const updated = { id, label: body.label, startsOn: body.startsOn, endsOn: body.endsOn, minimumRatedGames: body.minimumRatedGames, revision: (previous?.revision ?? 0) + 1, editable: true, publishedRewardsLocked: false };
        catalog.seasons = [...catalog.seasons.filter((season) => season.id !== id), updated];
        data = { season: updated };
      }
    } else if (path.endsWith("/seasons")) data = catalog;
    else if (path === "/api/referee/fixtures") data = { me: { profileId: actor, displayName: "Preview Admin", role: "admin" }, fixtures: [] };
    else if (path.endsWith("/assignments")) data = { referees: [], fixtures: [] };
    else if (path.endsWith("/overview")) data = { metrics: {}, attention: [], audit: [] };
    else if (path.endsWith("/support")) data = { tickets: [], activeCount: 0 };
    else if (path.endsWith("/reports")) data = { reports: [] };
    else if (path.endsWith("/subjects")) data = { subjects: [] };
    else if (path.endsWith("/forfeits")) data = { forfeits: [] };
    else if (path.endsWith("/referees")) data = { staff: [] };
    await route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
  });
  return writes;
}

test("current city rewards save independently and publication locks the advertised amounts", async ({ page }, info) => {
  const writes = await mockAdmin(page); await page.goto("/admin/seasons");
  await expect(page.getByRole("combobox", { name: "Season", exact: true })).toHaveValue("s1");
  await expect(page.getByLabel("Rated games for prizes")).toBeDisabled();
  const outfield = page.getByRole("form", { name: "Outfield rewards" });
  const keeper = page.getByRole("form", { name: "Keeper rewards" });
  await outfield.getByLabel("Outfield first place USD").fill("200.15");
  await outfield.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "Reward draft saved" })).toBeVisible();
  expect(writes[0]).toEqual({ path: "/api/referee/admin/seasons/s1/rewards/phoenix/OUTFIELD", body: { firstPrizeUsd: "200.15", secondPrizeUsd: "100.00", thirdPrizeUsd: "50.00", action: "SAVE", reason: null, expectedRevision: 1 } });
  await expect(keeper.getByLabel("Keeper first place USD")).toHaveValue("150.00");
  await outfield.getByRole("button", { name: "Publish rewards" }).click();
  await expect(outfield.getByRole("heading", { name: "Publish $350.15 for Phoenix outfield?" })).toBeVisible();
  expect(writes).toHaveLength(1);
  await outfield.getByRole("button", { name: "Confirm and publish" }).click();
  await expect(outfield.getByLabel("Outfield first place USD")).toBeDisabled();
  await expect(outfield.getByRole("button", { name: "Correct published rewards" })).toBeVisible();
  await expect(keeper.getByRole("button", { name: "Publish rewards" })).toBeVisible();
  expect(writes[1].body.expectedRevision).toBe(2);
  await page.screenshot({ path: info.outputPath("seasons-rewards-desktop.png"), fullPage: true });
});

test("future season qualification is configurable before publishing and each city is separate", async ({ page }) => {
  const writes = await mockAdmin(page); await page.goto("/admin/seasons");
  await page.getByRole("combobox", { name: "Season", exact: true }).selectOption("s2");
  await page.getByLabel("Rated games for prizes").fill("4");
  await page.getByRole("button", { name: "Save season settings" }).click();
  await expect(page.getByText(/Players need 4 rated games/)).toBeVisible();
  expect(writes[0].body.minimumRatedGames).toBe(4);
  await page.getByRole("combobox", { name: "City", exact: true }).selectOption("new-york");
  const keeper = page.getByRole("form", { name: "Keeper rewards" });
  await keeper.getByLabel("Keeper first place USD").fill("75");
  await keeper.getByRole("button", { name: "Publish rewards" }).click();
  await expect(keeper.getByText(/locks the season dates and 4-game/)).toBeVisible();
  await keeper.getByRole("button", { name: "Confirm and publish" }).click();
  await expect(page.getByLabel("Rated games for prizes")).toBeDisabled();
  expect(writes[1].path).toBe("/api/referee/admin/seasons/s2/rewards/new-york/GOALKEEPER");
  await page.getByRole("combobox", { name: "City", exact: true }).selectOption("phoenix");
  await expect(keeper.getByLabel("Keeper first place USD")).toHaveValue("150.00");
  await expect(keeper.getByLabel("Keeper first place USD")).toBeEnabled();
});

test("published corrections require a reason and leave a visible before/after trail", async ({ page }) => {
  const writes = await mockAdmin(page); await page.goto("/admin/seasons");
  const outfield = page.getByRole("form", { name: "Outfield rewards" });
  await outfield.getByRole("button", { name: "Publish rewards" }).click(); await outfield.getByRole("button", { name: "Confirm and publish" }).click();
  await outfield.getByRole("button", { name: "Correct published rewards" }).click();
  await outfield.getByLabel("Outfield first place USD").fill("175");
  await outfield.getByRole("button", { name: "Save audited correction" }).click();
  expect(writes).toHaveLength(1);
  await outfield.getByLabel("Reason for published correction").fill("Correcting the approved first-place amount.");
  await outfield.getByRole("button", { name: "Save audited correction" }).click();
  await expect(page.getByText("Correcting the approved first-place amount.", { exact: false })).toBeVisible();
  expect(writes[1].body.action).toBe("CORRECT"); expect(writes[1].body.expectedRevision).toBe(2);
  await page.getByText("View before and after").first().click();
  await expect(page.getByText("$175 / $100 / $50 · published")).toBeVisible();
});

test("past seasons cannot be edited and mobile settings fit the viewport", async ({ page }, info) => {
  const writes = await mockAdmin(page); await page.setViewportSize({ width: 390, height: 844 }); await page.goto("/admin/seasons");
  await page.getByRole("combobox", { name: "Season", exact: true }).selectOption("s0");
  await expect(page.getByLabel("Outfield first place USD")).toBeDisabled();
  await expect(page.getByLabel("Keeper first place USD")).toBeDisabled();
  await expect(page.getByRole("button", { name: "Correct published rewards" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Publish rewards" })).toHaveCount(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: info.outputPath("seasons-rewards-mobile.png"), fullPage: true });
  expect(writes).toHaveLength(0);
});

test("save conflicts keep the entered amounts and never show a false success", async ({ page }) => {
  const writes = await mockAdmin(page, true); await page.goto("/admin/seasons");
  const outfield = page.getByRole("form", { name: "Outfield rewards" });
  await outfield.getByLabel("Outfield first place USD").fill("123.45");
  await outfield.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect(outfield.getByRole("alert")).toContainText("another session");
  await expect(outfield.getByLabel("Outfield first place USD")).toHaveValue("123.45");
  await expect(page.getByRole("status").filter({ hasText: "Reward draft saved" })).toHaveCount(0);
  expect(writes).toHaveLength(1);
});

test("new seasons start with two-game qualification and the next quarterly dates", async ({ page }) => {
  const writes = await mockAdmin(page); await page.goto("/admin/seasons");
  await page.getByRole("button", { name: "Add season" }).click();
  const editor = page.getByRole("form", { name: "New season" });
  await expect(editor.getByLabel("Starts on")).toHaveValue("2027-04-01"); await expect(editor.getByLabel("Ends on")).toHaveValue("2027-06-30");
  await editor.getByRole("button", { name: "Create season" }).click();
  await expect(page.getByRole("combobox", { name: "Season", exact: true })).toHaveValue("s3");
  expect(writes[0].body).toEqual({ label: "Season 3", startsOn: "2027-04-01", endsOn: "2027-06-30", minimumRatedGames: 2, expectedRevision: 0 });
});
