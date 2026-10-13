import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const publicConfig = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? publicConfig.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname.split(".")[0];
const sampleField = { id: "f1000000-0000-4000-8000-000000000001", name: "Encanto Park · Pitch 1", address: "2605 N 15th Ave", city: "Phoenix", state: "AZ", countryCode: "US", latitude: 33.477, longitude: -112.093, isActive: true, createdAt: "2026-10-11T00:00:00Z", updatedAt: "2026-10-11T00:00:00Z" };

async function mockAdmin(page: Page, options: { fields?: typeof sampleField[]; fieldsError?: boolean; saveError?: boolean; createError?: boolean } = {}) {
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  let fields = options.fields ?? [];
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
      writes.push({ path, body });
      if (path === "/api/referee/admin/fields") {
        if (options.saveError) { status = 400; data = { error: "This field already exists." }; }
        else { const field = { ...sampleField, ...body }; fields = [...fields, field]; data = { field }; status = 201; }
      } else if (path.startsWith("/api/referee/admin/fields/")) {
        fields = fields.map((field) => ({ ...field, ...body })); data = { field: fields[0] };
      } else if (path === "/api/referee/admin/solo-games") {
        status = options.createError ? 400 : 201;
        data = options.createError ? { error: "This field is archived. Choose another field." } : { gameId: "new-game" };
      }
    } else if (path === "/api/referee/admin/fields") {
      status = options.fieldsError ? 503 : 200;
      data = options.fieldsError ? { error: "The saved-fields database update is not installed yet." } : { fields };
    } else if (path === "/api/referee/fixtures") {
      data = { me: { profileId: "00000000-0000-4000-8000-000000000001", displayName: "Preview Admin", role: "admin" }, fixtures: [] };
    } else if (path === "/api/referee/assignments") data = { referees: [], fixtures: [] };
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

async function fillField(page: Page) {
  await page.getByLabel("Field / pitch name").fill(sampleField.name);
  await page.getByLabel("Street address").fill(sampleField.address);
  await page.getByLabel("Latitude", { exact: false }).fill(String(sampleField.latitude));
  await page.getByLabel("Longitude", { exact: false }).fill(String(sampleField.longitude));
}

test("empty catalogue redirects into field creation then resumes the solo game", async ({ page }, info) => {
  const writes = await mockAdmin(page);
  await page.goto("/admin?section=games");
  await page.getByRole("button", { name: "Create solo game", exact: false }).click();
  await expect(page).toHaveURL(/\/admin\/fields\/new\?returnTo=solo/);
  await expect(page.getByRole("heading", { name: "Add a field", exact: true })).toBeVisible();
  await fillField(page);
  await expect(page.getByRole("link", { name: /Check this map pin/ })).toHaveAttribute("href", /33\.477%2C-112\.093/);
  await page.screenshot({ path: info.outputPath("add-field-desktop.png"), fullPage: true });
  await page.getByRole("button", { name: "Save field & continue" }).click();
  await expect(page.getByRole("heading", { name: "Create a solo game" })).toBeVisible();
  await expect(page.getByLabel("Field / pitch", { exact: false })).toHaveValue(sampleField.id);
  await page.getByLabel("Match date").fill("2099-07-24");
  await page.getByRole("button", { name: "Create and open game" }).click();
  await expect(page.getByText("Solo game created and opened for bookings.")).toBeVisible();
  const create = writes.find((write) => write.path.endsWith("solo-games"));
  expect(create?.body).toEqual({
    fieldId: sampleField.id,
    matchDate: "2099-07-24",
    kickoffTime: "20:30",
    durationMinutes: 60,
    priceUsd: "13.00",
    ageLabel: "18+",
    highestDivision: 1,
    lowestDivision: 5,
  });
});

test("saved active field is required; archived fields cannot be selected", async ({ page }) => {
  await mockAdmin(page, { fields: [sampleField, { ...sampleField, id: "f1000000-0000-4000-8000-000000000002", name: "Archived pitch", isActive: false }] });
  await page.goto("/admin?section=games");
  await page.getByRole("button", { name: "Create solo game", exact: false }).click();
  await expect(page.getByRole("button", { name: "Create and open game" })).toBeDisabled();
  await expect(page.getByRole("option", { name: /Archived pitch/ })).toHaveCount(0);
  await page.getByLabel("Field / pitch", { exact: false }).selectOption(sampleField.id);
  await expect(page.getByLabel("Highest division")).toHaveValue("1");
  await expect(page.getByLabel("Lowest division")).toHaveValue("5");
  await expect(page.getByText("Placement players (fewer than 2 matches) can only book unrestricted Division 1–5 games.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Create and open game" })).toBeEnabled();
  await page.getByLabel("Highest division").selectOption("5");
  await page.getByLabel("Lowest division").selectOption("4");
  await expect(page.getByRole("button", { name: "Create and open game" })).toBeDisabled();
  await page.getByLabel("Lowest division").selectOption("5");
  await expect(page.getByRole("button", { name: "Create and open game" })).toBeEnabled();
});

test("adding a field midway preserves the game draft and validates the map pin", async ({ page }) => {
  const writes = await mockAdmin(page, { fields: [sampleField] });
  await page.goto("/admin?section=games");
  await page.getByRole("button", { name: "Create solo game", exact: false }).click();
  await page.getByLabel("Match date").fill("2099-07-24");
  await page.getByLabel("Kickoff time").fill("18:15");
  await page.getByLabel("Duration (minutes)").fill("90");
  await page.getByLabel("Price per player (USD)").fill("15.50");
  await page.getByLabel("Highest division").selectOption("2");
  await page.getByLabel("Lowest division").selectOption("4");
  await page.getByRole("button", { name: "Add a new field", exact: false }).click();
  await fillField(page);
  await page.getByLabel("Latitude", { exact: false }).fill("91");
  await expect(page.getByRole("link", { name: /Check this map pin/ })).toHaveCount(0);
  await page.getByRole("button", { name: "Save field & continue" }).click();
  expect(writes).toHaveLength(0);
  await page.getByLabel("Latitude", { exact: false }).fill("33.477");
  await page.getByRole("button", { name: "Save field & continue" }).click();
  await expect(page.getByLabel("Match date")).toHaveValue("2099-07-24");
  await expect(page.getByLabel("Kickoff time")).toHaveValue("18:15");
  await expect(page.getByLabel("Duration (minutes)")).toHaveValue("90");
  await expect(page.getByLabel("Price per player (USD)")).toHaveValue("15.50");
  await expect(page.getByLabel("Highest division")).toHaveValue("2");
  await expect(page.getByLabel("Lowest division")).toHaveValue("4");
  await page.getByRole("button", { name: "Create and open game" }).click();
  const create = writes.find((write) => write.path.endsWith("solo-games"));
  expect(create?.body).toMatchObject({
    highestDivision: 2,
    lowestDivision: 4,
    durationMinutes: 90,
    priceUsd: "15.50",
  });
});

test("field loading failure is not treated as an empty catalogue", async ({ page }) => {
  await mockAdmin(page, { fieldsError: true });
  await page.goto("/admin?section=games");
  await page.getByRole("button", { name: "Create solo game", exact: false }).click();
  await expect(page.getByText("The saved-fields database update is not installed yet.")).toBeVisible();
  await expect(page).toHaveURL(/section=games/);
  await expect(page.getByRole("heading", { name: "Add a field", exact: true })).toHaveCount(0);
});

test("failed field save keeps entered details and does not create a game", async ({ page }) => {
  const writes = await mockAdmin(page, { saveError: true });
  await page.goto("/admin/fields/new?returnTo=solo");
  await fillField(page);
  await page.getByRole("button", { name: "Save field & continue" }).click();
  await expect(page.getByRole("alert").filter({ hasText: "This field already exists." })).toBeVisible();
  await expect(page.getByLabel("Field / pitch name")).toHaveValue(sampleField.name);
  expect(writes.filter((write) => write.path.endsWith("solo-games"))).toHaveLength(0);
});

test("archive and restore preserve field history; mobile layout has no page overflow", async ({ page }, info) => {
  const writes = await mockAdmin(page, { fields: [sampleField] });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/admin/fields");
  await expect(page.getByRole("heading", { name: sampleField.name })).toBeVisible();
  await page.screenshot({ path: info.outputPath("fields-mobile.png"), fullPage: true });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.getByRole("button", { name: "Archive", exact: true }).click();
  await expect(page.getByRole("heading", { name: sampleField.name })).toHaveCount(0);
  await page.getByLabel("Show archived").check();
  await page.getByRole("button", { name: "Restore", exact: true }).click();
  await expect(page.getByText("Available", { exact: true })).toBeVisible();
  expect(writes.map((write) => write.body)).toEqual([{ isActive: false }, { isActive: true }]);
});

test("server rejecting an archived field leaves the create form open for correction", async ({ page }) => {
  await mockAdmin(page, { fields: [sampleField], createError: true });
  await page.goto("/admin?section=games");
  await page.getByRole("button", { name: "Create solo game", exact: false }).click();
  await page.getByLabel("Field / pitch", { exact: false }).selectOption(sampleField.id);
  await page.getByRole("button", { name: "Create and open game" }).click();
  await expect(page.locator(".admin-modal").getByRole("alert")).toHaveText("This field is archived. Choose another field.");
  await expect(page.getByRole("heading", { name: "Create a solo game" })).toBeVisible();
});

for (const longitude of ["-111.975201", "−111.975201", " −111,975201 "]) {
  test(`decimal longitude ${JSON.stringify(longitude)} saves as the correct numeric coordinate`, async ({ page }) => {
    const writes = await mockAdmin(page);
    await page.goto("/admin/fields/new");
    await fillField(page);
    const input = page.getByLabel("Longitude", { exact: false });
    await expect(input).toHaveAttribute("type", "text");
    await input.fill(longitude);
    await expect(page.getByRole("link", { name: /Check this map pin/ })).toHaveAttribute("href", /33\.477%2C-111\.975201/);
    await page.getByRole("button", { name: "Save field", exact: true }).click();
    await expect(page.getByRole("heading", { name: sampleField.name })).toBeVisible();
    expect(writes).toHaveLength(1);
    expect(writes[0]).toEqual({
      path: "/api/referee/admin/fields",
      body: {
        name: sampleField.name, address: sampleField.address, city: "Phoenix", state: "AZ", countryCode: "US",
        latitude: 33.477, longitude: -111.975201,
      },
    });
  });
}

test("invalid coordinate text and ranges explain the error without posting or losing field details", async ({ page }) => {
  const writes = await mockAdmin(page);
  await page.goto("/admin/fields/new");
  await fillField(page);
  const latitude = page.getByLabel("Latitude", { exact: false });
  const longitude = page.getByLabel("Longitude", { exact: false });
  for (const value of ["NaN", "Infinity", "0x10", "1e2", "-111.975201 West", "33.477, -111.975201", "-180.000001"]) {
    await longitude.fill(value);
    await page.getByRole("button", { name: "Save field", exact: true }).click();
    await expect(longitude).toHaveAttribute("aria-invalid", "true");
    await expect(longitude).toBeFocused();
    await expect(page.getByRole("alert").filter({ hasText: "No field has been saved." })).toBeVisible();
    await expect(longitude).toHaveAccessibleDescription(/longitude from −180 to 180/);
    await expect(page.getByRole("link", { name: /Check this map pin/ })).toHaveCount(0);
    await expect(longitude).toHaveValue(value);
    await expect(page.getByLabel("Field / pitch name")).toHaveValue(sampleField.name);
    await expect(page.getByLabel("Street address")).toHaveValue(sampleField.address);
    expect(writes).toHaveLength(0);
  }
  await longitude.fill("-111.975201");
  await latitude.fill("90.000001");
  await page.getByRole("button", { name: "Save field", exact: true }).click();
  await expect(latitude).toHaveAttribute("aria-invalid", "true");
  await expect(latitude).toBeFocused();
  await expect(page.getByRole("alert").filter({ hasText: "No field has been saved." })).toBeVisible();
  await expect(latitude).toHaveAccessibleDescription(/latitude from −90 to 90/);
  expect(writes).toHaveLength(0);
  await latitude.fill("33.477");
  await page.getByRole("button", { name: "Save field", exact: true }).click();
  await expect(page.getByRole("heading", { name: sampleField.name })).toBeVisible();
  expect(writes).toHaveLength(1);
  expect(writes[0].body).toMatchObject({ latitude: 33.477, longitude: -111.975201 });
});

test("a rejected server save retains pasted coordinates and other entered details", async ({ page }) => {
  const writes = await mockAdmin(page, { saveError: true });
  await page.goto("/admin/fields/new");
  await fillField(page);
  await page.getByLabel("Longitude", { exact: false }).fill("−111.975201");
  await page.getByRole("button", { name: "Save field", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "This field already exists." })).toBeVisible();
  await expect(page.getByLabel("Longitude", { exact: false })).toHaveValue("−111.975201");
  await expect(page.getByLabel("Latitude", { exact: false })).toHaveValue("33.477");
  await expect(page.getByLabel("Field / pitch name")).toHaveValue(sampleField.name);
  await expect(page.getByLabel("Street address")).toHaveValue(sampleField.address);
  expect(writes).toHaveLength(1);
  expect(writes[0].body).toMatchObject({ latitude: 33.477, longitude: -111.975201 });
});
