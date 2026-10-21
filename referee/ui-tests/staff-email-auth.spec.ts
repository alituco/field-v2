import { expect, test, type Page } from "@playwright/test";

const host = "nfdkdhdevpstfspazbfn.supabase.co";
const actor = "00000000-0000-4000-8000-000000000001";
const staffKey = `fieldrush-staff-${host}-auth-v1`;
function session(staff = true) {
  const exp = 4102444800;
  const encoded = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return { access_token: `${encoded({ alg: "HS256", typ: "JWT" })}.${encoded({ sub: actor, exp })}.mock-only-signature`,
    refresh_token: "mock-staff-refresh", token_type: "bearer", expires_at: exp, expires_in: exp - Math.floor(Date.now() / 1000),
    user: { id: actor, aud: "authenticated", role: "authenticated", email: "referee@example.test", created_at: "2026-10-20T00:00:00Z",
      app_metadata: { provider: "email", providers: ["email"], ...(staff ? { fieldrush_account_type: "staff" } : {}) }, user_metadata: {} } };
}
async function isolate(page: Page) {
  await page.route("**/*", async route => {
    const url = new URL(route.request().url());
    if (url.hostname === "127.0.0.1") return route.fallback();
    if (url.hostname === host && url.pathname === "/auth/v1/logout") return route.fulfill({ status: 204 });
    await route.abort();
  });
}

test("dedicated staff email gets a six-digit code and enters staff tools", async ({ page }) => {
  await isolate(page);
  let requested: unknown;
  let verified: unknown;
  await page.route("**/api/staff-auth/code", async route => {
    requested = route.request().postDataJSON();
    await route.fulfill({ json: { message: "If this email has staff access, a code was sent." } });
  });
  await page.route(`https://${host}/auth/v1/verify`, async route => {
    verified = route.request().postDataJSON();
    await route.fulfill({ json: session() });
  });
  await page.route("**/api/referee/fixtures", route => route.fulfill({ json: { me: { profileId: actor, displayName: "Staff Referee", role: "referee" }, fixtures: [] } }));
  await page.goto("/");
  await expect(page.getByText("EMAIL SIGN IN")).toBeVisible();
  await expect(page.getByLabel("Phone", { exact: true })).toHaveCount(0);
  await page.getByLabel("Staff email").fill("Referee@Example.Test");
  await page.getByRole("button", { name: "Send code", exact: true }).click();
  expect(requested).toEqual({ email: "referee@example.test" });
  await expect(page.getByText("If referee@example.test has active staff access", { exact: false })).toBeVisible();
  await page.getByLabel("6-digit code").fill("123456");
  await page.getByRole("button", { name: "Verify", exact: true }).click();
  await expect(page.getByText("Signed in as Staff Referee")).toBeVisible();
  expect(verified).toMatchObject({ email: "referee@example.test", token: "123456", type: "email" });
});

test("a player identity returned by email verification is signed out with setup guidance", async ({ page }) => {
  await isolate(page);
  let fixtureReads = 0;
  await page.route("**/api/staff-auth/code", route => route.fulfill({ json: { message: "If this email has staff access, a code was sent." } }));
  await page.route(`https://${host}/auth/v1/verify`, route => route.fulfill({ json: session(false) }));
  await page.route("**/api/referee/fixtures", route => { fixtureReads++; return route.fulfill({ status: 500 }); });
  await page.goto("/");
  await page.getByLabel("Staff email").fill("player@example.test");
  await page.getByRole("button", { name: "Send code", exact: true }).click();
  await page.getByLabel("6-digit code").fill("123456");
  await page.getByRole("button", { name: "Verify", exact: true }).click();
  await expect(page.getByText(/Use your dedicated staff email to sign in/)).toBeVisible();
  expect(fixtureReads).toBe(0);
  await expect.poll(() => page.evaluate(key => localStorage.getItem(key), staffKey)).toBeNull();
});

test("a legacy player browser session is not imported into staff storage", async ({ page }) => {
  await isolate(page);
  await page.addInitScript(value => localStorage.setItem("sb-nfdkdhdevpstfspazbfn-auth-token", JSON.stringify(value)), session(false));
  let fixtureReads = 0;
  await page.route("**/api/referee/fixtures", route => { fixtureReads++; return route.fulfill({ status: 500 }); });
  await page.goto("/");
  await expect(page.getByLabel("Staff email")).toBeVisible();
  expect(fixtureReads).toBe(0);
  expect(await page.evaluate(() => localStorage.getItem("sb-nfdkdhdevpstfspazbfn-auth-token"))).not.toBeNull();
});

test("legacy staff setup preserves its staff ID, name and role while requesting a dedicated email", async ({ page }) => {
  await isolate(page);
  await page.addInitScript(({ key, value }) => localStorage.setItem(key, JSON.stringify(value)), { key: staffKey, value: session() });
  const legacyId = "00000000-0000-4000-8000-000000000099";
  let created: unknown;
  await page.route("**/api/referee/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() === "POST" && path === "/api/referee/referees") {
      created = route.request().postDataJSON();
      return route.fulfill({ json: { profileId: legacyId } });
    }
    const responses: Record<string, unknown> = {
      "/api/referee/fixtures": { me: { profileId: actor, displayName: "Admin", role: "admin" }, fixtures: [] },
      "/api/referee/assignments": { referees: [], fixtures: [] },
      "/api/referee/admin/overview": { metrics: {}, attention: [], audit: [] },
      "/api/referee/admin/support": { tickets: [], activeCount: 0 },
      "/api/referee/admin/reports": { reports: [] }, "/api/referee/admin/subjects": { subjects: [] },
      "/api/referee/admin/forfeits": { forfeits: [] },
      "/api/referee/referees": { staff: [
        { profileId: legacyId, displayName: "Existing Ref", email: null, phone: "+16025550101", role: "referee", isActive: true, setupRequired: true },
        { profileId: "00000000-0000-4000-8000-000000000098", displayName: "Inactive Ref", email: null, phone: null, role: "referee", isActive: false, setupRequired: true },
      ] },
    };
    await route.fulfill({ json: responses[path] ?? {} });
  });
  await page.goto("/admin?section=staff");
  await expect(page.getByText("Setup required", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Set up staff email for Inactive Ref", exact: true })).toHaveCount(0);
  await expect(page.getByText("Inactive", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Set up staff email for Existing Ref", exact: true }).click();
  await expect(page.getByLabel("Staff display name")).toBeDisabled();
  await expect(page.getByLabel("Staff display name")).toHaveValue("Existing Ref");
  await page.getByLabel("Dedicated staff email", { exact: true }).fill("Existing.Ref@Example.Test");
  await page.getByRole("button", { name: "Set up email and send code", exact: true }).click();
  await expect.poll(() => created).toEqual({ displayName: "Existing Ref", email: "existing.ref@example.test", role: "referee", existingStaffProfileId: legacyId, sendOtp: true });
});
