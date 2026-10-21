import { expect, test } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

import { normalizeAdminWaitlistApplicant } from "../src/lib/admin-waitlist";

const publicConfig = existsSync(".env.local")
  ? parseEnv(readFileSync(".env.local", "utf8"))
  : {};
const project = new URL(
  process.env.NEXT_PUBLIC_SUPABASE_URL ??
    publicConfig.NEXT_PUBLIC_SUPABASE_URL ??
    "https://nfdkdhdevpstfspazbfn.supabase.co",
).hostname;
const adminId = "00000000-0000-4000-8000-000000000001";
const applicants = [
  normalizeAdminWaitlistApplicant({
    id: "10000000-0000-4000-8000-000000000001",
    email: "launch@example.com",
    interest: "LAUNCH_UPDATES",
    status: "WAITING",
    source: "FIELDRUSH_GG",
    created_at: "2026-10-12T20:00:00Z",
    launch_updates_consented_at: "2026-10-12T20:00:00Z",
    launch_updates_consent_version: "launch-updates-v1",
    signup_placement: "desktop-hero",
  }),
  normalizeAdminWaitlistApplicant({
    id: "10000000-0000-4000-8000-000000000002",
    full_name: "Existing Applicant",
    email: "existing@example.com",
    interest: "CLAN_LEADER",
    status: "SELECTED",
    source: "FIELD_BH",
    age: 23,
    preferred_position: "DEFENDER",
    created_at: "2026-07-17T20:00:00Z",
    launch_updates_consented_at: "2026-10-12T21:00:00Z",
    launch_updates_consent_version: "launch-updates-v1",
    signup_placement: "mobile-footer",
  }),
  normalizeAdminWaitlistApplicant({
    id: "10000000-0000-4000-8000-000000000003",
    full_name: "Player Applicant",
    email: "player@example.com",
    interest: "SOLO_PLAYER",
    status: "WAITING",
    source: "FIELD_BH",
    age: 19,
    created_at: "2026-07-17T19:00:00Z",
  }),
];

test("Interest shows one list and filters all launch subscribers without changing player applications", async ({ page }) => {
  const unexpectedRequests: string[] = [];
  let interestReads = 0;
  await page.addInitScript(({ key, userId }) => {
    localStorage.setItem(key, JSON.stringify({
      access_token: "ui-test-token",
      refresh_token: "ui-test-refresh",
      token_type: "bearer",
      expires_at: 4102444800,
      user: { id: userId, aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } },
    }));
  }, { key: `fieldrush-staff-${project}-auth-v1`, userId: adminId });

  await page.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (["127.0.0.1", "localhost"].includes(url.hostname)) {
      await route.fallback();
      return;
    }
    if (url.hostname.endsWith(".supabase.co")) {
      await route.fulfill({ status: 200, contentType: "application/json", body: "{}" });
      return;
    }
    unexpectedRequests.push(url.origin);
    await route.abort();
  });
  await page.route("**/api/referee/**", async (route) => {
    const request = route.request();
    const pathname = new URL(request.url()).pathname;
    if (request.method() !== "GET") {
      unexpectedRequests.push(`${request.method()} ${pathname}`);
      await route.fulfill({ status: 405 });
      return;
    }
    const responses: Record<string, unknown> = {
      "/api/referee/fixtures": { me: { profileId: adminId, displayName: "Preview Admin", role: "admin" }, fixtures: [] },
      "/api/referee/assignments": { referees: [], fixtures: [] },
      "/api/referee/admin/overview": { metrics: {}, attention: [], audit: [] },
      "/api/referee/admin/support": { tickets: [], activeCount: 0 },
      "/api/referee/admin/reports": { reports: [] },
      "/api/referee/admin/subjects": { subjects: [] },
      "/api/referee/admin/forfeits": { forfeits: [] },
      "/api/referee/referees": { staff: [] },
      "/api/referee/admin/waitlist": { applicants },
    };
    if (!(pathname in responses)) unexpectedRequests.push(pathname);
    if (pathname === "/api/referee/admin/waitlist") {
      interestReads += 1;
      expect(request.headers().authorization).toBe("Bearer ui-test-token");
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(responses[pathname] ?? {}) });
  });

  await page.goto("/admin?section=waitlist");
  await expect(page.getByRole("heading", { name: "Interest", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Interest", exact: true })).toBeVisible();
  const table = page.locator(".admin-waitlist-table");
  await expect(table.locator("tbody tr")).toHaveCount(3);
  const emailSignup = table.getByRole("row").filter({ hasText: "launch@example.com" });
  await expect(emailSignup).toContainText("fieldrush.gg");
  await expect(emailSignup).toContainText("Desktop hero");
  await expect(emailSignup).toContainText("Not requested for email signup");
  await expect(emailSignup).toContainText("Subscribed");
  await expect(emailSignup).not.toContainText("Unnamed");
  await expect(emailSignup).not.toContainText("Solo player");
  const existing = table.getByRole("row").filter({ hasText: "existing@example.com" });
  await expect(existing).toContainText("Existing Applicant");
  await expect(existing).toContainText("Clan leader");
  await expect(existing).toContainText("Age 23");
  await expect(existing).toContainText("Subscribed");
  await expect(existing).toContainText("Mobile footer");
  await expect(table.getByRole("row").filter({ hasText: "player@example.com" })).toContainText("No signup recorded");
  await page.screenshot({ path: test.info().outputPath("interest.png"), fullPage: true });

  await page.getByRole("combobox", { name: "Filter by interest", exact: true }).selectOption("LAUNCH_UPDATES");
  await expect(table.locator("tbody tr")).toHaveCount(2);
  await expect(table).toContainText("existing@example.com");
  await expect(table).not.toContainText("player@example.com");
  await page.getByPlaceholder("Search name, email or phone").fill("launch@example.com");
  await expect(table.locator("tbody tr")).toHaveCount(1);
  expect(interestReads).toBe(1);
  expect(unexpectedRequests).toEqual([]);
});
