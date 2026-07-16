import assert from "node:assert/strict";
import test from "node:test";

import {
  buildRefereeRiskSignals,
  riskContextFor,
} from "../src/lib/referee-risk-context.ts";

const PLAYER = "11111111-1111-4111-8111-111111111111";
const CLAN = "22222222-2222-4222-8222-222222222222";
const NOW = new Date("2026-07-15T12:00:00.000Z");

function playerReport(overrides = {}) {
  return {
    subject_type: "PLAYER",
    subject_profile_id: PLAYER,
    subject_clan_id: null,
    status: "OPEN",
    priority: "NORMAL",
    reporter_profile_id: "33333333-3333-4333-8333-333333333333",
    reporter_referee_id: null,
    created_at: "2026-07-10T12:00:00.000Z",
    ...overrides,
  };
}

test("one unreviewed player flag is deliberately not shown to a referee", () => {
  const signals = buildRefereeRiskSignals([playerReport()], [], NOW);
  assert.equal(signals.size, 0);
});

test("repeated independent recent flags expose aggregates but no reporter identity", () => {
  const signals = buildRefereeRiskSignals(
    [
      playerReport(),
      playerReport({
        reporter_profile_id: "44444444-4444-4444-8444-444444444444",
        created_at: "2026-07-11T12:00:00.000Z",
      }),
    ],
    [],
    NOW,
  );

  const context = riskContextFor(signals, [], [PLAYER]);
  assert.equal(context.players.length, 1);
  assert.deepEqual(context.players[0], {
    subjectType: "PLAYER",
    subjectId: PLAYER,
    level: "AWARE",
    labels: ["Repeated recent flags"],
    priorReports: 2,
    recentReports: 2,
    distinctRecentReporters: 2,
    openReports: 2,
    actionedReports: 0,
    priorRefereeReports: 0,
    priorWarnings: 0,
    activeRestriction: null,
    lastReportedAt: "2026-07-11T12:00:00.000Z",
  });
  assert.equal(JSON.stringify(context).includes("33333333"), false);
  assert.equal(JSON.stringify(context).includes("44444444"), false);
});

test("dismissed flags are excluded while referee flags and warnings are high-signal", () => {
  const signals = buildRefereeRiskSignals(
    [
      playerReport({ status: "DISMISSED", priority: "URGENT" }),
      playerReport({
        reporter_profile_id: null,
        reporter_referee_id: "55555555-5555-4555-8555-555555555555",
      }),
    ],
    [
      {
        subject_type: "PLAYER",
        subject_profile_id: PLAYER,
        subject_clan_id: null,
        action_type: "WARNING",
        restriction_scope: "NONE",
        starts_at: "2026-06-01T00:00:00.000Z",
        ends_at: null,
        revoked_at: null,
        created_at: "2026-06-01T00:00:00.000Z",
      },
    ],
    NOW,
  );

  const signal = riskContextFor(signals, [], [PLAYER]).players[0];
  assert.equal(signal.priorReports, 1);
  assert.equal(signal.priorRefereeReports, 1);
  assert.equal(signal.priorWarnings, 1);
  assert.equal(signal.level, "ELEVATED");
  assert.deepEqual(signal.labels, [
    "Previously warned",
    "Previously flagged by a referee",
  ]);
});

test("an active clan restriction is surfaced at high level for that match only", () => {
  const signals = buildRefereeRiskSignals(
    [],
    [
      {
        subject_type: "CLAN",
        subject_profile_id: null,
        subject_clan_id: CLAN,
        action_type: "SUSPENSION",
        restriction_scope: "SCHEDULING",
        starts_at: "2026-07-14T00:00:00.000Z",
        ends_at: "2026-07-20T00:00:00.000Z",
        revoked_at: null,
        created_at: "2026-07-14T00:00:00.000Z",
      },
    ],
    NOW,
  );

  const context = riskContextFor(signals, [CLAN, "not-in-signal-map"], []);
  assert.equal(context.teams.length, 1);
  assert.equal(context.teams[0].level, "HIGH");
  assert.deepEqual(context.teams[0].activeRestriction, {
    actionType: "SUSPENSION",
    scope: "SCHEDULING",
    endsAt: "2026-07-20T00:00:00.000Z",
  });
});
