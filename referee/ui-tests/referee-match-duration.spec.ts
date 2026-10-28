import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const env = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? env.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname;

async function mockGame(page: Page, matchKind: "SOLO" | "CLAN") {
  const writes: Record<string, unknown>[] = [];
  const fixture = {
    id: "duration-game", matchKind, status: matchKind === "SOLO" ? "FULL" : "SCHEDULED",
    venue: "Saved Phoenix pitch", day: "SATURDAY", timeSlot: "6:15 PM - 7:45 PM", matchDate: "2030-01-12",
    scheduledDurationSeconds: 5400, operationalState: null, operationalStateUpdatedAt: null,
    cancellationCode: null, cancellationReason: null, cancelledAt: null, cancelledBy: null,
    homeScore: null, awayScore: null, whiteAverageSr: null, blackAverageSr: null, matchAverageSr: null,
    teamSrSpread: null, teamsAssignedAt: "2030-01-12T12:00:00Z",
    homeClan: { id: "WHITE", name: "White Team", tag: "WHITE", emblem: "", skillRating: 0 },
    awayClan: { id: "BLACK", name: "Black Team", tag: "BLACK", emblem: "", skillRating: 0 },
    players: [
      { id: "white-player", clanId: "WHITE", displayName: "White Player", role: "ATT", username: "white", avatarUrl: null, ratingAtTeamAssignment: null },
      { id: "black-player", clanId: "BLACK", displayName: "Black Player", role: "ATT", username: "black", avatarUrl: null, ratingAtTeamAssignment: null },
    ],
    participantIds: [], clock: null, goals: [], events: [], blueCards: [], reliabilityContext: null,
    riskContext: { teams: [], players: [], guidance: "" },
  };
  await page.addInitScript((key) => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } } })), `fieldrush-staff-${project}-auth-v1`);
  await page.route("**/*.supabase.co/**", (route) => route.fulfill({ status: 200, contentType: "application/json", body: "{}" }));
  await page.route("**/api/referee/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    let data: unknown = {};
    if (route.request().method() !== "GET") {
      writes.push(route.request().postDataJSON());
      data = { ok: true };
    } else if (path === "/api/referee/fixtures") {
      data = { me: { profileId: "00000000-0000-4000-8000-000000000001", displayName: "Preview Referee", role: "referee" }, fixtures: [fixture] };
    } else if (path.includes("broadcast")) {
      data = { broadcast: null, device: null };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(data) });
  });
  return writes;
}

for (const kind of ["SOLO", "CLAN"] as const) {
  test(`${kind} start uses the intended schedule duration contract`, async ({ page }) => {
    const writes = await mockGame(page, kind);
    await page.goto("/");
    await expect(page.getByRole("button", { name: "Start game", exact: true })).toBeVisible();
    await page.getByText("Confirm who is playing", { exact: true }).click();
    await page.getByRole("button", { name: "Select all", exact: true }).first().click();
    await page.getByRole("button", { name: "Select all", exact: true }).click();
    await page.getByRole("button", { name: "Start game", exact: true }).click();
    await expect.poll(() => writes.length).toBe(1);
    expect(writes[0].action).toBe("start");
    expect(writes[0].participantIds).toEqual(["white-player", "black-player"]);
    if (kind === "SOLO") expect(writes[0]).not.toHaveProperty("durationSeconds");
    else expect(writes[0].durationSeconds).toBe(3600);
  });
}
