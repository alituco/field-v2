import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const publicConfig = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? publicConfig.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname;
const phoenix = { id: "phoenix", displayName: "Phoenix", state: "AZ", countryCode: "US", timezone: "America/Phoenix", active: true };

async function mockAdmin(page: Page, failSave = false) {
  const writes: Array<{ path: string; body: Record<string, unknown> }> = [];
  let cities = [phoenix];
  await page.addInitScript(({ key }) => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } } })), { key: `fieldrush-staff-${project}-auth-v1` });
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({ status: 200, contentType: "application/json", body: "{}" }));
  await page.route("**/api/referee/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let data: unknown = {};
    let status = 200;
    if (request.method() !== "GET") {
      const body = request.postDataJSON(); writes.push({ path, body });
      if (failSave) { status = 400; data = { error: "City timezone is invalid." }; }
      else { const city = { ...phoenix, ...body, id: path.split("/").at(-1)! }; cities = [...cities.filter((item) => item.id !== city.id), city]; data = { city }; }
    } else if (path.endsWith("/cities")) data = { cities };
    else if (path === "/api/referee/fixtures") data = { me: { profileId: "00000000-0000-4000-8000-000000000001", displayName: "Preview Admin", role: "admin" }, fixtures: [] };
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

test("city page starts with Phoenix only and creates new markets closed until explicitly opened", async ({ page }, info) => {
  const writes = await mockAdmin(page);
  await page.goto("/admin/cities");
  await expect(page.getByRole("heading", { name: "Phoenix, AZ" })).toBeVisible();
  await expect(page.getByText(/most games played across both positions/)).toBeVisible();
  await page.getByRole("button", { name: "Add a city" }).click();
  await page.getByLabel("City name", { exact: true }).fill("New York");
  await expect(page.getByLabel("Permanent city ID")).toHaveValue("new-york");
  await page.getByLabel("State / region").fill("NY");
  await page.getByLabel("IANA timezone").fill("America/New_York");
  await expect(page.getByRole("checkbox")).not.toBeChecked();
  await page.screenshot({ path: info.outputPath("city-editor-desktop.png"), fullPage: true });
  await page.getByRole("button", { name: "Save city", exact: true }).click();
  await expect(page.getByRole("heading", { name: "New York, NY" })).toBeVisible();
  expect(writes).toEqual([{ path: "/api/referee/admin/cities/new-york", body: { displayName: "New York", state: "NY", countryCode: "US", timezone: "America/New_York", active: false } }]);
});

test("editing a city preserves its identity and mobile layout fits", async ({ page }, info) => {
  const writes = await mockAdmin(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/admin/cities");
  await page.getByRole("button", { name: "Edit city" }).click();
  await expect(page.getByLabel("Permanent city ID")).toHaveAttribute("readonly", "");
  await expect(page.getByRole("checkbox")).toBeChecked();
  await page.getByLabel("City name", { exact: true }).fill("Phoenix Metro");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: info.outputPath("city-editor-mobile.png"), fullPage: true });
  await page.getByRole("button", { name: "Save city", exact: true }).click();
  expect(writes[0].path).toBe("/api/referee/admin/cities/phoenix");
  expect(writes[0].body.active).toBe(true);
});

test("failed city save retains entered details and does not pretend success", async ({ page }) => {
  await mockAdmin(page, true);
  await page.goto("/admin/cities");
  await page.getByRole("button", { name: "Edit city" }).click();
  await page.getByLabel("IANA timezone").fill("Unknown/City");
  await page.getByRole("button", { name: "Save city", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "City timezone is invalid." })).toBeVisible();
  await expect(page.getByLabel("IANA timezone")).toHaveValue("Unknown/City");
});
