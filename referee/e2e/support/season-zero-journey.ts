import { expect, type Page } from "@playwright/test";

export const journeyDurationSeconds = 30 * 60;

export function completedPlayingDuration(payload: unknown, gameId: string): boolean {
  const state = (payload as { state?: Record<string, unknown> } | null)?.state;
  if (!state || state.game_id !== gameId || state.lifecycle !== "LIVE" ||
      state.scheduled_seconds !== journeyDurationSeconds ||
      typeof state.elapsed_seconds !== "number" || !Number.isFinite(state.elapsed_seconds) ||
      state.elapsed_seconds < 0) {
    throw new Error("E2E match must have the exact live Season 0 state and saved 30-minute duration.");
  }
  return state.elapsed_seconds >= journeyDurationSeconds;
}

export async function waitForPlayingDuration(page: Page, gameId: string, accessToken: string) {
  // Only read the authoritative clock. Never backdate evidence, change the
  // duration after booking, or call a privileged fast-forward for this test.
  const deadline = Date.now() + (journeyDurationSeconds + 90) * 1000;
  while (Date.now() < deadline) {
    const response = await page.request.get(`/api/referee/open-queue-games/${gameId}/participation`, {
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(response.ok(), `Playing-time lookup failed (HTTP ${response.status()}).`).toBe(true);
    const complete = completedPlayingDuration(await response.json(), gameId);
    if (complete) return;
    await page.waitForTimeout(15_000);
  }
  throw new Error("The server clock did not complete the real scheduled playing duration within its bounded wait.");
}
