import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import type { AdminGameSchedule } from "../src/lib/admin-game-schedules";

const publicConfig = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? publicConfig.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname.split(".")[0];
const sampleField = { id: "f1000000-0000-4000-8000-000000000001", name: "Encanto Park · Pitch 1", address: "2605 N 15th Ave", city: "Phoenix", state: "AZ", countryCode: "US", marketCityId: "phoenix", marketCityName: "Phoenix", marketTimezone: "America/Phoenix", marketActive: true, latitude: 33.477, longitude: -112.093, isActive: true, createdAt: "2026-10-11T00:00:00Z", updatedAt: "2026-10-11T00:00:00Z" };
const sampleSchedule: AdminGameSchedule = { id: "c1000000-0000-4000-8000-000000000001", name: "Saturday football", fieldId: sampleField.id, fieldName: sampleField.name, weekdays: [6], kickoffTime: "20:30", durationMinutes: 60, startsOn: "2026-10-10", endsOn: null, bookingWindowDays: 28, priceUsd: "13.00", ageLabel: "18+", highestDivision: 1, lowestDivision: 5, isActive: true, timezone: "America/Phoenix", createdAt: "2026-10-11T00:00:00Z", updatedAt: "2026-10-11T00:00:00Z", occurrences: [], skips: [] };

async function mockAdmin(page: Page, options: { fields?: typeof sampleField[]; schedules?: AdminGameSchedule[]; loadError?: boolean; saveError?: boolean; skipError?: boolean } = {}) {
  const writes: { path: string; method: string; body: Record<string, unknown> }[] = [];
  let fields = options.fields ?? [sampleField];
  let schedules = options.schedules ?? [];
  await page.addInitScript(({ key }) => {
    localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated" } }));
  }, { key: `sb-${project}-auth-token` });
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({ status: 200, contentType: "application/json", body: "{}" }));
  await page.route("**/api/referee/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let data: unknown = {};
    let status = 200;
    if (request.method() !== "GET") {
      const body = request.postDataJSON();
      writes.push({ path, method: request.method(), body });
      if (path === "/api/referee/admin/fields") {
        const field = { ...sampleField, ...body, id: "f1000000-0000-4000-8000-000000000002" };
        fields = [...fields, field]; data = { field }; status = 201;
      } else if (path.endsWith("/generate")) data = { created: 1, conflicts: 0, skipped: 1 };
      else if (path.endsWith("/skip")) {
        if (options.skipError) { status = 400; data = { error: "Choose a date that belongs to this schedule." }; }
        else {
          schedules = schedules.map((schedule) => ({ ...schedule, skips: body.skip ? [...schedule.skips, { matchDate: String(body.matchDate), reason: String(body.reason) }] : schedule.skips.filter((skip) => skip.matchDate !== body.matchDate) }));
          data = { schedule: schedules[0] };
        }
      } else if (path.startsWith("/api/referee/admin/game-schedules")) {
        if (options.saveError) { status = 400; data = { error: "The selected field is archived. Choose another field." }; }
        else if (request.method() === "POST") { const schedule = { ...sampleSchedule, ...body } as AdminGameSchedule; schedules = [...schedules, schedule]; data = { schedule }; status = 201; }
        else { schedules = schedules.map((schedule) => ({ ...schedule, ...body })); data = { schedule: schedules[0] }; }
      }
    } else if (path === "/api/referee/admin/game-schedules") {
      status = options.loadError ? 503 : 200;
      data = options.loadError ? { error: "The game-schedules database update is not installed yet." } : { schedules, fields };
    } else if (path === "/api/referee/admin/fields") data = { fields };
    else if (path === "/api/referee/admin/cities") data = { cities: [{ id: "phoenix", displayName: "Phoenix", state: "AZ", countryCode: "US", timezone: "America/Phoenix", active: true }] };
    else if (path === "/api/referee/fixtures") data = { me: { profileId: "00000000-0000-4000-8000-000000000001", displayName: "Preview Admin", role: "admin" }, fixtures: [] };
    else if (path === "/api/referee/assignments") data = { referees: [], fixtures: [] };
    else if (path === "/api/referee/admin/overview") data = { metrics: {}, attention: [], audit: [] };
    else if (path === "/api/referee/admin/support") data = { tickets: [], activeCount: 0 };
    else if (path === "/api/referee/admin/reports") data = { reports: [] };
    else if (path === "/api/referee/admin/subjects") data = { subjects: [] };
    else if (path === "/api/referee/admin/forfeits") data = { forfeits: [] };
    else if (path === "/api/referee/referees") data = { staff: [] };
    else if (path === "/api/referee/admin/game-payment-settings") data = { settings: { soloPriceFils: 13000, clanPriceFils: 80000, clanGamesEnabled: false } };
    await route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
  });
  return writes;
}

async function startSchedule(page: Page) {
  await page.goto("/admin?section=schedules");
  await page.getByRole("button", { name: "Add schedule" }).click();
  await page.getByLabel("Field / pitch", { exact: true }).selectOption(sampleField.id);
}

test("Saturday schedule defaults are clear and additional days are sent explicitly", async ({ page }, info) => {
  const writes = await mockAdmin(page);
  await startSchedule(page);
  await expect(page.getByRole("checkbox", { name: "Saturday", exact: true })).toBeChecked();
  await expect(page.getByLabel("Kickoff time", { exact: true })).toHaveValue("20:30");
  await expect(page.getByLabel("Game duration (minutes)", { exact: true })).toHaveValue("60");
  await expect(page.getByLabel("Booking window (days ahead)", { exact: true })).toHaveValue("28");
  await expect(page.getByLabel("Price per player (USD)", { exact: true })).toHaveValue("13.00");
  await expect(page.getByLabel("Highest division", { exact: true })).toHaveValue("1");
  await expect(page.getByLabel("Lowest division", { exact: true })).toHaveValue("5");
  await expect(page.getByText("The booked position determines the rating used. Placement players (fewer than 2 games in that track) can only book unrestricted Division 1–5 games.", { exact: true })).toBeVisible();
  await expect(page.getByText("Phoenix · America/Phoenix", { exact: true })).toBeVisible();
  await page.getByLabel("Tuesday", { exact: true }).check();
  await page.getByLabel("Highest division", { exact: true }).selectOption("2");
  await page.getByLabel("Lowest division", { exact: true }).selectOption("4");
  await page.getByLabel("Start date", { exact: true }).fill("2099-07-04");
  await page.getByLabel("End date (optional)", { exact: true }).fill("2099-08-01");
  await page.screenshot({ path: info.outputPath("schedule-editor-desktop.png"), fullPage: true });
  await page.getByRole("button", { name: "Save schedule", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Saturday football", exact: true })).toBeVisible();
  expect(writes).toHaveLength(1);
  expect(writes[0].body).toEqual({ name: "Saturday football", fieldId: sampleField.id, weekdays: [2, 6], kickoffTime: "20:30", durationMinutes: 60, startsOn: "2099-07-04", endsOn: "2099-08-01", bookingWindowDays: 28, priceUsd: "13.00", ageLabel: "18+", highestDivision: 2, lowestDivision: 4, isActive: true });
});

test("missing field routes through adding a field and restores the schedule", async ({ page }) => {
  const writes = await mockAdmin(page, { fields: [] });
  await page.goto("/admin?section=schedules");
  await page.getByRole("button", { name: "Add a field first", exact: true }).click();
  await expect(page).toHaveURL(/\/admin\/fields\/new\?returnTo=schedules/);
  await page.getByLabel("Field / pitch name").fill("Saturday pitch");
  await page.getByLabel("Street address").fill(sampleField.address);
  await page.getByLabel("Latitude", { exact: false }).fill("33.477");
  await page.getByLabel("Longitude", { exact: false }).fill("-112.093");
  await page.getByRole("button", { name: /Save field & continue/ }).click();
  await expect(page.getByRole("heading", { name: "Add a schedule", exact: true })).toBeVisible();
  await expect(page.getByLabel("Field / pitch", { exact: true })).toHaveValue("f1000000-0000-4000-8000-000000000002");
  expect(writes.filter((write) => write.path.endsWith("game-schedules"))).toHaveLength(0);
});

test("add-field round trip preserves schedule draft and selects the new field", async ({ page }) => {
  await mockAdmin(page);
  await startSchedule(page);
  await page.getByLabel("Schedule name", { exact: true }).fill("Weekend pickup");
  await page.getByLabel("Price per player (USD)", { exact: true }).fill("15.50");
  await page.getByLabel("Sunday", { exact: true }).check();
  await page.getByLabel("Kickoff time", { exact: true }).fill("18:00");
  await page.getByLabel("Highest division", { exact: true }).selectOption("2");
  await page.getByLabel("Lowest division", { exact: true }).selectOption("3");
  await page.getByRole("button", { name: "Add a new field" }).click();
  await page.getByLabel("Field / pitch name").fill("Second pitch");
  await page.getByLabel("Street address").fill(sampleField.address);
  await page.getByLabel("Latitude", { exact: false }).fill("33.477");
  await page.getByLabel("Longitude", { exact: false }).fill("-112.093");
  await page.getByRole("button", { name: /Save field & continue/ }).click();
  await expect(page.getByLabel("Schedule name", { exact: true })).toHaveValue("Weekend pickup");
  await expect(page.getByLabel("Price per player (USD)", { exact: true })).toHaveValue("15.50");
  await expect(page.getByLabel("Sunday", { exact: true })).toBeChecked();
  await expect(page.getByLabel("Kickoff time", { exact: true })).toHaveValue("18:00");
  await expect(page.getByLabel("Highest division", { exact: true })).toHaveValue("2");
  await expect(page.getByLabel("Lowest division", { exact: true })).toHaveValue("3");
  await expect(page.getByLabel("Field / pitch", { exact: true })).toHaveValue("f1000000-0000-4000-8000-000000000002");
});

test("load failures cannot become an empty schedule and require a retry", async ({ page }) => {
  await mockAdmin(page, { loadError: true });
  await page.goto("/admin?section=schedules");
  await expect(page.getByRole("alert").filter({ hasText: "database update" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Add schedule" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Add a field first" })).toHaveCount(0);
});

test("invalid weekdays and a failed save keep entered schedule details", async ({ page }) => {
  const writes = await mockAdmin(page, { saveError: true });
  await startSchedule(page);
  await page.getByLabel("Schedule name", { exact: true }).fill("My Saturday game");
  await page.getByLabel("Saturday", { exact: true }).uncheck();
  await page.getByRole("button", { name: "Save schedule", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "Choose at least one day" })).toBeVisible();
  expect(writes).toHaveLength(0);
  await page.getByLabel("Saturday", { exact: true }).check();
  await page.getByRole("button", { name: "Save schedule", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "field is archived" })).toBeVisible();
  await expect(page.getByLabel("Schedule name", { exact: true })).toHaveValue("My Saturday game");
  await expect(page.getByLabel("Field / pitch", { exact: true })).toHaveValue(sampleField.id);
  expect(writes).toHaveLength(1);
});

test("reversed division ranges are rejected before the schedule is sent", async ({ page }) => {
  const writes = await mockAdmin(page);
  await startSchedule(page);
  await page.getByLabel("Highest division", { exact: true }).selectOption("4");
  await page.getByLabel("Lowest division", { exact: true }).selectOption("2");
  await page.getByRole("button", { name: "Save schedule", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "Highest division must be less than or equal to lowest division." })).toBeVisible();
  expect(writes).toHaveLength(0);
});

test("pause and resume change only the schedule and explain existing games stay open", async ({ page }) => {
  const writes = await mockAdmin(page, { schedules: [sampleSchedule] });
  await page.goto("/admin?section=schedules");
  await page.getByRole("button", { name: "Pause schedule", exact: true }).click();
  await expect(page.getByText("Paused: no new games will be generated. Already-created games stay open.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Generate next games", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Resume schedule", exact: true }).click();
  await expect(page.getByRole("button", { name: "Generate next games", exact: true })).toBeEnabled();
  expect(writes.map((write) => write.body)).toEqual([{ isActive: false }, { isActive: true }]);
});

test("skip and restore use explicit reasons without cancelling generated games", async ({ page }) => {
  const writes = await mockAdmin(page, { schedules: [sampleSchedule] });
  await page.goto("/admin?section=schedules");
  await page.getByRole("button", { name: "Skip a date", exact: true }).click();
  await expect(page.getByText(/If a game already exists, cancel it from its game page/)).toBeVisible();
  await page.getByLabel("Date to skip", { exact: true }).fill("2099-07-04");
  await page.getByLabel("Reason", { exact: true }).fill("Field closed for holiday");
  await page.getByRole("button", { name: "Confirm skip", exact: true }).click();
  await page.getByText("Dates & exceptions", { exact: false }).click();
  await expect(page.getByText("Field closed for holiday", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Restore date", exact: true }).click();
  await expect(page.getByText("Field closed for holiday", { exact: true })).toHaveCount(0);
  expect(writes.map((write) => write.body)).toEqual([{ matchDate: "2099-07-04", reason: "Field closed for holiday", skip: true }, { matchDate: "2099-07-04", reason: "", skip: false }]);
  expect(writes.every((write) => write.path.endsWith("/skip"))).toBe(true);
});

test("generation conflicts are visible with generated-game links and mobile layout fits", async ({ page }, info) => {
  const writes = await mockAdmin(page, { schedules: [{ ...sampleSchedule, occurrences: [{ matchDate: "2099-07-04", status: "CONFLICT", gameId: null, errorMessage: "Another game overlaps this pitch." }, { matchDate: "2099-07-11", status: "CREATED", gameId: "created-game-id", errorMessage: null }] }] });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/admin?section=schedules");
  await expect(page.getByText("Needs attention: Another game overlaps this pitch.")).toBeVisible();
  await expect(page.getByRole("link", { name: "Open game" })).toHaveAttribute("href", "/admin/games/solo/created-game-id");
  await page.screenshot({ path: info.outputPath("schedules-mobile-conflict.png"), fullPage: true });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.getByRole("button", { name: "Generate next games", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "1 new game created" })).toBeVisible();
  expect(writes[0].path).toBe(`/api/referee/admin/game-schedules/${sampleSchedule.id}/generate`);
});

test("failed date skip preserves its date and reason for correction", async ({ page }) => {
  await mockAdmin(page, { schedules: [sampleSchedule], skipError: true });
  await page.goto("/admin?section=schedules");
  await page.getByRole("button", { name: "Skip a date", exact: true }).click();
  await page.getByLabel("Date to skip", { exact: true }).fill("2099-07-04");
  await page.getByLabel("Reason", { exact: true }).fill("Field unavailable");
  await page.getByRole("button", { name: "Confirm skip", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "belongs to this schedule" })).toBeVisible();
  await expect(page.getByLabel("Date to skip", { exact: true })).toHaveValue("2099-07-04");
  await expect(page.getByLabel("Reason", { exact: true })).toHaveValue("Field unavailable");
});

test("preview excludes elapsed kickoff and the date beyond the booking window", async ({ page }) => {
  await page.clock.setFixedTime(new Date("2026-10-12T06:00:00Z")); // Sunday 11 PM in Phoenix.
  await mockAdmin(page);
  await startSchedule(page);
  await page.getByLabel("Saturday", { exact: true }).uncheck();
  await page.getByLabel("Sunday", { exact: true }).check();
  await page.getByLabel("Start date", { exact: true }).fill("2026-10-11");
  await page.getByLabel("Booking window (days ahead)", { exact: true }).fill("7");
  const preview = page.getByRole("region", { name: "Schedule preview" });
  await expect(preview.getByText("No matching dates", { exact: false })).toBeVisible();
  await expect(preview.getByRole("listitem")).toHaveCount(0);
});

test("edit preview does not promise duplicate games or skipped dates", async ({ page }) => {
  await page.clock.setFixedTime(new Date("2026-10-12T06:00:00Z"));
  await mockAdmin(page, { schedules: [{ ...sampleSchedule, occurrences: [{ matchDate: "2026-10-17", status: "CREATED", gameId: "existing", errorMessage: null }], skips: [{ matchDate: "2026-10-24", reason: "Holiday" }] }] });
  await page.goto("/admin?section=schedules");
  await page.getByRole("button", { name: "Edit schedule", exact: true }).click();
  const preview = page.getByRole("region", { name: "Schedule preview" });
  await expect(preview.getByText("Sat, Oct 17, 2026", { exact: true })).toHaveCount(0);
  await expect(preview.getByText("Sat, Oct 24, 2026", { exact: true })).toHaveCount(0);
  await expect(preview.getByText("Sat, Oct 31, 2026", { exact: true })).toBeVisible();
});
