import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const env = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? env.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname;
const id = (value: number) => `d1000000-0000-4000-8000-${String(value).padStart(12, "0")}`;
const reason = "The player arrived at minute 30; the referee missed recording it.";
async function setup(page: Page, options: { final?: boolean; failSave?: boolean; conflictAfterFailure?: boolean; conflictPreview?: boolean; terminalPause?: boolean; hangSave?: boolean } = {}) {
  const writes: Record<string, any>[] = [];
  const players = [
    { id: id(1), clanId: "WHITE", displayName: "Ali", role: "ATT", username: "ali", avatarUrl: null, ratingAtTeamAssignment: null },
    { id: id(2), clanId: "BLACK", displayName: "Sam", role: "DEF", username: "sam", avatarUrl: null, ratingAtTeamAssignment: null },
  ];
  const game = {
    id: id(20), matchKind: "SOLO", ratingPolicyId: "field-sr-season0-v2", status: options.final ? "FINAL" : "LIVE",
    minimumPlayers: 2, participationRulesVersion: "s0-configurable-v1", capacity: 14,
    venue: "Diablo Soccer Field 07", timezone: "America/Phoenix", day: "SATURDAY", timeSlot: "5:30 PM - 6:30 PM", matchDate: "2030-01-12",
    scheduledDurationSeconds: 3600, operationalState: "NORMAL", operationalStateUpdatedAt: null,
    cancellationCode: null, cancellationReason: null, cancelledAt: null, cancelledBy: null,
    homeScore: 0, awayScore: 1, whiteAverageSr: 1000, blackAverageSr: 1000, matchAverageSr: 1000, teamSrSpread: 0,
    teamsAssignedAt: "2030-01-12T20:00:00Z",
    homeClan: { id: "WHITE", name: "White Team", tag: "WHITE", emblem: "", skillRating: 0 },
    awayClan: { id: "BLACK", name: "Black Team", tag: "BLACK", emblem: "", skillRating: 0 }, players,
    participantIds: [id(2)], clock: { status: options.final ? "ENDED" : "PAUSED", startedAt: null, accumulatedSeconds: options.final ? 3600 : 1800, durationSeconds: 3600 },
    goals: [], events: [], blueCards: [], reliabilityContext: null, riskContext: { teams: [], players: [], guidance: "" },
  };
  const state = {
    game_id: id(20), revision: 5, lifecycle: options.final ? "FINAL" : "LIVE", rating_status: options.final ? "completed" : "pending_review",
    settlement_status: options.final ? "RATED" : "HELD", referee_can_reopen: Boolean(options.final), can_correct_record: true,
    started_at: "2030-01-13T00:30:00Z", ended_at: options.final ? "2030-01-13T01:30:00Z" : null, white_score: 0, black_score: 1,
    elapsed_seconds: options.final ? 3600 : 1800, scheduled_seconds: 3600, server_now: "2030-01-13T01:00:00Z",
    observed_roster: players.map(player => ({ id: player.id, team: player.clanId === "WHITE" ? "A" : "B", booked_role: player.role })),
    arrivals: [{ profile_id: id(1), arrived_at: null as string | null, attendance_outcome: options.final ? "NO_SHOW" : null },
      { profile_id: id(2), arrived_at: "2030-01-13T00:10:00Z", attendance_outcome: options.final ? "ON_TIME" : null }],
    events: [] as { id: string; type: string; player_id: string | null; second: number; recorded_at: string; note?: string }[], goals: [{ id: id(55), team: "BLACK", profile_id: id(2), assist_profile_id: null, second: 600 }], record_revisions: [],
    audit: { players: { [id(1)]: { actual_seconds: 0, final_state: "NOT_ENTERED", exit_reason: "NONE" }, [id(2)]: { actual_seconds: 1800, final_state: "ACTIVE", exit_reason: "NONE" } } },
  };
  if (options.terminalPause) state.events.push({ id: `${id(99)}:finish`, type: "PAUSE", player_id: null, second: 3600,
    recorded_at: "2030-01-13T01:30:00Z", note: "Referee ended the match." });
  await page.addInitScript(key => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800,
    user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } } })), `fieldrush-staff-${project}-auth-v1`);
  await page.route("**/*.supabase.co/**", route => route.fulfill({ json: {} }));
  await page.route("**/api/referee/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith("/record") && route.request().method() === "POST") {
      const body = route.request().postDataJSON(); writes.push(body);
      if (options.conflictPreview && writes.length === 1) { state.revision++; return route.fulfill({ status: 409, json: { error: "Another referee action changed this record." } }); }
      if (options.conflictAfterFailure && writes.length === 2) { state.revision++; return route.fulfill({ status: 409, json: { error: "This earlier save was not applied; another action changed the match." } }); }
      if (options.hangSave && !body.preview && writes.filter(row => !row.preview).length === 1) return;
      if (options.failSave && !body.preview && writes.filter(row => !row.preview).length === 1) return route.fulfill({ status: 503, json: { error: "Connection interrupted after saving. Retry this same request." } });
      const canonical = structuredClone(body.record);
      if (canonical.arrivals) canonical.arrivals = canonical.arrivals.map((row: { profile_id: string; arrived_at: string | null }) => ({ ...row, arrived_at: row.arrived_at === "now" ? "2030-01-13T01:00:00Z" : row.arrived_at }));
      const nextEvents = canonical.events ? [...state.events.filter(event => event.type === "JOIN"), ...canonical.events] : [...state.events];
      for (const arrival of canonical.arrivals ?? []) {
        const existing = nextEvents.findIndex(event => event.type === "JOIN" && event.player_id === arrival.profile_id);
        if (existing >= 0) nextEvents.splice(existing, 1);
        if (arrival.arrived_at && Date.parse(arrival.arrived_at) > Date.parse(state.started_at)) nextEvents.push({
          id: `${body.requestId}:${arrival.profile_id}`, type: "JOIN", player_id: arrival.profile_id,
          second: Math.floor((Date.parse(arrival.arrived_at) - Date.parse(state.started_at)) / 1000), recorded_at: arrival.arrived_at,
        });
      }
      const next = { ...state, revision: state.revision + 1, events: nextEvents,
        white_score: canonical.goals ? canonical.goals.filter((goal: { team: string }) => goal.team === "WHITE").length : state.white_score,
        black_score: canonical.goals ? canonical.goals.filter((goal: { team: string }) => goal.team === "BLACK").length : state.black_score,
        arrivals: state.arrivals.map(arrival => ({ ...arrival,
        arrived_at: canonical.arrivals?.find((row: { profile_id: string }) => row.profile_id === arrival.profile_id)?.arrived_at ?? arrival.arrived_at })) };
      const impact = { attendance: canonical.arrivals ? [{ profile_id: id(1), changed: true,
        before: { active_strikes: 3, can_book: false }, after: { active_strikes: 2, can_book: true } }] : [], players: [{ profile_id: id(1), display_name: "Ali", rating_track: "OUTFIELD", before: { sr: 1000, matches: 5, game_sr_delta: 0, attendance_outcome: "NO_SHOW", strikes: 2, arrived_at: null },
        after: { sr: 1020, matches: 6, game_sr_delta: 20, attendance_outcome: "LATE", strikes: 1, arrived_at: "2030-01-13T01:00:00Z" } }], dependent_players_changed: 0, dependent_matches_changed: 0 };
      if (!body.preview) Object.assign(state, next);
      return route.fulfill({ json: { state: next, impact, preview: body.preview, record_input: canonical, ...(body.preview ? { preview_token: "verified-preview-token" } : {}) } });
    }
    if (path === "/api/referee/fixtures") return route.fulfill({ json: { me: { profileId: id(9), displayName: "Preview Referee", role: "referee" }, fixtures: [game] } });
    if (path.endsWith("/participation") || path.endsWith("/record")) return route.fulfill({ json: { state } });
    return route.fulfill({ json: { broadcast: null, device: null } });
  });
  await page.goto("/");
  await expect(page.getByRole("button", { name: /Players/ })).toBeVisible();
  return { writes, state, game };
}

async function openLateCorrection(page: Page) {
  await page.getByRole("button", { name: /Players/ }).click();
  await page.getByRole("button", { name: "Correct arrival", exact: true }).first().click();
  await page.getByLabel("Minutes after actual kickoff").fill("30");
  await page.getByLabel("Reason for correction").fill(reason);
}

test("late arrival records arrival and joins play in one action with a server time", async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const { writes } = await setup(page);
  await expect(page.getByRole("button", { name: "Join play", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: /Players/ }).click();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await expect(page.getByLabel("When did they arrive?")).toHaveValue("NOW");
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await expect(page.getByText("Saved. Attendance, playing time and affected ratings are updated together.")).toBeVisible();
  expect(writes).toHaveLength(1);
  expect(writes[0]).toMatchObject({ preview: false, expectedRevision: 5, record: { reason: "", arrivals: [{ profile_id: id(1), arrived_at: "now" }] } });
  expect(writes[0].record.events).toBeUndefined();
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.screenshot({ path: info.outputPath("arrival-recorded-mobile.png"), fullPage: true });
});

test("finished-game correction previews strikes and SR then saves without reopening", async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const { writes, state } = await setup(page, { final: true });
  await openLateCorrection(page);
  await expect(page.getByRole("option", { name: "Arrived now" })).toHaveCount(0);
  await page.getByRole("button", { name: "Review correction", exact: true }).click();
  await expect(page.getByText(/SR 1000 → 1020/)).toBeVisible();
  await expect(page.getByText(/This game’s strikes 2 → 1/)).toBeVisible();
  await expect(page.getByText(/Total active strikes 3 → 2/)).toBeVisible();
  await expect(page.getByText(/Can book games again/)).toBeVisible();
  expect(writes).toHaveLength(1);
  expect(writes[0].preview).toBe(true);
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.screenshot({ path: info.outputPath("finished-correction-preview-mobile.png"), fullPage: true });
  await page.getByRole("button", { name: "Save correction", exact: true }).click();
  await expect(page.getByText("Saved. Attendance, playing time and affected ratings are updated together.")).toBeVisible();
  expect(writes[1].requestId).toBe(writes[0].requestId);
  expect(writes[1].previewToken).toBe("verified-preview-token");
  expect(writes[1].record.arrivals[0].arrived_at).toBe("2030-01-13T01:00:00.000Z");
  expect(state.lifecycle).toBe("FINAL");
  expect(writes.every(row => row.action !== "reopen")).toBe(true);
});

test("uncertain arrival save retains the exact request and disables edits until retry", async ({ page }) => {
  const { writes } = await setup(page, { failSave: true });
  await page.getByRole("button", { name: /Players/ }).click();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await expect(page.getByLabel("When did they arrive?")).toBeDisabled();
  await page.getByRole("button", { name: "Retry same save", exact: true }).click();
  await expect(page.getByText("Saved. Attendance, playing time and affected ratings are updated together.")).toBeVisible();
  expect(writes).toHaveLength(2);
  expect(writes[1]).toEqual(writes[0]);
});

test("a revision conflict preserves the correction draft and requires a new preview", async ({ page }) => {
  const { writes } = await setup(page, { final: true, conflictPreview: true });
  await openLateCorrection(page);
  await page.getByRole("button", { name: "Review correction", exact: true }).click();
  await expect(page.getByText(/Your draft is preserved/)).toBeVisible();
  await page.getByRole("button", { name: "Refresh and keep draft", exact: true }).click();
  await expect(page.getByLabel("Reason for correction")).toHaveValue(reason);
  await expect(page.getByLabel("Minutes after actual kickoff")).toHaveValue("30");
  await page.getByRole("button", { name: "Review correction", exact: true }).click();
  await expect(page.getByRole("button", { name: "Save correction", exact: true })).toBeVisible();
  expect(writes[1].expectedRevision).toBe(6);
  expect(writes[1].requestId).not.toBe(writes[0].requestId);
});

test("the full correction can remove a goal and update attendance in the same reviewed record", async ({ page }, info) => {
  const { writes } = await setup(page, { final: true });
  await page.getByRole("button", { name: /More/ }).click();
  await page.getByRole("button", { name: "Correct match record", exact: true }).click();
  await page.getByLabel("Correct Ali’s arrival").check();
  await page.getByLabel("Minutes after actual kickoff").fill("30");
  await page.getByLabel("Correct goals and score").check();
  await page.getByRole("button", { name: "Remove goal 1", exact: true }).click();
  await page.getByLabel("Reason for correction").fill(reason);
  await page.getByRole("button", { name: "Review correction", exact: true }).click();
  await expect(page.getByRole("button", { name: "Save correction", exact: true })).toBeVisible();
  expect(writes[0].record.goals).toEqual([]);
  expect(writes[0].record.arrivals).toEqual([{ profile_id: id(1), arrived_at: "2030-01-13T01:00:00.000Z" }]);
  expect(writes[0].record.white_score).toBeUndefined();
  await page.screenshot({ path: info.outputPath("match-record-full-correction.png"), fullPage: true });
});


test("a definite conflict after an uncertain save unlocks the preserved draft for reconciliation", async ({ page }) => {
  const { writes } = await setup(page, { failSave: true, conflictAfterFailure: true });
  await page.getByRole("button", { name: /Players/ }).click();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await page.getByRole("button", { name: "Retry same save", exact: true }).click();
  await page.getByRole("button", { name: "Refresh and keep draft", exact: true }).click();
  await expect(page.getByLabel("When did they arrive?")).toBeEnabled();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await expect(page.getByText("Saved. Attendance, playing time and affected ratings are updated together.")).toBeVisible();
  expect(writes[1]).toEqual(writes[0]);
  expect(writes[2].expectedRevision).toBe(6);
  expect(writes[2].requestId).not.toBe(writes[0].requestId);
});


test("a referee can correct the timeline after a real derived late-arrival entry without resubmitting JOIN", async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const { writes, state } = await setup(page);
  await page.getByRole("button", { name: /Players/ }).click();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await expect(page.getByText("Saved. Attendance, playing time and affected ratings are updated together.")).toBeVisible();
  expect(state.events[0].id).toBe(`${writes[0].requestId}:${id(1)}`);
  await page.getByRole("button", { name: /More/ }).click();
  await page.getByRole("button", { name: "Correct match record", exact: true }).click();
  await page.getByLabel("Correct playing time, departures or cards").check();
  await expect(page.getByText(/Ali · arrival \/ joined play at match time 30:00/)).toBeVisible();
  await page.getByRole("button", { name: "Add missed departure, return or clock event", exact: true }).click();
  await page.getByRole("combobox", { name: "Player", exact: true }).selectOption(id(2));
  await page.getByRole("spinbutton", { name: "Minutes after actual kickoff", exact: true }).fill("20");
  await expect(page.getByLabel("Event 2 calculated match time")).toHaveText("20:00");
  await page.getByLabel("Event note", { exact: true }).fill("Injury observed on the pitch");
  await page.getByLabel("Reason for correction").fill("The injury was recorded late; the actual time was minute 20.");
  await page.getByRole("button", { name: "Review correction", exact: true }).click();
  await expect(page.getByRole("button", { name: "Save correction", exact: true })).toBeVisible();
  expect(writes[1].record.events).toEqual([{ id: expect.stringMatching(/^[0-9a-f-]{36}$/), type: "EXCUSED_LEAVE", player_id: id(2),
    second: 1200, recorded_at: "2030-01-13T00:50:00.000Z", note: "Injury observed on the pitch" }]);
  expect(writes[1].record.events.some((event: { type: string }) => event.type === "JOIN")).toBe(false);
  expect(writes[1].record.played_seconds).toBeUndefined();
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.screenshot({ path: info.outputPath("arrival-timeline-correction-mobile.png"), fullPage: true });
});


test("correcting a finished duration omits the generated final pause and explains the finish-time change", async ({ page }) => {
  const { writes } = await setup(page, { final: true, terminalPause: true });
  await page.getByRole("button", { name: /More/ }).click();
  await page.getByRole("button", { name: "Correct match record", exact: true }).click();
  await page.getByLabel("Correct playing time, departures or cards").check();
  await expect(page.getByText("The final whistle is calculated from the actual playing duration above.")).toBeVisible();
  await page.getByLabel("Actual playing duration (minutes:seconds)").fill("25:00");
  await page.getByLabel("Reason for correction").fill("Actual play finished at minute 25; the clock was left running.");
  await page.getByRole("button", { name: "Review correction", exact: true }).click();
  await expect(page.getByRole("button", { name: "Save correction", exact: true })).toBeVisible();
  expect(writes[0].record.played_seconds).toBe(1500);
  expect(writes[0].record.events).toEqual([]);
});


test("a stalled save times out and retries its exact original arrival request", async ({ page }) => {
  const { writes } = await setup(page, { hangSave: true });
  await page.getByRole("button", { name: /Players/ }).click();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await page.getByRole("button", { name: "Record arrival", exact: true }).click();
  await expect(page.getByText("The server has not confirmed this save. Retry the same change to check its result.")).toBeVisible({ timeout: 20_000 });
  await expect(page.getByLabel("When did they arrive?")).toBeDisabled();
  await page.getByRole("button", { name: "Retry same save", exact: true }).click();
  await expect(page.getByText("Saved. Attendance, playing time and affected ratings are updated together.")).toBeVisible();
  expect(writes).toHaveLength(2);
  expect(writes[1]).toEqual(writes[0]);
});
