import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

import { verifyAdminRequestInboxes } from "../e2e/support/admin-request-navigation";
import type { AdminSupportTicket } from "../src/lib/admin-support";

const publicConfig = existsSync(".env.local")
  ? parseEnv(readFileSync(".env.local", "utf8"))
  : {};
const project = new URL(
  process.env.NEXT_PUBLIC_SUPABASE_URL ??
    publicConfig.NEXT_PUBLIC_SUPABASE_URL ??
    "https://nfdkdhdevpstfspazbfn.supabase.co",
).hostname;
const markers = {
  supportDetails: "[FIELD UI INBOX] A player needs help with a booking.",
  reportDetails: "[FIELD UI INBOX] A player reported unsafe conduct.",
};
const adminId = "00000000-0000-4000-8000-000000000001";

function supportTicket(id: string, description: string): AdminSupportTicket {
  return {
    id,
    reference: `FIELD-${id.slice(-6)}`,
    status: "OPEN",
    priority: "NORMAL",
    category: "BOOKING",
    subject: "Booking question",
    description,
    source: "PLAYER_APP",
    requesterId: "00000000-0000-4000-8000-000000000002",
    requesterName: "Support Player",
    requesterUsername: "support_player",
    requesterAvatarUrl: null,
    assignedTo: null,
    resolutionNote: null,
    adminNote: null,
    revision: 0,
    createdAt: "2026-10-11T00:00:00Z",
    updatedAt: "2026-10-11T00:00:00Z",
  };
}

function report(id: string, description: string) {
  return {
    id,
    status: "OPEN",
    priority: "NORMAL",
    category: "UNSAFE_CONDUCT",
    description,
    reporterName: "Reporting Player",
    reporterRole: "PLAYER",
    subjectType: "PLAYER",
    subjectId: "00000000-0000-4000-8000-000000000003",
    subjectName: "Reported Player",
    matchLabel: null,
    matchKind: null,
    matchId: null,
    replayOffsetSeconds: null,
    assignedTo: null,
    resolutionNote: null,
    createdAt: "2026-10-11T00:00:00Z",
    updatedAt: "2026-10-11T00:00:00Z",
  };
}

async function mockAdminInboxes(page: Page, initialLoad?: Promise<void>) {
  const unexpectedRequests: string[] = [];
  const inboxQueries: string[] = [];
  await page.addInitScript(({ key, userId }) => {
    localStorage.setItem(key, JSON.stringify({
      access_token: "ui-test-token",
      refresh_token: "ui-test-refresh",
      token_type: "bearer",
      expires_at: 4102444800,
      user: { id: userId, aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } },
    }));
  }, { key: `fieldrush-staff-${project}-auth-v1`, userId: adminId });

  // The real page and local assets may load; no unmocked remote traffic may leave.
  await page.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (["127.0.0.1", "localhost"].includes(url.hostname)) {
      await route.fallback();
      return;
    }
    unexpectedRequests.push(url.origin);
    await route.abort();
  });
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({
    status: 200,
    contentType: "application/json",
    body: "{}",
  }));
  await page.route("**/api/referee/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    if (request.method() !== "GET") {
      unexpectedRequests.push(`${request.method()} ${url.pathname}`);
      await route.fulfill({ status: 405, body: "UI contract is read-only." });
      return;
    }

    if (initialLoad) await initialLoad;
    let data: unknown;
    switch (url.pathname) {
      case "/api/referee/fixtures":
        data = {
          me: { profileId: adminId, displayName: "Preview Admin", role: "admin" },
          fixtures: [],
        };
        break;
      case "/api/referee/assignments":
        data = { referees: [], fixtures: [] };
        break;
      case "/api/referee/admin/overview":
        data = { metrics: {}, attention: [], audit: [] };
        break;
      case "/api/referee/admin/support":
        inboxQueries.push(`${url.pathname}${url.search}`);
        data = {
          tickets: [
            supportTicket("10000000-0000-4000-8000-000000000001", "An unrelated account question."),
            supportTicket("10000000-0000-4000-8000-000000000002", markers.supportDetails),
          ],
          activeCount: 2,
        };
        break;
      case "/api/referee/admin/reports":
        inboxQueries.push(`${url.pathname}${url.search}`);
        data = {
          reports: [
            report("20000000-0000-4000-8000-000000000001", "An unrelated player report."),
            report("20000000-0000-4000-8000-000000000002", markers.reportDetails),
          ],
        };
        break;
      case "/api/referee/admin/subjects":
        data = { subjects: [] };
        break;
      case "/api/referee/admin/forfeits":
        data = { forfeits: [] };
        break;
      case "/api/referee/referees":
        data = { staff: [] };
        break;
      default:
        unexpectedRequests.push(`${request.method()} ${url.pathname}`);
        await route.fulfill({ status: 501, body: "Missing UI API fixture." });
        return;
    }
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(data),
    });
  });
  return { unexpectedRequests, inboxQueries };
}

function expectOnlyMockedInboxReads(result: Awaited<ReturnType<typeof mockAdminInboxes>>) {
  expect(result.unexpectedRequests).toEqual([]);
  expect(result.inboxQueries).toContain("/api/referee/admin/support?status=ACTIVE");
  expect(result.inboxQueries).toContain("/api/referee/admin/reports?status=OPEN");
}

test("actual admin overview navigates to matching support and report descriptions", async ({ page }) => {
  const result = await mockAdminInboxes(page);
  await page.goto("/admin");
  await expect(page.getByRole("heading", {
    name: "Every game starts here.",
    exact: true,
  })).toBeVisible();
  await expect(page.getByRole("heading", {
    name: "Overview",
    exact: true,
  })).toHaveCount(0);

  await verifyAdminRequestInboxes(page, markers);
  await expect(page.locator(".admin-report-list > button")).toHaveCount(1);
  await expect(page.getByText("An unrelated player report.", { exact: true })).toHaveCount(0);
  expectOnlyMockedInboxReads(result);
});

test("the shared admin inbox journey waits for delayed initial API loading", async ({ page }) => {
  let releaseInitialLoad!: () => void;
  const initialLoad = new Promise<void>((resolve) => {
    releaseInitialLoad = resolve;
  });
  const result = await mockAdminInboxes(page, initialLoad);
  const journey = verifyAdminRequestInboxes(page, markers);
  try {
    await expect(page.getByRole("status", { name: "Loading admin overview" })).toBeVisible();
    await expect(page.getByPlaceholder("Search tickets")).toHaveCount(0);
    await expect(page.getByPlaceholder("Search reports")).toHaveCount(0);
  } finally {
    releaseInitialLoad();
  }
  await journey;
  await expect(page.getByRole("status", { name: "Loading admin overview" })).toHaveCount(0);
  expectOnlyMockedInboxReads(result);
});
