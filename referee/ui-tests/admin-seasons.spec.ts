import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import type { AdminSeason, AdminSeasonCatalog, AdminSeasonReward } from "../src/lib/admin-seasons";

const publicConfig = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const supabaseUrl = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? publicConfig.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co");
const project = supabaseUrl.hostname;
const actor = "00000000-0000-4000-8000-000000000001";

function makeSeason(values: Partial<AdminSeason> & Pick<AdminSeason, "id" | "label" | "startsOn" | "endsOn">): AdminSeason {
  return { minimumRatedGames: 2, revision: 1, editable: true, publishedRewardsLocked: false, lifecycle: "DRAFT", visible: false, canHide: true, canChangeEnd: true, transitionState: "READY", blockedReason: null,
    gamesPlayed: 0, rankedPlayers: 0, placementPlayers: 0, unfinishedGames: 0, liveGames: 0, publishedPrizeCents: 0, readiness: [], ...values };
}

async function mockAdmin(page: Page, failSave = false, liveGames = 0) {
  const writes: Array<{ path: string; body: Record<string, unknown> }> = [];
  const previews: Array<{ path: string; body: Record<string, unknown> }> = [];
  let policy = { enabled: false, changed_at: "2026-10-14T12:00:00Z", changed_by: actor };
  const catalog: AdminSeasonCatalog = {
    today: "2026-10-13", currentSeasonId: "s1",
    seasons: [
      makeSeason({ id: "s0", label: "Season 0", startsOn: "2026-06-01", endsOn: "2026-09-30", editable: false, publishedRewardsLocked: true, lifecycle: "ENDED", visible: true, canChangeEnd: false }),
      makeSeason({ id: "s1", label: "Season 1", startsOn: "2026-10-01", endsOn: "2026-12-31", editable: false, lifecycle: "ACTIVE", visible: true, canHide: false, unfinishedGames: 1, liveGames, gamesPlayed: 12, rankedPlayers: 18, placementPlayers: 4, readiness: [{ code: "missing-rewards", message: "Phoenix keeper rewards are unpublished.", blocking: false }] }),
      makeSeason({ id: "s2", label: "Season 2", startsOn: "2027-01-01", endsOn: "2027-03-31", lifecycle: "SCHEDULED", visible: true }),
    ],
    cities: [
      { id: "phoenix", displayName: "Phoenix", state: "AZ", countryCode: "US", timezone: "America/Phoenix", active: true },
      { id: "new-york", displayName: "New York", state: "NY", countryCode: "US", timezone: "America/New_York", active: false },
    ],
    rewards: [], audit: [],
  };
  catalog.rewards = catalog.seasons.flatMap((season) => catalog.cities.flatMap((city) => (["OUTFIELD", "GOALKEEPER"] as const).map((track) => ({ seasonId: season.id, cityId: city.id, ratingTrack: track, currency: "USD" as const, firstPrizeCents: 15000, secondPrizeCents: 10000, thirdPrizeCents: 5000, status: season.id === "s0" ? "PUBLISHED" as const : "DRAFT" as const, revision: 1, publishedAt: season.id === "s0" ? "2026-06-01T00:00:00Z" : null }))));
  await page.addInitScript(({ key, actor }) => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: actor, aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } } })), { key: `fieldrush-staff-${project}-auth-v1`, actor });
  await page.route(`${supabaseUrl.origin}/**`, (route) => route.fulfill({ status: 200, contentType: "application/json", body: "{}" }));
  await page.route("**/api/referee/**", async (route) => {
    const request = route.request(); const path = new URL(request.url()).pathname;
    let data: unknown = {}; let status = 200;
    if (request.method() !== "GET") {
      const body = request.postDataJSON();
      if (path.endsWith("/rating-policy")) {
        writes.push({ path, body });
        if (failSave) { status = 409; data = { error: "Policy changed in another session. Refresh before saving." }; }
        else { policy = { ...policy, enabled: body.enabled }; data = { policy }; }
      } else if (path.endsWith("/transition/preview")) {
        previews.push({ path, body }); const currentSeason = catalog.seasons.find((item) => item.id === body.currentSeasonId)!; const nextSeason = catalog.seasons.find((item) => item.id === body.nextSeasonId)!;
        const end = new Date(`${body.startsOn}T12:00:00Z`); end.setUTCDate(end.getUTCDate() - 1);
        data = { preview: { currentSeason, nextSeason, startsOn: body.startsOn, endsOn: end.toISOString().slice(0, 10), liveGames: liveGames ? [{ id: "live", venue: "Diablo", kind: "SOLO", status: "LIVE" }] : [], unfinishedGames: [{ id: "missing", venue: "Reach 11", kind: "SOLO", status: "NO_DATA" }], affectedFutureGames: [{ id: "future", venue: "Diablo", kind: "SOLO", status: "OPEN" }], canSchedule: liveGames === 0, blockers: liveGames ? ["Finish the live game before scheduling this transition."] : [] } };
      } else if (path.endsWith("/end-preview")) {
        previews.push({ path, body }); const currentSeason = catalog.seasons.find((item) => item.id === path.split("/")[5])!;
        data = { preview: { currentSeason, endsOn: body.endsOn, liveGames: [], unfinishedGames: [{ id: "missing", venue: "Reach 11", status: "NO_DATA", kind: "SOLO" }], affectedFutureGames: [{ id: "future", venue: "Diablo", status: "OPEN", kind: "SOLO" }], canSave: true, blockers: [] } };
      } else if (failSave) { writes.push({ path, body }); status = 409; data = { error: "These settings changed in another session. Refresh before saving again." }; }
      else if (path.includes("/rewards/")) {
        writes.push({ path, body });
        const parts = path.split("/"); const seasonId = parts[5]; const cityId = parts[7]; const track = parts[8];
        const previous = catalog.rewards.find((reward) => reward.seasonId === seasonId && reward.cityId === cityId && reward.ratingTrack === track)!;
        const updated: AdminSeasonReward = { ...previous, firstPrizeCents: Math.round(Number(body.firstPrizeUsd) * 100), secondPrizeCents: Math.round(Number(body.secondPrizeUsd) * 100), thirdPrizeCents: Math.round(Number(body.thirdPrizeUsd) * 100), status: body.action === "SAVE" ? "DRAFT" : "PUBLISHED", revision: previous.revision + 1, publishedAt: body.action === "SAVE" ? null : "2026-10-13T12:00:00Z" };
        catalog.rewards = catalog.rewards.map((reward) => reward === previous ? updated : reward);
        if (body.action !== "SAVE") catalog.seasons = catalog.seasons.map((season) => season.id === seasonId ? { ...season, editable: false, publishedRewardsLocked: true } : season);
        catalog.audit.unshift({ id: String(catalog.audit.length + 1), seasonId, cityId, ratingTrack: updated.ratingTrack, action: `REWARD_${body.action}`, actorAdminId: actor, reason: body.reason, createdAt: "2026-10-13T12:00:00Z", beforeState: { first_prize_cents: previous.firstPrizeCents, second_prize_cents: previous.secondPrizeCents, third_prize_cents: previous.thirdPrizeCents, status: previous.status }, afterState: { first_prize_cents: updated.firstPrizeCents, second_prize_cents: updated.secondPrizeCents, third_prize_cents: updated.thirdPrizeCents, status: updated.status } });
        data = { reward: updated };
      } else if (path.endsWith("/actions")) {
        writes.push({ path, body }); const id = path.split("/")[5]; const previous = catalog.seasons.find((item) => item.id === id)!;
        const updated = { ...previous, revision: previous.revision + 1,
          ...(body.action === "RENAME" ? { label: body.label } : body.action === "VISIBILITY" ? { visible: body.visible } : body.action === "SCHEDULE" ? { lifecycle: "SCHEDULED" as const, visible: true } : body.action === "MAKE_DRAFT" ? { lifecycle: "DRAFT" as const, visible: false } : { endsOn: body.endsOn }) };
        catalog.seasons = catalog.seasons.map((item) => item.id === id ? updated : item);
        catalog.audit.unshift({ id: String(catalog.audit.length + 1), seasonId: id, cityId: null, ratingTrack: null, action: body.action, actorAdminId: actor, reason: body.reason ?? null, createdAt: "2026-10-13T12:00:00Z", beforeState: { label: previous.label, starts_on: previous.startsOn, ends_on: previous.endsOn, minimum_rated_games: previous.minimumRatedGames, visible_to_players: previous.visible }, afterState: { label: updated.label, starts_on: updated.startsOn, ends_on: updated.endsOn, minimum_rated_games: updated.minimumRatedGames, visible_to_players: updated.visible } }); data = { season: updated };
      } else if (path.endsWith("/duplicate")) {
        writes.push({ path, body }); const sourceId = path.split("/")[5]; const duplicated = makeSeason({ id: body.id, label: body.label, startsOn: body.startsOn, endsOn: body.endsOn, minimumRatedGames: body.minimumRatedGames });
        catalog.seasons.push(duplicated); catalog.rewards.push(...catalog.rewards.filter((reward) => reward.seasonId === sourceId).map((reward) => ({ ...reward, seasonId: body.id, status: "DRAFT" as const, publishedAt: null, revision: 1 }))); data = { season: duplicated };
      } else if (path.endsWith("/transition")) {
        writes.push({ path, body }); const end = new Date(`${body.startsOn}T12:00:00Z`); end.setUTCDate(end.getUTCDate() - 1);
        catalog.seasons = catalog.seasons.map((item) => item.id === body.currentSeasonId ? { ...item, endsOn: end.toISOString().slice(0, 10), revision: item.revision + 1 } : item.id === body.nextSeasonId ? { ...item, startsOn: body.startsOn, lifecycle: "SCHEDULED", revision: item.revision + 1 } : item); data = { scheduled: true };
      } else {
        writes.push({ path, body });
        const id = path.split("/").at(-1)!;
        const previous = catalog.seasons.find((season) => season.id === id);
        const updated = makeSeason({ ...previous, id, label: body.label, startsOn: body.startsOn, endsOn: body.endsOn, minimumRatedGames: body.minimumRatedGames, revision: (previous?.revision ?? 0) + 1 });
        catalog.seasons = [...catalog.seasons.filter((season) => season.id !== id), updated];
        data = { season: updated };
      }
    } else if (path.endsWith("/rating-policy")) data = { policy };
    else if (path.endsWith("/seasons")) data = catalog;
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
  return { writes, previews, catalog };
}

test("prospective rating policy requires explicit scope confirmation and an audit reason", async ({ page }) => {
  const { writes } = await mockAdmin(page);
  await page.goto("/admin/seasons");
  const panel = page.getByRole("region", { name: "Solo rating policy" });
  await expect(panel.getByText("Legacy for new games", { exact: true })).toBeVisible();
  await panel.getByRole("button", { name: "Enable Season 0 v2 for future games" }).click();
  await expect(panel.getByText(/This switch does not control signup/)).toContainText("even while this switch is off");
  await panel.getByLabel("Rating policy change reason").fill("Referee workflow verified for future games.");
  await expect(panel.getByRole("button", { name: "Confirm policy change" })).toBeDisabled();
  await panel.getByRole("button", { name: "Cancel", exact: true }).click();
  expect(writes).toHaveLength(0);
  await panel.getByRole("button", { name: "Enable Season 0 v2 for future games" }).click();
  await panel.getByLabel(/I have reviewed the new-game scope/).check();
  await panel.getByRole("button", { name: "Confirm policy change" }).click();
  await expect(panel.getByText("Season 0 v2 enabled", { exact: true })).toBeVisible();
  await expect(panel.getByRole("status")).toHaveText(/Existing games and earned ratings are unchanged/);
  expect(writes).toEqual([{ path: "/api/referee/admin/rating-policy", body: { enabled: true, confirmed: true, reason: "Referee workflow verified for future games." } }]);
  await expect(panel.getByRole("button", { name: "Use legacy policy for future games" })).toBeVisible();
});

test("failed prospective policy write preserves the reason and does not claim activation", async ({ page }) => {
  const { writes } = await mockAdmin(page, true);
  await page.goto("/admin/seasons");
  const panel = page.getByRole("region", { name: "Solo rating policy" });
  await panel.getByRole("button", { name: "Enable Season 0 v2 for future games" }).click();
  await panel.getByLabel("Rating policy change reason").fill("Verified the new referee tools.");
  await panel.getByLabel(/I have reviewed the new-game scope/).check();
  await panel.getByRole("button", { name: "Confirm policy change" }).click();
  await expect(panel.getByRole("alert")).toHaveText(/Policy changed in another session/);
  await expect(panel.getByLabel("Rating policy change reason")).toHaveValue("Verified the new referee tools.");
  await expect(panel.getByText("Legacy for new games", { exact: true })).toBeVisible();
  expect(writes).toHaveLength(1);
});

test("current city rewards save independently and publication locks the advertised amounts", async ({ page }, info) => {
  const { writes } = await mockAdmin(page); await page.goto("/admin/seasons");
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
  const { writes } = await mockAdmin(page); await page.goto("/admin/seasons");
  await page.getByRole("combobox", { name: "Season", exact: true }).selectOption("s2");
  await page.getByLabel("Rated games for prizes").fill("4");
  await page.getByRole("button", { name: "Save season settings" }).click();
  await expect(page.getByText(/Players need 4 rated games/)).toBeVisible();
  expect(writes[0].body.minimumRatedGames).toBe(4);
  await page.getByRole("combobox", { name: "City", exact: true }).selectOption("new-york");
  const keeper = page.getByRole("form", { name: "Keeper rewards" });
  await keeper.getByLabel("Keeper first place USD").fill("75");
  await keeper.getByRole("button", { name: "Publish rewards" }).click();
  await expect(keeper.getByText(/locks the season start date and 4-game/)).toBeVisible();
  await keeper.getByRole("button", { name: "Confirm and publish" }).click();
  await expect(page.getByLabel("Rated games for prizes")).toBeDisabled();
  expect(writes[1].path).toBe("/api/referee/admin/seasons/s2/rewards/new-york/GOALKEEPER");
  await page.getByRole("combobox", { name: "City", exact: true }).selectOption("phoenix");
  await expect(keeper.getByLabel("Keeper first place USD")).toHaveValue("150.00");
  await expect(keeper.getByLabel("Keeper first place USD")).toBeEnabled();
});

test("published corrections require a reason and leave a visible before/after trail", async ({ page }) => {
  const { writes } = await mockAdmin(page); await page.goto("/admin/seasons");
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
  const { writes } = await mockAdmin(page); await page.setViewportSize({ width: 390, height: 844 }); await page.goto("/admin/seasons");
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
  const { writes } = await mockAdmin(page, true); await page.goto("/admin/seasons");
  const outfield = page.getByRole("form", { name: "Outfield rewards" });
  await outfield.getByLabel("Outfield first place USD").fill("123.45");
  await outfield.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect(outfield.getByRole("alert")).toContainText("another session");
  await expect(outfield.getByLabel("Outfield first place USD")).toHaveValue("123.45");
  await expect(page.getByRole("status").filter({ hasText: "Reward draft saved" })).toHaveCount(0);
  expect(writes).toHaveLength(1);
});

test("new season drafts use the current season end and duration without jumping to the last seeded season", async ({ page }) => {
  const { writes } = await mockAdmin(page); await page.goto("/admin/seasons");
  await page.getByRole("button", { name: "Add season" }).click();
  const editor = page.getByRole("form", { name: "New season" });
  await expect(editor.getByLabel("Starts on")).toHaveValue("2027-01-01"); await expect(editor.getByLabel("Ends on")).toHaveValue("2027-04-02");
  await editor.getByRole("button", { name: "Create season" }).click();
  await expect(page.getByRole("combobox", { name: "Season", exact: true })).toHaveValue("s3");
  expect(writes[0].body).toEqual({ label: "Season 2", startsOn: "2027-01-01", endsOn: "2027-04-02", minimumRatedGames: 2, expectedRevision: 0 });
  await expect(page.getByRole("button", { name: "Schedule season", exact: true })).toBeVisible();
});

test("current seasons can be renamed and past seasons hidden/restored without deleting history", async ({ page }) => {
  const { writes } = await mockAdmin(page); await page.goto("/admin/seasons");
  await expect(page.getByRole("button", { name: "Hide from players" })).toBeDisabled();
  await page.getByLabel("Season display name").fill("Phoenix Beta"); await page.getByRole("button", { name: "Save name" }).click();
  await expect(page.getByRole("heading", { name: "Phoenix Beta", exact: true })).toBeVisible();
  await expect(page.getByLabel("Rated games for prizes")).toBeDisabled();
  expect(writes[0]).toEqual({ path: "/api/referee/admin/seasons/s1/actions", body: { action: "RENAME", label: "Phoenix Beta", expectedRevision: 1 } });
  await page.getByRole("combobox", { name: "Season", exact: true }).selectOption("s0");
  await page.getByRole("button", { name: "Hide from players" }).click(); await expect(page.getByText("Hidden from players", { exact: true })).toBeVisible();
  await expect(page.getByRole("status").filter({ hasText: "Match history remains available" })).toBeVisible();
  await page.getByRole("button", { name: "Show to players" }).click(); await expect(page.getByText("Visible to players", { exact: true })).toBeVisible();
  expect(writes[1].body).toEqual({ action: "VISIBILITY", visible: false, expectedRevision: 1 }); expect(writes[2].body).toEqual({ action: "VISIBILITY", visible: true, expectedRevision: 2 });
  await page.getByLabel("Season display name").fill("Preseason"); await page.getByRole("button", { name: "Save name" }).click();
  await expect(page.getByRole("heading", { name: "Preseason", exact: true })).toBeVisible();
  await expect(page.getByLabel("Outfield first place USD")).toBeDisabled();
});

test("duplicate copies saved rewards into a hidden draft and can be scheduled", async ({ page }) => {
  const { writes } = await mockAdmin(page); await page.goto("/admin/seasons");
  const outfield = page.getByRole("form", { name: "Outfield rewards" }); await outfield.getByLabel("Outfield first place USD").fill("225"); await outfield.getByRole("button", { name: "Save draft", exact: true }).click();
  await page.getByRole("button", { name: "Duplicate season", exact: true }).click(); const editor = page.getByRole("form", { name: "New season" });
  await expect(editor.getByLabel("Starts on")).toHaveValue("2027-01-01"); await editor.getByLabel("Season name").fill("Spring Beta"); await editor.getByRole("button", { name: "Create duplicate draft" }).click();
  await expect(page.getByRole("combobox", { name: "Season", exact: true })).toHaveValue("s3"); await expect(page.getByText("Hidden from players", { exact: true })).toBeVisible();
  await expect(page.getByLabel("Outfield first place USD")).toHaveValue("225.00"); await expect(outfield.getByRole("button", { name: "Publish rewards" })).toBeVisible();
  expect(writes[1].path).toBe("/api/referee/admin/seasons/s1/duplicate"); expect(writes[1].body.expectedSourceRevision).toBe(1);
  await page.getByRole("button", { name: "Schedule season", exact: true }).click(); await expect(page.getByRole("status").filter({ hasText: "Season start scheduled" })).toBeVisible();
  expect(writes[2].body).toEqual({ action: "SCHEDULE", expectedRevision: 1 });
});

test("end-date changes show authoritative impact before recording the confirmation reason", async ({ page }) => {
  const { writes, previews } = await mockAdmin(page); await page.goto("/admin/seasons");
  await page.getByRole("button", { name: "Change end date" }).click(); const form = page.getByRole("form", { name: "Change season end date" });
  await form.getByLabel("New end date").fill("2026-12-30"); await form.getByLabel("Reason for end-date change").fill("Correcting the final day of the beta season.");
  await form.getByRole("button", { name: "Review date change" }).click(); await expect(form.getByText("Dec 31, 2026 → Dec 30, 2026")).toBeVisible();
  expect(writes).toHaveLength(0); expect(previews[0].body).toEqual({ endsOn: "2026-12-30" });
  await form.getByText("View games affected by the end date").click(); await expect(form.getByText("Diablo · OPEN")).toBeVisible();
  await form.getByRole("button", { name: "Confirm end-date change" }).click(); await expect(page.getByRole("status").filter({ hasText: "Season end date updated" })).toBeVisible();
  expect(writes[0].body).toEqual({ action: "END_DATE", endsOn: "2026-12-30", reason: "Correcting the final day of the beta season.", expectedRevision: 1 });
});

test("early season transition previews late/future games and requires reason plus both revisions", async ({ page }) => {
  const { writes, previews } = await mockAdmin(page); await page.goto("/admin/seasons");
  await page.getByRole("button", { name: "End current / Start next" }).click(); const planner = page.getByRole("form", { name: "Season transition" });
  await expect(planner.getByLabel("Next season starts on")).toHaveValue("2026-10-14"); await planner.getByRole("button", { name: "Review transition" }).click();
  await expect(planner.getByRole("heading", { name: "Review the transition" })).toBeVisible(); await expect(planner.getByText(/Late results remain in their original season/)).toBeVisible();
  expect(writes).toHaveLength(0); expect(previews[0].body).toEqual({ currentSeasonId: "s1", nextSeasonId: "s2", startsOn: "2026-10-14" });
  await planner.getByRole("button", { name: "Confirm and schedule transition" }).click(); expect(writes).toHaveLength(0);
  await planner.getByLabel("Reason for season transition").fill("Ending beta season one and starting the next competition."); await planner.getByRole("button", { name: "Confirm and schedule transition" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Season transition scheduled for midnight Phoenix time" })).toBeVisible();
  expect(writes[0].body).toEqual({ currentSeasonId: "s1", nextSeasonId: "s2", startsOn: "2026-10-14", reason: "Ending beta season one and starting the next competition.", expectedCurrentRevision: 1, expectedNextRevision: 1 });
});

test("live game blockers prevent transition confirmation", async ({ page }) => {
  const { writes } = await mockAdmin(page, false, 1); await page.goto("/admin/seasons"); await page.getByRole("button", { name: "End current / Start next" }).click();
  const planner = page.getByRole("form", { name: "Season transition" }); await planner.getByRole("button", { name: "Review transition" }).click();
  await expect(planner.getByRole("alert")).toContainText("Finish the live game"); await expect(planner.getByRole("button", { name: "Confirm and schedule transition" })).toBeDisabled(); expect(writes).toHaveLength(0);
});

test("player preview distinguishes saved draft rewards and stays compact on mobile", async ({ page }, info) => {
  const { writes } = await mockAdmin(page); await page.setViewportSize({ width: 390, height: 844 }); await page.goto("/admin/seasons");
  await page.getByRole("button", { name: "Player preview", exact: true }).click(); const preview = page.getByRole("region", { name: "Player preview" });
  await expect(preview.getByText(/Standings are not shown here/)).toBeVisible(); await expect(preview.getByText("Saved draft", { exact: true })).toHaveCount(2);
  await expect(preview.getByText("$150", { exact: true })).toHaveCount(2);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: info.outputPath("season-management-mobile-preview.png"), fullPage: true });
  expect(writes).toHaveLength(0);
  await page.getByRole("combobox", { name: "Season", exact: true }).selectOption("s2"); await page.getByRole("button", { name: "Player preview", exact: true }).click(); await expect(preview.getByText("Available after start")).toBeVisible();
});
