import { expect, test, type Page } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";

const env = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const project = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? env.NEXT_PUBLIC_SUPABASE_URL ?? "https://nfdkdhdevpstfspazbfn.supabase.co").hostname;
const gameId = "d1000000-0000-4000-8000-000000000001";
const reason = "Reviewed the full recording and confirmed the actual evidence.";
const fixture = (started = false) => {
  const players = [
    { id: "white-player", clanId: "WHITE", displayName: "White Player", role: "ATT", username: "white", avatarUrl: null, ratingAtTeamAssignment: null },
    { id: "black-player", clanId: "BLACK", displayName: "Black Player", role: "ATT", username: "black", avatarUrl: null, ratingAtTeamAssignment: null },
    ...Array.from({ length: 8 }, (_, index) => ({ id: `other-${index}`, clanId: index % 2 ? "BLACK" : "WHITE", displayName: `Other Player ${index + 1}`, role: "DEF", username: `other${index}`, avatarUrl: null, ratingAtTeamAssignment: null })),
  ];
  return {
  id: gameId, matchKind: "SOLO", ratingPolicyId: "field-sr-season0-v2", status: started ? "FINAL" : "FULL",
  minimumPlayers: 10, participationRulesVersion: "s0-standard-v1", capacity: 14,
  venue: "Saved pitch", day: "SATURDAY", timeSlot: "6:00 PM - 7:00 PM", matchDate: "2030-01-12",
  scheduledDurationSeconds: 3600, operationalState: "NORMAL", operationalStateUpdatedAt: null,
  cancellationCode: null, cancellationReason: null, cancelledAt: null, cancelledBy: null,
  homeScore: started ? 1 : null, awayScore: started ? 0 : null, whiteAverageSr: null, blackAverageSr: null, matchAverageSr: null, teamSrSpread: null,
  teamsAssignedAt: "2030-01-12T12:00:00Z",
  homeClan: { id: "WHITE", name: "White Team", tag: "WHITE", emblem: "", skillRating: 0 },
  awayClan: { id: "BLACK", name: "Black Team", tag: "BLACK", emblem: "", skillRating: 0 },
  players,
  participantIds: [], clock: started ? { status: "ENDED", startedAt: null, accumulatedSeconds: 3600, durationSeconds: 3600 } : null,
  goals: [], events: [], blueCards: [], reliabilityContext: {
    serverNow: "2030-01-12T18:10:00Z", policyVersionId: "refund-policy", kickoffAt: "2030-01-12T18:00:00Z", checkInDeadlineAt: null, noShowCutoffAt: null,
    reserveActivationMinutesAfterKickoff: 5, reserveActivationAt: null, originalPlayerReclaimUntilMinutesAfterKickoff: 10, originalPlayerReclaimUntilAt: null,
    replacementOrder: ["EMERGENCY_NOTIFICATION", "ON_FIELD_RESERVE", "PLAY_SHORTHANDED"], reservePlanAutomated: false, reservePlanAuthority: "FIELD_HOST",
    canCheckIn: true, canFinalizeAttendance: false, attendanceFinalized: false, expectedCount: 10, checkedInCount: 10, onTimeCount: 10, lateCount: 0, missingCount: 0,
    players: players.map(player => ({ attendanceRecordId: null, profileId: player.id, displayName: player.displayName, expectedForMatch: true, checkInEligible: true, teamId: null, teamName: null, side: player.clanId, role: player.role, checkedInAt: "2030-01-12T17:50:00Z", checkInTiming: "EARLY", outcome: null, status: "CHECKED_IN", isCheckedIn: true, checkInRevision: 1, canRemoveCheckIn: false })),
    verifiedInjuries: [], openShorthandedPeriods: [],
  }, riskContext: { teams: [], players: [], guidance: "" },
}; };
function reviewState() {
  return { game_id: gameId, revision: 3, lifecycle: "REVIEW", rating_status: "pending_review", settlement_status: "HELD", elapsed_seconds: 3600, scheduled_seconds: 3600,
    server_now: "2030-01-12T19:00:00Z", observed_roster: [
      { id: "white-player", team: "A", booked_role: "ATT", sr_before: 1937 }, { id: "black-player", team: "B", booked_role: "ATT", sr_before: 1941 },
    ], events: [{ id: "event-one", type: "EXCUSED_LEAVE", player_id: "white-player", second: 1800, recorded_at: "2030-01-12T18:30:00.123456Z", note: "Injury recorded", actor_id: "old-actor" }],
    audit: { players: { "white-player": { actual_seconds: 1800, final_state: "EXCUSED", exit_reason: "INJURY" }, "black-player": { actual_seconds: 3600, final_state: "ACTIVE", exit_reason: "NONE" } } } };
}
async function auth(page: Page) {
  await page.addInitScript(key => localStorage.setItem(key, JSON.stringify({ access_token: "ui-test-token", refresh_token: "ui-test-refresh", token_type: "bearer", expires_at: 4102444800, user: { id: "00000000-0000-4000-8000-000000000001", aud: "authenticated", app_metadata: { fieldrush_account_type: "staff" } } })), `fieldrush-staff-${project}-auth-v1`);
  await page.route("**/*.supabase.co/**", route => route.fulfill({ json: {} }));
}
async function referee(page: Page, options: { reject?: boolean; started?: boolean; unassigned?: number; stale?: boolean; invalidateAssignment?: boolean; live?: boolean; legacy?: boolean; minimum?: number; players?: number } = {}) {
  await auth(page);
  const writes: Record<string, unknown>[] = [];
  const game = fixture(options.started);
  if (options.minimum !== undefined) {
    game.minimumPlayers = options.minimum;
    game.participationRulesVersion = "s0-configurable-v1";
    game.status = "OPEN";
  }
  if (options.players !== undefined) {
    game.players = game.players.slice(0, options.players);
    game.reliabilityContext.players = game.reliabilityContext.players.slice(0, options.players);
    game.reliabilityContext.expectedCount = game.reliabilityContext.checkedInCount = options.players;
  }
  if (options.unassigned !== undefined) {
    game.status = "OPEN";
    game.teamsAssignedAt = "";
    game.players = Array.from({ length: options.unassigned }, (_, index) => ({ ...game.players[0], id: `player-${index}`, displayName: `Player ${index + 1}`, clanId: "UNASSIGNED" }));
  }
  if (options.stale) {
    game.teamsAssignedAt = "";
    game.players.at(-1)!.clanId = "UNASSIGNED";
  }
  if (options.live) {
    game.status = "LIVE";
    game.clock = { status: "PAUSED", startedAt: null, accumulatedSeconds: 300, durationSeconds: 3600 };
  }
  if (options.legacy) game.ratingPolicyId = "legacy";
  await page.route("**/api/referee/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() === "POST") {
      const body = route.request().postDataJSON(); writes.push(body);
      if (body.action === "assign_teams") {
        game.teamsAssignedAt = options.invalidateAssignment ? "" : "2030-01-12T17:50:00Z";
        game.players.forEach((player, index) => { if (player.clanId === "UNASSIGNED") player.clanId = index % 2 ? "BLACK" : "WHITE"; });
        return route.fulfill({ json: { ok: true, assignment: { game_id: gameId, action: "ASSIGN" } } });
      }
      if (body.action === "record_verified_injury") return route.fulfill({ json: { ok: true } });
      if (options.reject) return route.fulfill({ status: 400, json: { error: "Accepted parties must stay together after a transfer." } });
      for (const move of body.moves) game.players.find(player => player.id === move.profile_id)!.clanId = move.to_team;
      game.teamsAssignedAt = "2030-01-12T17:50:00Z";
      return route.fulfill({ json: { ok: true, rebalance: { game_id: gameId, action: "REBALANCE" } } });
    }
    if (path === "/api/referee/fixtures") return route.fulfill({ json: { me: { profileId: "referee", displayName: "Preview Referee", role: "referee" }, fixtures: [game] } });
    if (path.endsWith("/participation")) return route.fulfill({ json: { state: options.started ? reviewState() : null } });
    return route.fulfill({ json: { broadcast: null, device: null } });
  });
  await page.goto("/");
  return writes;
}
async function admin(page: Page, conflict = false, lifecycle = "REVIEW") {
  await auth(page);
  const writes: Record<string, unknown>[] = [];
  let state = { ...reviewState(), lifecycle };
  await page.route("**/api/referee/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith("/rating-review")) {
      if (route.request().method() === "POST") {
        const body = route.request().postDataJSON(); writes.push(body);
        if (conflict) return route.fulfill({ status: 409, json: { error: "Refresh the changed match before adjudicating." } });
        state = { ...state, revision: 4, rating_status: body.resolution.status, settlement_status: "RATED" };
      }
      return route.fulfill({ json: { state } });
    }
    return route.fulfill({ json: { detail: { fixture: fixture(true), currency: "USD", pricing: null, formation: null,
      participants: { matchKind: "SOLO", matchId: gameId, status: "FINAL", capacity: 14, capacityPerSide: 7, registeredPlayers: [], actualPlayers: [], withdrawnPlayers: [], counts: { registered: 0, actual: 0, withdrawn: 0 } },
      reserves: { active: [], history: [] }, assignedReferee: null, ratingSummary: { kind: "SOLO", whiteAverageSr: null, blackAverageSr: null, matchAverageSr: null, teamSrSpread: null, ratedPlayers: 0 }, audit: [], reports: [], stoppages: [], resolutionCase: null,
    } } });
  });
  await page.goto(`/admin/games/solo/${gameId}`);
  return writes;
}

async function adminMissingData(page: Page, options: {
  started?: boolean;
  stateError?: boolean;
  missingState?: boolean;
  previewConflict?: boolean;
  saveConflict?: boolean;
} = {}) {
  await auth(page);
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  const game = { ...fixture(), operationalState: "NO_DATA" };
  const caseData = {
    id: "missing-data-case", matchKind: "SOLO", state: "NO_DATA", reasonCode: "RESULT_MISSING",
    scheduledEndAt: "2030-01-12T19:00:00Z", detectedAt: "2030-01-12T20:00:00Z",
    highPriorityAt: "2030-01-13T20:00:00Z", resolvedAt: null, resolvedBy: null,
    currentRevision: 0, evidenceSnapshot: {}, policySnapshot: {},
    createdAt: "2030-01-12T20:00:00Z", updatedAt: "2030-01-12T20:00:00Z",
    revisions: [], refunds: [], disputes: [],
  };
  await page.route("**/api/referee/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith("/rating-review")) {
      if (options.stateError) return route.fulfill({ status: 503, json: { error: "Rating evidence is temporarily unavailable." } });
      if (options.missingState) return route.fulfill({ json: {} });
      return route.fulfill({ json: { state: options.started ? reviewState() : null } });
    }
    if (route.request().method() === "POST") {
      const body = route.request().postDataJSON();
      writes.push({ path, body });
      if (path.endsWith("/resolution/preview")) {
        if (options.previewConflict) return route.fulfill({ status: 409, json: { error: "This match started or changed. Refresh before resolving it." } });
        return route.fulfill({ json: { preview: {
          preview: true, case_id: caseData.id, current_revision: 0, next_revision: 1,
          is_correction: false, resolution_type: body.resolutionType, would_set_case_state: "RESOLVED",
          consequences: { home_refund_bps: 10000, away_refund_bps: 10000, home_sr_delta: 0, away_sr_delta: 0, home_strikes: 0, away_strikes: 0 },
          refunds: [],
        } } });
      }
      expect(path).toBe(`/api/referee/admin/games/solo/${gameId}/resolution`);
      if (options.saveConflict) return route.fulfill({ status: 409, json: { error: "This match started or changed. Refresh before resolving it." } });
      caseData.state = "RESOLVED";
      caseData.currentRevision = 1;
      game.status = "CANCELLED";
      game.operationalState = "NORMAL";
      return route.fulfill({ json: { ok: true } });
    }
    return route.fulfill({ json: { detail: { fixture: game, currency: "USD", pricing: null, formation: null,
      participants: { matchKind: "SOLO", matchId: gameId, status: game.status, capacity: 14, capacityPerSide: 7,
        registeredPlayers: [], actualPlayers: [], withdrawnPlayers: [], counts: { registered: 0, actual: 0, withdrawn: 0 } },
      reserves: { active: [], history: [] }, assignedReferee: null,
      ratingSummary: { kind: "SOLO", whiteAverageSr: null, blackAverageSr: null, matchAverageSr: null, teamSrSpread: null, ratedPlayers: 0 },
      audit: [], reports: [], stoppages: [], resolutionCase: caseData,
    } } });
  });
  await page.goto(`/admin/games/solo/${gameId}`);
  return writes;
}

async function chooseUnstartedCancellation(page: Page, outcome: string, entry = "Review & resolve no data") {
  await page.getByRole("button", { name: entry, exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Resolve missing match data" });
  await expect(dialog.getByRole("button", { name: "Field / venue cancellation", exact: false })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Administrative void", exact: false })).toBeVisible();
  for (const forbidden of ["Recorded result", "Home / white no-show", "Away / black no-show", "Both sides no-show", "Mutual cancellation", "Both sides at fault"]) {
    await expect(dialog.getByRole("button", { name: forbidden, exact: false })).toHaveCount(0);
  }
  await dialog.getByRole("button", { name: outcome, exact: false }).click();
  await dialog.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(dialog.getByText("Advanced overrides", { exact: true })).toHaveCount(0);
  await expect(dialog.getByRole("spinbutton")).toHaveCount(0);
  await expect(dialog.getByRole("combobox")).toHaveCount(0);
  return dialog;
}

for (const [outcome, resolutionType, entry] of [
  ["Field / venue cancellation", "FIELD_OR_VENUE_CANCELLATION", "Review & resolve no data"],
  ["Administrative void", "ADMINISTRATIVE_VOID", "Cancel game"],
]) {
  test(`unstarted Season 0 missing data can use ${outcome.toLowerCase()} with policy-only consequences`, async ({ page }) => {
    const writes = await adminMissingData(page);
    const dialog = await chooseUnstartedCancellation(page, outcome, entry);
    expect(writes).toHaveLength(0);
    await dialog.getByRole("button", { name: "Continue", exact: true }).click();
    await expect(dialog.getByText("Exact server-calculated preview", { exact: true })).toBeVisible();
    const confirm = dialog.getByRole("button", { name: "Confirm and resolve", exact: true });
    await expect(confirm).toBeDisabled();
    await dialog.getByLabel("Evidence and reason · required").fill(reason);
    await confirm.click();
    await expect(dialog).toHaveCount(0);
    expect(writes).toEqual([
      { path: `/api/referee/admin/games/solo/${gameId}/resolution/preview`, body: {
        expectedRevision: 0, resolutionType, reason: "Consequence preview before admin confirmation.", payload: {},
      } },
      { path: `/api/referee/admin/games/solo/${gameId}/resolution`, body: { expectedRevision: 0, resolutionType, reason, payload: {} } },
    ]);
    await expect(page.getByRole("button", { name: "Cancel game", exact: true })).toBeDisabled();
  });
}

test("unstarted cancellation surfaces a stale preview and cannot proceed to confirmation", async ({ page }) => {
  const writes = await adminMissingData(page, { previewConflict: true });
  const dialog = await chooseUnstartedCancellation(page, "Field / venue cancellation");
  await dialog.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(dialog.getByText("This match started or changed. Refresh before resolving it.", { exact: true })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Confirm and resolve", exact: true })).toHaveCount(0);
  expect(writes).toHaveLength(1);
  expect(writes[0].path).toMatch(/\/resolution\/preview$/);
});

test("unstarted cancellation preserves the audited reason when the final save becomes stale", async ({ page }) => {
  const writes = await adminMissingData(page, { saveConflict: true });
  const dialog = await chooseUnstartedCancellation(page, "Administrative void");
  await dialog.getByRole("button", { name: "Continue", exact: true }).click();
  await dialog.getByLabel("Evidence and reason · required").fill(reason);
  await dialog.getByRole("button", { name: "Confirm and resolve", exact: true }).click();
  await expect(dialog.getByText("This match started or changed. Refresh before resolving it.", { exact: true })).toBeVisible();
  await expect(dialog.getByLabel("Evidence and reason · required")).toHaveValue(reason);
  expect(writes).toHaveLength(2);
  expect(writes[1].body).toEqual({ expectedRevision: 0, resolutionType: "ADMINISTRATIVE_VOID", reason, payload: {} });
});

test("started Season 0 missing data stays on rating review and cannot enter unstarted cancellation", async ({ page }) => {
  const writes = await adminMissingData(page, { started: true });
  const panel = page.getByRole("region", { name: "Rating review" });
  await expect(panel.getByRole("button", { name: "Review outcome or correct evidence" })).toBeEnabled();
  await expect(page.getByRole("button", { name: "Cancel game", exact: true })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Review & resolve no data", exact: true })).toHaveCount(0);
  await expect(page.getByRole("region", { name: "Match data resolution" }).getByRole("button", { name: "Resolve match", exact: true })).toHaveCount(0);
  expect(writes).toHaveLength(0);
});

test("failed kickoff evidence load cannot expose unstarted Season 0 cancellation", async ({ page }) => {
  const writes = await adminMissingData(page, { stateError: true });
  await expect(page.getByRole("region", { name: "Rating review" }).getByRole("alert")).toHaveText("Rating evidence is temporarily unavailable.");
  await expect(page.getByRole("button", { name: "Cancel game", exact: true })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Review & resolve no data", exact: true })).toHaveCount(0);
  await expect(page.getByRole("region", { name: "Match data resolution" }).getByRole("button", { name: "Resolve match", exact: true })).toHaveCount(0);
  expect(writes).toHaveLength(0);
});

test("missing kickoff state is not mistaken for a confirmed unstarted game", async ({ page }) => {
  const writes = await adminMissingData(page, { missingState: true });
  await expect(page.getByRole("region", { name: "Rating review" }).getByRole("alert")).toBeVisible();
  await expect(page.getByRole("button", { name: "Cancel game", exact: true })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Review & resolve no data", exact: true })).toHaveCount(0);
  await expect(page.getByRole("region", { name: "Match data resolution" }).getByRole("button", { name: "Resolve match", exact: true })).toHaveCount(0);
  expect(writes).toHaveLength(0);
});

test("refresh failure invalidates earlier confirmation that kickoff has not happened", async ({ page }) => {
  const writes = await adminMissingData(page);
  await expect(page.getByRole("button", { name: "Cancel game", exact: true })).toBeEnabled();
  await page.route("**/rating-review", route => route.fulfill({ status: 503, json: { error: "Rating evidence is temporarily unavailable." } }));
  const panel = page.getByRole("region", { name: "Rating review" });
  await panel.getByRole("button", { name: "Refresh rating evidence", exact: true }).click();
  await expect(panel.getByRole("alert")).toHaveText("Rating evidence is temporarily unavailable.");
  await expect(page.getByRole("button", { name: "Cancel game", exact: true })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Review & resolve no data", exact: true })).toHaveCount(0);
  expect(writes).toHaveLength(0);
});

test("configured 1v1 and odd-player games enable kickoff once their actual minimum is met", async ({ page }) => {
  for (const [minimum, players] of [[2, 2], [3, 3]]) {
    await referee(page, { minimum, players });
    await expect(page.getByRole("button", { name: "Start game", exact: true })).toBeEnabled();
    await expect(page.getByText(new RegExp(`At least ${minimum} actual players total`)).first()).toBeVisible();
    await page.unroute("**/api/referee/**");
  }
});

test("a small roster below its saved minimum and old S0 games cannot start", async ({ page }) => {
  await referee(page, { minimum: 4, players: 3 });
  await expect(page.getByRole("button", { name: "Start game", exact: true })).toBeDisabled();
  await page.unroute("**/api/referee/**");
  await referee(page, { players: 2 });
  await expect(page.getByRole("button", { name: "Start game", exact: true })).toBeDisabled();
});

test("configured two-player rosters can be assigned while the game is still OPEN", async ({ page }) => {
  const writes = await referee(page, { minimum: 2, unassigned: 2 });
  const panel = page.getByRole("region", { name: "Rebalance assigned teams" });
  await expect(panel.getByText(/At least 2 and at most 14/)).toBeVisible();
  await panel.getByRole("button", { name: "Assign booked players to teams" }).click();
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0]).toMatchObject({ action: "assign_teams" });
});

test("pre-kickoff multi-player move requires consent and reason, then refreshes assignments", async ({ page }) => {
  const writes = await referee(page);
  const panel = page.getByRole("region", { name: "Rebalance assigned teams" });
  await panel.getByRole("button", { name: "Review team moves" }).click();
  await panel.getByLabel("Team for White Player").selectOption("BLACK");
  await panel.getByLabel("Team for Black Player").selectOption("WHITE");
  await panel.getByLabel("Reason for team changes").fill(reason);
  await expect(panel.getByRole("button", { name: "Save team changes" })).toBeDisabled();
  await panel.getByLabel(/White Player agreed to move/).check();
  await panel.getByLabel(/Black Player agreed to move/).check();
  await panel.getByRole("button", { name: "Save team changes" }).click();
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0]).toMatchObject({ action: "rebalance", reason, moves: [{ profile_id: "white-player", to_team: "BLACK", consented: true }, { profile_id: "black-player", to_team: "WHITE", consented: true }] });
  expect(writes[0].requestId).toMatch(/^[0-9a-f-]{36}$/);
  await expect(panel.getByRole("form")).toHaveCount(0);
  await panel.getByRole("button", { name: "Review team moves" }).click();
  await expect(panel.getByLabel("Team for White Player")).toHaveValue("BLACK");
});

test("ten booked players can be assigned without starting a clock", async ({ page }) => {
  const writes = await referee(page, { unassigned: 10 });
  const panel = page.getByRole("region", { name: "Rebalance assigned teams" });
  await expect(panel.getByText(/10 booked players/)).toBeVisible();
  await panel.getByRole("button", { name: "Assign booked players to teams" }).click();
  await expect(panel.getByRole("button", { name: "Review team moves" })).toBeVisible();
  expect(writes).toHaveLength(1);
  expect(writes[0]).toEqual({ action: "assign_teams", requestId: expect.stringMatching(/^[0-9a-f-]{36}$/) });
  await expect(page.getByRole("button", { name: "Start game", exact: true })).toBeVisible();
});

test("fewer than ten bookings cannot use initial assignment", async ({ page }) => {
  const writes = await referee(page, { unassigned: 9 });
  const panel = page.getByRole("region", { name: "Rebalance assigned teams" });
  await expect(panel.getByRole("button", { name: "Assign booked players to teams" })).toBeDisabled();
  await expect(panel.getByText(/At least 10 and at most 14/)).toBeVisible();
  expect(writes).toHaveLength(0);
});

test("stale roster keeps existing teams and assigns a new slot without invented move consent", async ({ page }) => {
  const writes = await referee(page, { stale: true });
  const panel = page.getByRole("region", { name: "Rebalance assigned teams" });
  await expect(panel.getByRole("button", { name: "Confirm roster without moving players" })).toBeEnabled();
  await panel.getByRole("button", { name: "Review team moves" }).click();
  await expect(panel.getByLabel("Team for White Player")).toHaveValue("WHITE");
  await expect(panel.getByText(/Choose a team for every unassigned/)).toBeVisible();
  await panel.getByLabel("Reason for team changes").fill(reason);
  await expect(panel.getByRole("button", { name: "Save team changes" })).toBeDisabled();
  await panel.getByLabel("Team for Other Player 8").selectOption("BLACK");
  await expect(panel.getByLabel(/Other Player 8 agreed to move/)).toHaveCount(0);
  await panel.getByRole("button", { name: "Save team changes" }).click();
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0]).toMatchObject({ moves: [{ profile_id: "other-7", to_team: "BLACK", consented: false }] });
  await expect(panel.getByRole("button", { name: "Confirm roster without moving players" })).toHaveCount(0);
});

test("a later invalidation can be confirmed again without remounting the panel", async ({ page }) => {
  const writes = await referee(page, { stale: true, invalidateAssignment: true });
  const panel = page.getByRole("region", { name: "Rebalance assigned teams" });
  const confirm = panel.getByRole("button", { name: "Confirm roster without moving players" });
  await confirm.click();
  await expect(confirm).toBeEnabled();
  await confirm.click();
  await expect.poll(() => writes.length).toBe(2);
  expect(writes[0].requestId).not.toBe(writes[1].requestId);
});

test("Season 0 injury evidence is refund-only and cannot enable external replacement", async ({ page }) => {
  const writes = await referee(page, { live: true });
  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.getByRole("button", { name: /Injury refund evidence/ }).click();
  await expect(page.getByText("Host reserve plan", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /Team playing short/ })).toHaveCount(0);
  await expect(page.getByText(/This is refund evidence only/)).toContainText("does not change SR, attendance or playing time");
  await page.getByRole("button", { name: /Verify injury/ }).click();
  const dialog = page.getByRole("dialog", { name: "Record an injury" });
  await expect(dialog.getByLabel("Replacement available")).toHaveCount(0);
  await expect(dialog.getByText(/does not promise a refund/)).toContainText("Use Playing time separately");
  await dialog.getByRole("button", { name: "Record verified injury" }).click();
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0]).toMatchObject({ action: "record_verified_injury", profileId: "white-player", replacementAvailable: false, unableToContinue: true, matchContinued: true });
});

test("legacy injury evidence retains its original replacement and shorthanded controls", async ({ page }) => {
  await referee(page, { live: true, legacy: true });
  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.getByRole("button", { name: /Match operations/ }).click();
  await expect(page.getByText("Host reserve plan", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: /Team playing short/ })).toBeVisible();
  await page.getByRole("button", { name: /Verify injury/ }).click();
  await expect(page.getByRole("dialog").getByLabel("Replacement available")).toBeVisible();
});

test("rebalance rejection keeps the draft and reuses the same request on retry", async ({ page }) => {
  const writes = await referee(page, { reject: true });
  const panel = page.getByRole("region", { name: "Rebalance assigned teams" });
  await panel.getByRole("button", { name: "Review team moves" }).click();
  await panel.getByLabel("Team for White Player").selectOption("BLACK");
  await panel.getByLabel(/White Player agreed to move/).check();
  await panel.getByLabel("Reason for team changes").fill(reason);
  await panel.getByRole("button", { name: "Save team changes" }).click();
  await expect(panel.getByRole("alert")).toHaveText(/Accepted parties/);
  await expect(panel.getByLabel("Reason for team changes")).toHaveValue(reason);
  await panel.getByRole("button", { name: "Save team changes" }).click();
  await expect.poll(() => writes.length).toBe(2);
  expect(writes[0].requestId).toBe(writes[1].requestId);
});

test("kickoff locks the rebalance controls", async ({ page }) => {
  await referee(page, { started: true });
  await expect(page.getByRole("heading", { name: "Playing time" })).toBeVisible();
  await expect(page.getByRole("region", { name: "Rebalance assigned teams" })).toHaveCount(0);
});

test("admin corrects bounded evidence without SR or actor inputs and preserves payment controls", async ({ page }, info) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const writes = await admin(page);
  const panel = page.getByRole("region", { name: "Rating review" });
  await expect(panel.getByText("Held for review", { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Reserve player", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Cancel game", exact: true })).toBeVisible();
  await panel.getByRole("button", { name: "Review outcome or correct evidence" }).click();
  await panel.getByLabel("Rating outcome").selectOption("completed");
  await panel.getByLabel("White final score").fill("3");
  await panel.getByLabel("Black final score").fill("1");
  await panel.getByLabel("Correct participation timeline").check();
  await panel.getByLabel("Event 1 clock second").fill("1700");
  await panel.getByLabel("Evidence and reason for review").fill(reason);
  await expect(panel.getByRole("button", { name: "Save review and replay" })).toBeDisabled();
  await panel.getByLabel("I verified this evidence", { exact: false }).check();
  await expect(panel.getByText("1937", { exact: true })).toHaveCount(0);
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.screenshot({ path: info.outputPath("season-zero-review-mobile.png"), fullPage: true });
  await panel.getByRole("button", { name: "Save review and replay" }).click();
  await expect(panel.getByText("Rated", { exact: true })).toBeVisible();
  expect(writes).toHaveLength(1);
  expect(writes[0]).toMatchObject({ expectedRevision: 3, resolution: { status: "completed", white_score: 3, black_score: 1, winner: "A", played_seconds: 3600, reason } });
  const resolution = writes[0].resolution as { events: Record<string, unknown>[] };
  expect(resolution.events[0]).toEqual({ id: "event-one", type: "EXCUSED_LEAVE", player_id: "white-player", second: 1700, recorded_at: "2030-01-12T18:30:00.123456Z", note: "Injury recorded" });
});

test("stale admin revision keeps evidence draft but blocks another save until refresh", async ({ page }) => {
  const writes = await admin(page, true);
  const panel = page.getByRole("region", { name: "Rating review" });
  await panel.getByRole("button", { name: "Review outcome or correct evidence" }).click();
  await panel.getByLabel("Evidence and reason for review").fill(reason);
  await panel.getByLabel("I verified this evidence", { exact: false }).check();
  await panel.getByRole("button", { name: "Save review and replay" }).click();
  await expect(panel.getByRole("alert")).toHaveText(/Refresh the changed match/);
  await expect(panel.getByLabel("Evidence and reason for review")).toHaveValue(reason);
  await expect(panel.getByRole("button", { name: "Save review and replay" })).toBeDisabled();
  expect(writes).toHaveLength(1);
  await panel.getByRole("button", { name: "Cancel review" }).click();
  await expect(panel.getByRole("button", { name: "Review outcome or correct evidence" })).toBeEnabled();
});

test("review distinguishes rating-only outcomes from policy cancellation refunds", async ({ page }) => {
  const writes = await admin(page);
  const panel = page.getByRole("region", { name: "Rating review" });
  await panel.getByRole("button", { name: "Review outcome or correct evidence" }).click();
  for (const outcome of ["no_contest", "unranked"]) {
    await panel.getByLabel("Rating outcome").selectOption(outcome);
    await expect(panel.getByText(/No SR or counted-match credit/)).toContainText("does not automatically refund payments or change attendance");
  }
  await panel.getByLabel("Rating outcome").selectOption("cancelled");
  await expect(panel.getByText(/Cancel the game using the existing cancellation policy/)).toContainText("applicable refund workflow");
  await panel.getByLabel("Evidence and reason for review").fill(reason);
  await panel.getByLabel("I verified this evidence", { exact: false }).check();
  await panel.getByRole("button", { name: "Save review and replay" }).click();
  await expect(panel.getByRole("status")).toContainText("applicable refund workflow");
  expect(writes[0]).toMatchObject({ resolution: { status: "cancelled", reason } });
});

test("finalized rating review disables cancellation and directs manual refund review", async ({ page }) => {
  const writes = await admin(page, false, "FINAL");
  const panel = page.getByRole("region", { name: "Rating review" });
  await panel.getByRole("button", { name: "Review outcome or correct evidence" }).click();
  await expect(panel.getByRole("option", { name: "Cancel game (policy refunds)" })).toHaveJSProperty("disabled", true);
  await expect(panel.getByText(/A finalized game cannot be cancelled here/)).toContainText("manual refund review");
  await panel.getByLabel("Rating outcome").selectOption("unranked");
  await expect(panel.getByText(/No SR or counted-match credit/)).toBeVisible();
  expect(writes).toHaveLength(0);
});
