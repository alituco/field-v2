import { expect, test, type Page } from "@playwright/test";

import { finishSoloMatch } from "../e2e/support/finish-solo-match";

const gameId = "diagnostic-game";
const project = new URL(
  process.env.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co",
).hostname.split(".")[0];
const timeoutError = "Could not finalize solo game: canceling statement due to statement timeout";

async function mockLiveGame(page: Page, failFinalization: boolean) {
  const writes: Record<string, unknown>[] = [];
  const fixture = {
    id: gameId, matchKind: "SOLO", status: "LIVE", operationalState: null,
    operationalStateUpdatedAt: null, venue: "Isolated finalization test pitch",
    day: "SATURDAY", timeSlot: "6:15 PM - 7:15 PM", matchDate: "2030-01-12",
    timezone: "America/Phoenix", scheduledDurationSeconds: 3600,
    cancellationCode: null, cancellationReason: null, cancelledAt: null, cancelledBy: null,
    homeScore: 1, awayScore: 0, whiteAverageSr: null, blackAverageSr: null,
    matchAverageSr: null, teamSrSpread: null, teamsAssignedAt: "2030-01-12T12:00:00Z",
    homeClan: { id: "WHITE", name: "White Team", tag: "WHITE", emblem: "", skillRating: 0 },
    awayClan: { id: "BLACK", name: "Black Team", tag: "BLACK", emblem: "", skillRating: 0 },
    players: [], participantIds: [], goals: [], events: [], blueCards: [], reliabilityContext: null,
    riskContext: { teams: [], players: [], guidance: "" },
    clock: { status: "RUNNING", startedAt: new Date().toISOString(), accumulatedSeconds: 60, durationSeconds: 3600 },
  };
  await page.addInitScript((key) => localStorage.setItem(key, JSON.stringify({
    access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer",
    expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated" },
  })), `sb-${project}-auth-token`);
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({ status: 200, contentType: "application/json", body: "{}" }));
  await page.route("**/api/referee/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let status = 200;
    let data: unknown = {};
    if (request.method() === "POST") {
      const body = request.postDataJSON() as Record<string, unknown>;
      writes.push(body);
      if (path === `/api/referee/open-queue-games/${gameId}/action` && body.action === "finish") {
        if (failFinalization) {
          status = 400;
          data = { error: timeoutError };
        } else {
          fixture.status = "FINAL";
          fixture.clock.status = "ENDED";
          data = { ok: true };
        }
      }
    } else if (path === "/api/referee/fixtures") {
      data = { me: { profileId: "00000000-0000-4000-8000-000000000001", displayName: "Isolated Referee", role: "admin" }, fixtures: [fixture] };
    } else if (path.includes("broadcast")) {
      data = { broadcast: null, device: null };
    }
    await route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
  });
  await page.goto("/");
  await expect(page.locator(".fixture-status")).toHaveText("Live now");
  await page.locator("details.timer-end-disclosure summary").click();
  return writes;
}

test("finish request reports the actual SQL timeout immediately without retrying", async ({ page }) => {
  const writes = await mockLiveGame(page, true);
  await expect(finishSoloMatch(
    page, gameId, page.getByRole("button", { name: "Finish match", exact: true }),
  )).rejects.toThrow(`Solo match finalization failed (HTTP 400): ${timeoutError}`);
  await expect(page.locator(".error")).toHaveText(timeoutError);
  await expect(page.locator(".fixture-status")).toHaveText("Live now");
  expect(writes).toEqual([{ action: "finish" }]);
});

test("successful finish response retains the final status and locked result assertions", async ({ page }) => {
  const writes = await mockLiveGame(page, false);
  await finishSoloMatch(
    page, gameId, page.getByRole("button", { name: "Finish match", exact: true }),
  );
  await expect(page.locator(".fixture-status")).toHaveText("Finished");
  await expect(page.locator(".result-locked-note")).toContainText(
    "Final result saved. Admin corrections remain fully audited.",
  );
  expect(writes).toEqual([{ action: "finish" }]);
});
