import { expect, test } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const config = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? config.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname;

// The Phoenix wall time is already past if incorrectly interpreted as Bahrain;
// the actual UTC start is still 5.5 hours away.
test("admin next-games snapshot keeps upcoming Phoenix games and labels the venue timezone", async ({ page }) => {
  await page.clock.install({ time: new Date("2026-10-22T20:00:00Z") });
  const unexpected: string[] = [];
  await page.addInitScript(({ key }) => localStorage.setItem(key, JSON.stringify({
    access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800,
    user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } },
  })), { key: `fieldrush-staff-${project}-auth-v1` });
  await page.route("**/*", async (route) => {
    if (["127.0.0.1", "localhost"].includes(new URL(route.request().url()).hostname)) return route.fallback();
    unexpected.push(route.request().url());
    await route.abort();
  });
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({ json: {} }));
  await page.route("**/api/referee/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() !== "GET") { unexpected.push(path); return route.abort(); }
    const fixture = {
      id: "00000000-0000-4000-8000-000000000002", matchKind: "SOLO", status: "OPEN", operationalState: "NORMAL",
      venue: "Phoenix field", matchDate: "2026-10-22", timeSlot: "6:30 PM - 7:30 PM", timezone: "America/Phoenix",
      startsAt: "2026-10-23T01:30:00Z", endsAt: "2026-10-23T02:30:00Z", players: [], goals: [], events: [], blueCards: [], participantIds: [], clock: null,
      homeClan: { id: "WHITE", name: "White Team", tag: "WHITE", emblem: "W", skillRating: 0 }, awayClan: { id: "BLACK", name: "Black Team", tag: "BLACK", emblem: "B", skillRating: 0 },
    };
    const payloads: Record<string, unknown> = {
      "/api/referee/fixtures": { me: { profileId: "00000000-0000-4000-8000-000000000001", displayName: "Admin", role: "admin" }, fixtures: [fixture] },
      "/api/referee/assignments": { referees: [], fixtures: [] },
      "/api/referee/admin/overview": { metrics: {}, attention: [], audit: [] },
      "/api/referee/admin/reports": { reports: [] },
      "/api/referee/admin/support": { tickets: [], activeCount: 0 },
      "/api/referee/admin/forfeits": { forfeits: [] },
      "/api/referee/admin/subjects": { subjects: [] },
      "/api/referee/referees": { staff: [] },
    };
    if (!(path in payloads)) { unexpected.push(path); return route.fulfill({ status: 501, json: { error: "Missing mock" } }); }
    await route.fulfill({ json: payloads[path] });
  });
  await page.goto("/admin");
  const upcoming = page.locator(".admin-game-snapshot-section").filter({ hasText: "Next 2 games" });
  await expect(upcoming.locator("article")).toHaveCount(1);
  await expect(upcoming.getByText("6:30 PM - 7:30 PM (America/Phoenix)", { exact: false })).toBeVisible();
  await expect(upcoming.getByText("No upcoming games scheduled.")).toHaveCount(0);
  expect(unexpected).toEqual([]);
});
