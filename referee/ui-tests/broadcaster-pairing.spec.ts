import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const env = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? env.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname.split(".")[0];
const matchId = "c0000000-0000-4000-8000-000000000001";
const deviceKey = "paired-mac-1";
const code = "ABCD-EFGH-JKLM";

function fixture(status = "FULL") {
  return {
    id: matchId, matchKind: "SOLO", status, ratingPolicyId: "LEGACY", venue: "Phoenix pitch", day: "SATURDAY",
    timeSlot: "4:30 PM", matchDate: "2030-01-12", timezone: "America/Phoenix", scheduledDurationSeconds: 4200,
    operationalState: null, homeScore: null, awayScore: null, whiteAverageSr: null, blackAverageSr: null,
    matchAverageSr: null, teamSrSpread: null, teamsAssignedAt: null,
    homeClan: { id: "WHITE", name: "White team", tag: "WHITE", emblem: "", skillRating: 0 },
    awayClan: { id: "BLACK", name: "Black team", tag: "BLACK", emblem: "", skillRating: 0 },
    players: [], participantIds: [], clock: null, goals: [], events: [], blueCards: [], reliabilityContext: null,
    riskContext: { teams: [], players: [], guidance: "" },
  };
}

function pairedMac(streaming = false) {
  return { deviceKey, displayName: "Pitch-side Mac", status: streaming ? "STREAMING" : "READY", obsConnected: true,
    obsStreaming: streaming, lastSeenAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
    currentFixtureId: null, currentOpenQueueGameId: streaming ? matchId : null, errorMessage: null };
}

async function setup(page: Page, options: { paired?: boolean; streaming?: boolean; status?: string; expiresSoon?: boolean; rejectDisconnect?: boolean; rejectPair?: boolean; admin?: boolean; rejectForceOnce?: boolean; hideAfterForceFailure?: boolean; revoked?: boolean; testCleanupPending?: boolean } = {}) {
  const state = { device: options.paired ? { ...pairedMac(options.streaming), ...(options.revoked ? { revokedAt: new Date().toISOString(), reservationActive: true, status: "OFFLINE" } : {}), testCleanupPending: options.testCleanupPending ?? false } : null as ReturnType<typeof pairedMac> | null, writes: [] as { path: string; method: string; body: unknown }[], reads: 0 };
  await page.addInitScript((key) => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated" } })), `sb-${project}-auth-token`);
  await page.route("**/*.supabase.co/**", route => route.fulfill({ json: {} }));
  await page.route("**/api/referee/**", async route => {
    const request = route.request();
    const url = new URL(request.url());
    expect(request.headers().authorization).toBe("Bearer ui-test-token");
    if (request.method() !== "GET") state.writes.push({ path: url.pathname, method: request.method(), body: request.postDataJSON() });
    if (url.pathname === "/api/referee/fixtures") {
      await route.fulfill({ json: { me: { profileId: "00000000-0000-4000-8000-000000000001", displayName: "Preview Referee", role: options.admin ? "admin" : "referee" }, fixtures: [fixture(options.status)] } });
    } else if (url.pathname === "/api/referee/broadcast-pairing") {
      if (request.method() === "GET") {
        expect(url.searchParams.get("matchKind")).toBe("SOLO");
        expect(url.searchParams.get("matchId")).toBe(matchId);
        state.reads++;
        await route.fulfill({ json: { device: state.device } });
      } else if (request.method() === "POST") {
        await route.fulfill(options.rejectPair ? { status: 409, json: { error: "A laptop is already paired. Disconnect it first." } } : { json: { code, expiresAt: new Date(Date.now() + (options.expiresSoon ? 1_500 : 600_000)).toISOString() } });
      } else if (options.rejectDisconnect || options.rejectForceOnce && state.writes.filter(item => item.method === "DELETE").length === 1) {
        if (options.hideAfterForceFailure) state.device = null;
        await route.fulfill({ status: 409, json: { error: "Stop the stream before disconnecting this laptop." } });
      } else {
        state.device = null;
        await route.fulfill({ json: { ok: true } });
      }
    } else if (url.pathname.endsWith("/broadcast")) {
      await route.fulfill({ json: { broadcast: options.streaming ? { status: "LIVE", errorMessage: null } : null, device: state.device } });
    } else await route.fulfill({ json: {} });
  });
  await page.goto("/");
  await page.getByRole("button", { name: /More/ }).click();
  await page.getByText("Camera and broadcast", { exact: true }).click();
  const panel = page.getByRole("region", { name: "Broadcast laptop" });
  await expect(panel).toBeVisible();
  await expect(panel.getByText("Checking your laptop…")).toHaveCount(0);
  return { state, panel };
}

test("pairing requires an explicit action and issues a code only for the selected match", async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const { state, panel } = await setup(page);
  expect(state.writes).toEqual([]);
  await expect(page.getByRole("button", { name: "Start Stream", exact: true })).toBeDisabled();
  await panel.getByRole("button", { name: "Create pairing code" }).click();
  await expect(panel.getByText(code, { exact: true })).toBeVisible();
  await expect(panel.getByText(/Expires in/)).toBeVisible();
  expect(state.writes).toEqual([{ path: "/api/referee/broadcast-pairing", method: "POST", body: { matchKind: "SOLO", matchId } }]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: info.outputPath("mac-pairing-mobile.png"), fullPage: true });
});

test("a newly connected laptop replaces the one-use code and refreshes stream readiness", async ({ page }) => {
  const { state, panel } = await setup(page);
  await panel.getByRole("button", { name: "Create pairing code" }).click();
  await expect(panel.getByText(code, { exact: true })).toBeVisible();
  state.device = pairedMac();
  await expect(panel.getByRole("heading", { name: "Pitch-side Mac" })).toBeVisible({ timeout: 8_000 });
  await expect(panel.getByText(code, { exact: true })).toHaveCount(0);
  await expect(panel.getByText("Laptop connected · OBS ready")).toBeVisible();
  await expect(page.getByRole("button", { name: "Start Stream", exact: true })).toBeEnabled();
  await page.getByRole("button", { name: "Start Stream", exact: true }).click();
  expect(state.writes.at(-1)).toEqual({ path: `/api/referee/open-queue-games/${matchId}/broadcast`, method: "POST", body: { action: "start" } });
});

test("disconnecting a shared Mac requires confirmation and only revokes that laptop", async ({ page }) => {
  const { state, panel } = await setup(page, { paired: true });
  await panel.getByRole("button", { name: "Disconnect Mac" }).click();
  expect(state.writes).toEqual([]);
  const confirmation = panel.getByRole("group", { name: "Confirm laptop disconnection" });
  await expect(confirmation).toContainText("local recordings stay on the Mac");
  await confirmation.getByRole("button", { name: "Keep connected" }).click();
  expect(state.writes).toEqual([]);
  await panel.getByRole("button", { name: "Disconnect Mac" }).click();
  await confirmation.getByRole("button", { name: "Disconnect Mac" }).click();
  await expect(panel.getByRole("button", { name: "Create pairing code" })).toBeVisible();
  expect(state.writes).toEqual([{ path: "/api/referee/broadcast-pairing", method: "DELETE", body: { deviceKey } }]);
  await expect(page.getByRole("button", { name: "Start Stream", exact: true })).toBeDisabled();
});

test("a live stream blocks laptop handover and keeps stop-stream available", async ({ page }) => {
  const { state, panel } = await setup(page, { paired: true, streaming: true });
  await expect(panel.getByRole("button", { name: "Disconnect Mac" })).toBeDisabled();
  await expect(panel.getByText("Stop the stream before disconnecting or switching laptops.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Stop Stream" })).toBeEnabled();
  await expect(panel.getByRole("button", { name: "Force disconnect Mac" })).toHaveCount(0);
  expect(state.writes).toEqual([]);
});

test("only admins can force disconnect an active Mac after typing confirmation", async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const { state, panel } = await setup(page, { paired: true, streaming: true, admin: true });
  await panel.getByRole("button", { name: "Force disconnect Mac" }).click();
  const confirmation = panel.getByRole("group", { name: "Confirm forced laptop disconnection" });
  await expect(confirmation.getByRole("button", { name: "Force disconnect", exact: true })).toBeDisabled();
  await confirmation.getByLabel("Type DISCONNECT to confirm").fill("disconnect");
  await expect(confirmation.getByRole("button", { name: "Force disconnect", exact: true })).toBeDisabled();
  expect(state.writes).toEqual([]);
  await confirmation.getByLabel("Type DISCONNECT to confirm").fill("DISCONNECT");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: info.outputPath("admin-disconnect-mobile.png"), fullPage: true });
  await confirmation.getByRole("button", { name: "Force disconnect", exact: true }).click();
  await expect(panel.getByRole("button", { name: "Create pairing code" })).toBeVisible();
  expect(state.writes).toEqual([{ path: "/api/referee/broadcast-pairing", method: "DELETE", body: { deviceKey, force: true } }]);
});

test("a pending private test prevents ordinary handover and offers admin cleanup", async ({ page }) => {
  const { state, panel } = await setup(page, { paired: true, testCleanupPending: true, admin: true });
  await expect(page.getByRole("button", { name: "Start Stream", exact: true })).toBeDisabled();
  await expect(panel.getByText(/A private stream test is still active or needs cleanup/)).toBeVisible();
  await expect(panel.getByRole("button", { name: "Disconnect Mac", exact: true })).toBeDisabled();
  await panel.getByRole("button", { name: "Force disconnect Mac" }).click();
  await panel.getByLabel("Type DISCONNECT to confirm").fill("DISCONNECT");
  await panel.getByRole("button", { name: "Force disconnect", exact: true }).click();
  await expect(panel.getByRole("button", { name: "Create pairing code" })).toBeVisible();
  expect(state.writes).toEqual([{ path: "/api/referee/broadcast-pairing", method: "DELETE", body: { deviceKey, force: true } }]);
});

test("failed forced cleanup stays visible and can be retried even after access was revoked", async ({ page }) => {
  const { state, panel } = await setup(page, { paired: true, streaming: true, admin: true, rejectForceOnce: true, hideAfterForceFailure: true });
  await panel.getByRole("button", { name: "Force disconnect Mac" }).click();
  const confirmation = panel.getByRole("group", { name: "Confirm forced laptop disconnection" });
  await confirmation.getByLabel("Type DISCONNECT to confirm").fill("DISCONNECT");
  await confirmation.getByRole("button", { name: "Force disconnect", exact: true }).click();
  await expect(panel.getByRole("alert")).toBeVisible();
  const reads = state.reads;
  await expect.poll(() => state.reads, { timeout: 8_000 }).toBeGreaterThan(reads);
  await expect(panel.getByRole("heading", { name: "Pitch-side Mac" })).toBeVisible();
  await expect(panel.getByText("Disconnect cleanup needs attention")).toBeVisible();
  await confirmation.getByRole("button", { name: "Force disconnect", exact: true }).click();
  await expect(panel.getByRole("button", { name: "Create pairing code" })).toBeVisible();
  expect(state.writes).toHaveLength(2);
});

test("an admin can resume cleanup for a revoked laptop returned after reload", async ({ page }) => {
  const { state, panel } = await setup(page, { paired: true, revoked: true, admin: true });
  await expect(panel.getByText("Disconnect cleanup needs attention")).toBeVisible();
  await expect(panel.getByRole("button", { name: "Disconnect Mac", exact: true })).toBeDisabled();
  await panel.getByRole("button", { name: "Retry disconnect cleanup" }).click();
  await panel.getByLabel("Type DISCONNECT to confirm").fill("DISCONNECT");
  await panel.getByRole("button", { name: "Force disconnect", exact: true }).click();
  await expect(panel.getByRole("button", { name: "Create pairing code" })).toBeVisible();
  expect(state.writes).toHaveLength(1);
});

test("a server-side disconnect refusal retains the paired Mac and explains the conflict", async ({ page }) => {
  const { panel } = await setup(page, { paired: true, rejectDisconnect: true });
  await panel.getByRole("button", { name: "Disconnect Mac" }).click();
  await panel.getByRole("group", { name: "Confirm laptop disconnection" }).getByRole("button", { name: "Disconnect Mac" }).click();
  await expect(panel.getByRole("alert")).toHaveText("Stop the stream before disconnecting this laptop.");
  await expect(panel.getByRole("heading", { name: "Pitch-side Mac" })).toBeVisible();
  await expect(panel.getByRole("button", { name: "Create pairing code" })).toHaveCount(0);
});

test("an expired code cannot be copied and a replacement requires another action", async ({ page }) => {
  const { state, panel } = await setup(page, { expiresSoon: true });
  await panel.getByRole("button", { name: "Create pairing code" }).click();
  await expect(panel.getByText("This code has expired. Get a new code to connect.")).toBeVisible();
  await expect(panel.getByRole("button", { name: "Copy code" })).toHaveCount(0);
  expect(state.writes).toHaveLength(1);
  await panel.getByRole("button", { name: "Get new code" }).click();
  await expect.poll(() => state.writes.length).toBe(2);
});

for (const status of ["FINAL", "CANCELLED"]) {
  test(`${status} games do not create pairing codes`, async ({ page }) => {
    const { state, panel } = await setup(page, { status });
    await expect(panel.getByText(/Laptop pairing is closed/)).toBeVisible();
    await expect(panel.getByRole("button", { name: "Create pairing code" })).toHaveCount(0);
    expect(state.writes).toEqual([]);
  });
}

test("a rejected pairing request does not show a fictitious code", async ({ page }) => {
  const { state, panel } = await setup(page, { rejectPair: true });
  await panel.getByRole("button", { name: "Create pairing code" }).click();
  await expect(panel.getByRole("alert")).toHaveText("A laptop is already paired. Disconnect it first.");
  await expect(panel.getByText(code, { exact: true })).toHaveCount(0);
  expect(state.writes).toHaveLength(1);
});

test("the setup guide is accessible before an assignment and does not promise an unavailable download", async ({ page }) => {
  await page.goto("/broadcast/setup");
  await expect(page.getByRole("heading", { name: "Your pitch. Live." })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Connect your Osmo by USB-C" })).toBeVisible();
  await expect(page.getByText(/Your Osmo model must support webcam mode/)).toBeVisible();
  await expect(page.getByRole("link", { name: /Download/ })).toHaveCount(0);
});
