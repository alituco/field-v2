import { expect, test, type Page } from "@playwright/test";

const matchId = "c0000000-0000-4000-8000-000000000001";
const referenceTime = new Date("2030-01-13T03:54:12.000Z");

function payload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    fixtureId: matchId, fixtureStatus: "LIVE", serverTime: referenceTime.toISOString(),
    scheduledStart: "2030-01-13T03:30:00.000Z", timeZone: "America/Phoenix",
    home: { name: "White Team", tag: "WHITE" }, away: { name: "Black Team", tag: "BLACK" },
    homeScore: 0, awayScore: 1, halftimeSeconds: 1800, halftimePaused: false, latestGoal: null,
    clock: { status: "RUNNING", started_at: referenceTime.toISOString(), accumulated_seconds: 1452, duration_seconds: 3600 },
    ...overrides,
  };
}

async function open(page: Page, state: ReturnType<typeof payload>, legacy = false) {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await page.clock.install({ time: referenceTime });
  await page.route("**/api/broadcast-overlay/open-queue/**", route => {
    expect(route.request().headers().authorization).toBe("Bearer mock-overlay-only");
    return route.fulfill({ json: state });
  });
  await page.goto(`/broadcast/${legacy ? "overlay" : "obs"}/${matchId}?kind=solo#token=mock-overlay-only`);
  await expect(page.locator("#broadcast-scoreboard-root")).toHaveClass(/ready/);
  await page.evaluate(() => document.fonts.ready);
}

test("broadcast matches top-centred split score and green clock design", async ({ page }, info) => {
  await open(page, payload());
  await expect(page.locator('[data-scoreboard="homeLabel"]')).toHaveText("WHITE");
  await expect(page.locator('[data-scoreboard="awayLabel"]')).toHaveText("BLACK");
  await expect(page.locator('[data-scoreboard="clockText"]')).toHaveText("24:12");
  await expect(page.locator('[data-scoreboard="statusText"]')).toHaveText("1ST HALF");
  const bounds = await page.locator(".broadcast-scoreboard-score").boundingBox();
  expect(bounds).toEqual({ x: 728, y: 40, width: 464, height: 96 });
  for (const label of await page.locator(".broadcast-scoreboard-label").all()) {
    expect(await label.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  }
  expect(await page.locator(".broadcast-scoreboard-home").evaluate(el => getComputedStyle(el).backgroundColor)).toBe("rgb(250, 247, 239)");
  expect(await page.locator(".broadcast-scoreboard-away").evaluate(el => getComputedStyle(el).backgroundColor)).toBe("rgb(21, 24, 17)");
  await expect(page.getByText("ON AIR")).toHaveCount(0);
  await page.screenshot({ path: info.outputPath("broadcast-clock.png"), omitBackground: true });
});

test("scheduled kickoff, actual goal and full-time tabs have distinct designs", async ({ page }, info) => {
  const state = payload({ fixtureStatus: "FULL", homeScore: 0, awayScore: 0,
    clock: { status: "NOT_STARTED", started_at: null, accumulated_seconds: 0, duration_seconds: 3600 } });
  await open(page, state);
  await expect(page.locator('[data-scoreboard="clockText"]')).toHaveText("8:30PM");
  await expect(page.locator('[data-scoreboard="statusText"]')).toHaveText("KICKOFF");
  await page.screenshot({ path: info.outputPath("broadcast-kickoff.png"), omitBackground: true });

  Object.assign(state, payload({ latestGoal: { id: "goal-1", createdAt: referenceTime.toISOString(), minute: 25, scorerName: "Ali A.", team: "AWAY" } }));
  await page.clock.runFor(1000);
  await expect(page.locator("#broadcast-scoreboard-root")).toHaveAttribute("data-variant", "goal");
  await expect(page.locator('[data-scoreboard="statusText"]')).toHaveText("GOAL Ali A. 25′");
  await expect(page.locator('[data-scoreboard="clockText"]')).toBeHidden();
  await page.screenshot({ path: info.outputPath("broadcast-goal.png"), omitBackground: true });

  Object.assign(state, payload({ fixtureStatus: "FINAL", clock: { status: "ENDED", started_at: null, accumulated_seconds: 3600, duration_seconds: 3600 } }));
  await page.clock.runFor(1000);
  await expect(page.locator("#broadcast-scoreboard-root")).toHaveAttribute("data-variant", "ended");
  await expect(page.locator('[data-scoreboard="statusText"]')).toHaveText("FT");
  await page.screenshot({ path: info.outputPath("broadcast-fulltime.png"), omitBackground: true });
});

test("same event expires and deleting it cannot reannounce an earlier goal", async ({ page }) => {
  const state = payload({ latestGoal: { id: "goal-2", createdAt: referenceTime.toISOString(), minute: 25, scorerName: "Ali A.", team: "AWAY" } });
  await open(page, state);
  await expect(page.locator("#broadcast-scoreboard-root")).toHaveAttribute("data-variant", "goal");
  // Deletion exposes a still-fresh older row; the monotonic watermark suppresses it.
  state.latestGoal = { id: "goal-1", createdAt: new Date(referenceTime.getTime() - 2000).toISOString(), minute: 24, scorerName: "Earlier scorer", team: "HOME" };
  state.homeScore = 0;
  await page.clock.runFor(1000);
  await expect(page.locator("#broadcast-scoreboard-root")).toHaveAttribute("data-variant", "clock");
  state.latestGoal = { id: "goal-2", createdAt: referenceTime.toISOString(), minute: 25, scorerName: "Ali A.", team: "AWAY" };
  await page.clock.runFor(9000);
  // Poll responses carry current server time in reality, not the frozen fixture timestamp.
  state.serverTime = new Date(referenceTime.getTime() + 10000).toISOString();
  await page.clock.runFor(1000);
  await expect(page.locator("#broadcast-scoreboard-root")).toHaveAttribute("data-variant", "clock");
});

test("legacy overlay forwards to this renderer without exposing the hash token", async ({ page }) => {
  await open(page, payload(), true);
  expect(new URL(page.url()).pathname).toBe(`/broadcast/obs/${matchId}`);
  expect(new URL(page.url()).hash).toBe("#token=mock-overlay-only");
  expect(new URL(page.url()).search).toBe("?kind=solo");
});

test("overlay scales as the same video graphic at 720p", async ({ page }) => {
  await open(page, payload());
  await page.setViewportSize({ width: 1280, height: 720 });
  const bounds = await page.locator(".broadcast-scoreboard-score").boundingBox();
  expect(bounds?.width).toBeCloseTo(464 * 2 / 3, 1);
  expect(bounds?.x).toBeCloseTo((1280 - 464 * 2 / 3) / 2, 1);
  expect(bounds?.y).toBeCloseTo(40 * 2 / 3, 1);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test("multi-digit scores keep both team names readable", async ({ page }) => {
  await open(page, payload({ homeScore: 12, awayScore: 102 }));
  for (const label of await page.locator(".broadcast-scoreboard-label").all()) {
    expect(await label.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  }
  await expect(page.locator('[data-scoreboard="homeScore"]')).toHaveText("12");
  await expect(page.locator('[data-scoreboard="awayScore"]')).toHaveText("102");
});
