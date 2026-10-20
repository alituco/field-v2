import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// Run the actual packaged renderer with a fake preload bridge. No Electron,
// camera, filesystem dialog, provider, or shared account is touched by these tests.
type DesktopReply = { ok: boolean; value?: unknown; error?: string };
type TestBridge = {
  actions: { action: string; value: unknown }[];
  push: (patch: Record<string, unknown>) => void;
  finish: (action: string, result: DesktopReply) => void;
};
type TestWindow = Window & { __desktopTest: TestBridge };

const initialState = {
  server: "https://ops-staging.field.bh", development: true, displayName: "Pitch-side Mac",
  recordingDirectory: "/Users/referee/Movies/Fieldrush", freeBytes: 30 * 1024 ** 3,
  pairing: {
    deviceKey: "paired-test-mac", matchKind: "SOLO", matchId: "c0000000-0000-4000-8000-000000000001",
    matchLabel: "White team vs Black team", venue: "Phoenix pitch", expiresAt: "2030-01-02T18:00:00.000Z",
  },
  reachable: true, status: {
    connected: true, configured: true, cameraAvailable: true, microphoneAvailable: true,
    streaming: false, recording: false, audioLevel: 0.2,
  },
  busy: false, progress: null, canPauseUpload: false, hasRecovery: false, outputUncertain: false,
  lastLocalTest: "2030-01-01T18:00:00.000Z", lastStreamTest: "2030-01-01T18:00:00.000Z", version: "0.2.0",
};

async function setup(page: Page, heldActions: string[] = []) {
  await page.addInitScript(({ initial, held }) => {
    let state: Record<string, unknown> = initial;
    let listener: ((next: Record<string, unknown>) => void) | undefined;
    const pending = new Map<string, (reply: DesktopReply) => void>();
    const actions: { action: string; value: unknown }[] = [];
    const target = window as unknown as TestWindow & {
      fieldrush: {
        invoke: (action: string, value?: unknown) => Promise<DesktopReply>;
        onState: (callback: (next: Record<string, unknown>) => void) => void;
      };
    };
    target.__desktopTest = {
      actions,
      push(patch) { state = { ...state, ...patch }; listener?.(state); },
      finish(action, result) {
        const done = pending.get(action);
        if (!done) throw new Error(`No pending action: ${action}`);
        pending.delete(action); done(result);
      },
    };
    target.fieldrush = {
      async invoke(action, value) {
        if (action === "state") return { ok: true, value: state };
        if (action === "preview") return { ok: false, error: "No live preview in isolated UI tests" };
        actions.push({ action, value });
        if (held.includes(action)) return new Promise<DesktopReply>(done => pending.set(action, done));
        return { ok: true };
      },
      onState(callback) { listener = callback; },
    };
  }, { initial: initialState, held: heldActions });
  await page.route("**/*", route => {
    const filename = new URL(route.request().url()).pathname.split("/").pop();
    if (!filename || !["app.html", "app.js", "app.css"].includes(filename)) return route.abort();
    return route.fulfill({
      contentType: filename.endsWith(".html") ? "text/html" : filename.endsWith(".css") ? "text/css" : "text/javascript",
      body: readFileSync(resolve("../broadcaster/src/desktop", filename), "utf8"),
    });
  });
  await page.goto("/desktop-test/app.html");
  await expect(page.locator("#connection")).toHaveText("Camera connected");
}

async function push(page: Page, patch: Record<string, unknown>) {
  await page.evaluate(value => (window as unknown as TestWindow).__desktopTest.push(value), patch);
}
async function finish(page: Page, action: string, result: DesktopReply) {
  await page.evaluate(({ action, result }) => (window as unknown as TestWindow).__desktopTest.finish(action, result), { action, result });
}
async function actionNames(page: Page) {
  return page.evaluate(() => (window as unknown as TestWindow).__desktopTest.actions.map(item => item.action));
}

test("recovery progress stays visible and pause remains usable during a busy upload", async ({ page }, info) => {
  await page.setViewportSize({ width: 1180, height: 900 });
  await setup(page, ["recover-recording"]);
  expect(await actionNames(page)).toEqual([]);
  await page.getByRole("button", { name: "Recover a recording" }).click();
  await push(page, { busy: true, progress: "Uploading match backup · 24%", canPauseUpload: true, hasRecovery: true });
  await expect(page.locator("#progress")).toHaveText("Uploading match backup · 24%");
  await expect(page.locator("#recover-recording")).toBeDisabled();
  await expect(page.locator("#restart-recovery")).toBeDisabled();
  await expect(page.getByRole("button", { name: "Pause upload", exact: true })).toBeEnabled();
  await page.screenshot({ path: info.outputPath("desktop-recovery-progress.png"), fullPage: true });
  await page.getByRole("button", { name: "Pause upload", exact: true }).click();
  expect(await actionNames(page)).toEqual(["recover-recording", "cancel-upload"]);
  await push(page, { busy: false, progress: null, canPauseUpload: false });
  await finish(page, "recover-recording", { ok: false, error: "Upload paused. Select Recover to resume." });
  await expect(page.getByRole("alert")).toHaveText("Upload paused. Select Recover to resume.");
  await expect(page.locator("#progress-panel")).toBeHidden();
  await expect(page.locator("#pause-upload")).toBeHidden();
  await expect(page.locator("#recover-recording")).toBeEnabled();
  await expect(page.locator("#restart-recovery")).toBeEnabled();
  // A pause never automatically discards the backup, restarts it, or attaches it.
  expect(await actionNames(page)).toEqual(["recover-recording", "cancel-upload"]);
  await page.getByRole("button", { name: "Start recovery over", exact: true }).click();
  expect(await actionNames(page)).toEqual(["recover-recording", "cancel-upload", "restart-recovery"]);
});

test("failed private retests clear previous readiness and allow another explicit attempt", async ({ page }) => {
  await setup(page, ["stream-test"]);
  await expect(page.locator("#check-upload")).toHaveClass("passed");
  await page.getByRole("button", { name: "Test private stream", exact: true }).click();
  await push(page, { busy: true, lastStreamTest: null, progress: "Testing the private camera stream…" });
  await expect(page.locator("#check-upload")).not.toHaveClass("passed");
  await expect(page.locator("#stream-test")).toBeDisabled();
  await expect(page.locator("#progress")).toHaveText("Testing the private camera stream…");
  await push(page, { busy: false, progress: null });
  await finish(page, "stream-test", { ok: false, error: "Private test cleanup failed. Retry after reconnecting OBS." });
  await expect(page.getByRole("alert")).toHaveText("Private test cleanup failed. Retry after reconnecting OBS.");
  await expect(page.locator("#check-upload")).not.toHaveClass("passed");
  await expect(page.locator("#toast")).toBeHidden();
  await expect(page.locator("#stream-test")).toBeEnabled();
  await page.locator("#stream-test").click();
  expect(await actionNames(page)).toEqual(["stream-test", "stream-test"]);
});

test("failed local retests cannot leave the old recording check green", async ({ page }) => {
  await setup(page, ["local-test"]);
  await expect(page.locator("#check-recording")).toHaveClass("passed");
  await page.locator("#local-test").click();
  await push(page, { busy: true, lastLocalTest: null, progress: "Testing the local backup…" });
  await expect(page.locator("#check-recording")).not.toHaveClass("passed");
  await push(page, { busy: false, progress: null });
  await finish(page, "local-test", { ok: false, error: "The local recording test did not produce a usable file." });
  await expect(page.getByRole("alert")).toContainText("did not produce a usable file");
  await expect(page.locator("#check-recording")).not.toHaveClass("passed");
  await expect(page.locator("#local-test")).toBeEnabled();
});

test("uncertain OBS output blocks changing the match or recovering over an active recording", async ({ page }) => {
  await setup(page);
  await push(page, { outputUncertain: true, status: { connected: false, configured: false, streaming: false, recording: false } });
  await expect(page.locator("#warning")).toContainText("video may still be running");
  await expect(page.locator("#forget")).toBeDisabled();
  await expect(page.locator("#recover-recording")).toBeDisabled();
  await expect(page.locator("#server")).toBeDisabled();
  await expect(page.locator("#connect")).toBeEnabled();
  await push(page, { pairing: null });
  await expect(page.getByRole("button", { name: "Pair laptop", exact: true })).toBeDisabled();
  expect(await actionNames(page)).toEqual([]);
});

test("progress, match labels and errors are plain text rather than executable markup", async ({ page }) => {
  await setup(page);
  const unsafe = '<img src=x onerror="window.__injected=true">';
  await push(page, { progress: unsafe, error: unsafe, pairing: { ...initialState.pairing, matchLabel: unsafe } });
  for (const id of ["progress", "error", "match-name"]) {
    await expect(page.locator(`#${id}`)).toHaveText(unsafe);
    await expect(page.locator(`#${id} img`)).toHaveCount(0);
  }
  expect(await page.evaluate(() => "__injected" in window)).toBe(false);
});
