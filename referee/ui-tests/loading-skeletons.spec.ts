import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const publicConfig = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? publicConfig.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname.split(".")[0];

function deferred() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => { release = resolve; });
  return { promise, release };
}

async function mockSession(page: Page) {
  await page.addInitScript(({ key }) => {
    localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated" } }));
  }, { key: `sb-${project}-auth-token` });
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({ json: {} }));
}

function payloadFor(path: string) {
  if (path === "/api/referee/fixtures") return { me: { profileId: "00000000-0000-4000-8000-000000000001", displayName: "Preview Admin", role: "admin" }, fixtures: [] };
  if (path.endsWith("assignments")) return { referees: [], fixtures: [] };
  if (path.endsWith("overview")) return { metrics: {}, attention: [], audit: [] };
  if (path.endsWith("support")) return { tickets: [], activeCount: 0 };
  if (path.endsWith("reports")) return { reports: [] };
  if (path.endsWith("subjects")) return { subjects: [] };
  if (path.endsWith("forfeits")) return { forfeits: [] };
  if (path.endsWith("referees")) return { staff: [] };
  if (path.endsWith("game-schedules")) return { schedules: [], fields: [] };
  if (path.endsWith("fields")) return { fields: [] };
  return {};
}

for (const section of ["fields", "schedules"] as const) {
  for (const failure of [false, true]) {
    test(`${section} replaces an accessible skeleton with ${failure ? "an error" : "loaded content"}`, async ({ page }, info) => {
      await mockSession(page);
      await page.emulateMedia({ reducedMotion: "reduce" });
      const pending = deferred();
      const endpoint = section === "schedules" ? "game-schedules" : "fields";
      await page.route("**/api/referee/**", async (route) => {
        const path = new URL(route.request().url()).pathname;
        if (path === `/api/referee/admin/${endpoint}`) {
          await pending.promise;
          await route.fulfill({ status: failure ? 503 : 200, json: failure ? { error: "Could not load this test data." } : payloadFor(path) });
        } else await route.fulfill({ json: payloadFor(path) });
      });
      await page.goto(`/admin?section=${section}`);
      const skeleton = page.getByRole("status", { name: `Loading ${section}`, exact: true });
      try {
        await expect(skeleton).toBeVisible();
        await expect(skeleton.getByRole("button")).toHaveCount(0);
        await expect(skeleton.locator('[aria-hidden="true"]')).toHaveCount(1);
        expect(await skeleton.locator("i").evaluateAll((shapes) => shapes.every((shape) => getComputedStyle(shape).animationName === "none"))).toBe(true);
        await expect(page.getByRole("heading", { name: section === "fields" ? "Your first field goes here." : "Your week, on repeat." })).toHaveCount(0);
        if (!failure) await page.screenshot({ path: info.outputPath(`${section}-skeleton.png`), fullPage: true });
      } finally { pending.release(); }
      await expect(skeleton).toHaveCount(0);
      if (failure) await expect(page.getByRole("alert").filter({ hasText: "Could not load this test data." })).toBeVisible();
      else await expect(page.getByRole("heading", { name: section === "fields" ? "Your first field goes here." : "Your week, on repeat." })).toBeVisible();
    });
  }
}

test("referee waits for assigned games instead of showing a false empty state", async ({ page }, info) => {
  await mockSession(page);
  const pending = deferred();
  await page.route("**/api/referee/**", async (route) => {
    await pending.promise;
    await route.fulfill({ json: payloadFor(new URL(route.request().url()).pathname) });
  });
  await page.goto("/");
  const skeleton = page.getByRole("status", { name: "Loading assigned games" });
  try {
    await expect(skeleton).toBeVisible();
    await expect(page.getByRole("heading", { name: "No match assigned" })).toHaveCount(0);
    expect(await skeleton.locator("i").first().evaluate((shape) => getComputedStyle(shape).animationName)).not.toBe("none");
    await page.screenshot({ path: info.outputPath("referee-games-skeleton.png"), fullPage: true });
  } finally { pending.release(); }
  await expect(skeleton).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "No match assigned" })).toBeVisible();
});

for (const kind of ["games/solo", "people/player"]) {
  test(`${kind} skeleton ends when the detail request fails`, async ({ page }) => {
    await mockSession(page);
    await page.emulateMedia({ reducedMotion: "reduce" });
    const pending = deferred();
    await page.route("**/api/referee/**", async (route) => {
      await pending.promise;
      await route.fulfill({ status: 503, json: { error: "Detail temporarily unavailable." } });
    });
    await page.goto(`/admin/${kind}/d1000000-0000-4000-8000-000000000001`);
    const skeleton = page.getByRole("status", { name: kind.startsWith("games") ? "Loading game overview" : "Loading account history" });
    try {
      await expect(skeleton).toBeVisible();
      expect(await skeleton.locator("i").evaluateAll((shapes) => shapes.every((shape) => getComputedStyle(shape).animationName === "none"))).toBe(true);
    } finally { pending.release(); }
    await expect(skeleton).toHaveCount(0);
    await expect(page.getByText("Detail temporarily unavailable.")).toBeVisible();
  });
}
