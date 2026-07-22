import assert from "node:assert/strict";
import test from "node:test";

import {
  bpsToPercent,
  cloneReliabilityPolicyConfig,
  diffReliabilityPolicyConfigs,
  parseReliabilityPolicyConfig,
  percentToBps,
  reliabilityPolicyDefaults,
  reliabilityTimelineForKickoff,
  resolveReliabilityPolicyAt,
  validReliabilityRevision,
  validateReliabilityPolicyConfig,
} from "../src/lib/reliability-policy.ts";

test("the canonical reliability policy defaults pass strict validation", () => {
  assert.deepEqual(validateReliabilityPolicyConfig(reliabilityPolicyDefaults), []);
  assert.deepEqual(parseReliabilityPolicyConfig(reliabilityPolicyDefaults), reliabilityPolicyDefaults);
  assert.equal(reliabilityPolicyDefaults.solo.playersPerSide, 6);
  assert.equal(reliabilityPolicyDefaults.clan.playersPerSide, 6);
});

test("historical seven-a-side clan policies remain readable but cannot become drafts", () => {
  const historical = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  historical.clan.playersPerSide = 7;

  assert.ok(validateReliabilityPolicyConfig(historical).some((issue) =>
    issue.path === "clan.playersPerSide"));
  assert.deepEqual(
    validateReliabilityPolicyConfig(historical, { allowLegacyClanSevenSide: true }),
    [],
  );
});

test("draft revision tokens preserve PostgreSQL microseconds", () => {
  const revision = "2026-07-17T00:47:48.977107+00:00";
  assert.equal(validReliabilityRevision(revision), revision);
});

test("validation rejects unknown settings, unsafe thresholds, and overlapping cancellation bands", () => {
  const invalid = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  invalid.attendance.checkInOpenLeadMinutes = 10;
  invalid.attendance.checkInLeadMinutes = 15;
  invalid.solo.cancellations.early.minimumHoursBeforeKickoff = 8;
  invalid.solo.cancellations.late.minimumHoursBeforeKickoff = 10;
  invalid.clan.minimumAtKickoffWithoutForfeit = 8;
  invalid.solo.sanctions[2].threshold = invalid.solo.sanctions[1].threshold;
  invalid.solo.teamAssignmentLeadMinutes = 240;
  invalid.solo.partyLockLeadMinutes = 180;
  invalid.replacement.originalPlayerReclaimUntilMinutesAfterKickoff = 11;
  invalid.replacement.reserveActivationMinutesAfterKickoff = 10;
  invalid.extraRule = true;

  const issues = validateReliabilityPolicyConfig(invalid);
  assert.ok(issues.some((issue) => issue.path === "extraRule" && /Unknown/.test(issue.message)));
  assert.ok(issues.some((issue) => issue.path === "attendance.checkInOpenLeadMinutes"));
  assert.ok(issues.some((issue) => issue.path.includes("early.minimumHoursBeforeKickoff")));
  assert.ok(issues.some((issue) => issue.path === "clan.minimumAtKickoffWithoutForfeit"));
  assert.ok(issues.some((issue) => issue.path === "solo.sanctions"));
  assert.ok(issues.some((issue) => issue.path === "solo.partyLockLeadMinutes"));
  assert.ok(issues.some((issue) => issue.path.includes("originalPlayerReclaim")));
});

test("authority and wallet invariants cannot be weakened by an admin draft", () => {
  const invalid = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  invalid.attendance.hostCheckInRequired = false;
  invalid.attendance.cancellationAfterKickoffOutcome = "CANCELLED_LATE";
  invalid.wallet.refundDestination = "CARD";
  invalid.solo.playersPerSide = 5;
  invalid.clan.playersPerSide = 8;
  invalid.injury.strikeDelta = 1;
  invalid.injury.requiresRefereeVerification = false;
  invalid.appeals.routineTrafficAutomaticallyExcused = true;

  const issues = validateReliabilityPolicyConfig(invalid);
  assert.ok(issues.some((issue) => issue.path === "attendance.hostCheckInRequired"));
  assert.ok(issues.some((issue) => issue.path === "attendance.cancellationAfterKickoffOutcome"));
  assert.ok(issues.some((issue) => issue.path === "wallet.refundDestination"));
  assert.ok(issues.some((issue) => issue.path === "solo.playersPerSide"));
  assert.ok(issues.some((issue) => issue.path === "clan.playersPerSide"));
  assert.ok(issues.some((issue) => issue.path === "injury.strikeDelta"));
  assert.ok(issues.some((issue) => issue.path === "injury.requiresRefereeVerification"));
  assert.ok(issues.some((issue) => issue.path === "appeals.routineTrafficAutomaticallyExcused"));
});

test("admins may reorder the complete manual reserve plan but cannot corrupt it", () => {
  const reordered = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  reordered.replacement.order = [
    "ON_FIELD_RESERVE",
    "EMERGENCY_NOTIFICATION",
    "PLAY_SHORTHANDED",
  ];
  assert.deepEqual(validateReliabilityPolicyConfig(reordered), []);

  for (const order of [
    ["EMERGENCY_NOTIFICATION", "ON_FIELD_RESERVE"],
    ["EMERGENCY_NOTIFICATION", "ON_FIELD_RESERVE", "ON_FIELD_RESERVE"],
    ["EMERGENCY_NOTIFICATION", "ON_FIELD_RESERVE", "UNSUPPORTED_STEP"],
  ]) {
    const invalid = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
    invalid.replacement.order = order;
    assert.ok(validateReliabilityPolicyConfig(invalid).some((issue) =>
      issue.path === "replacement.order"));
  }
});

test("consequence ladders can add future effective-dated steps", () => {
  const next = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  next.solo.sanctions.push({
    threshold: 7,
    kind: "INDEFINITE_SUSPENSION",
    durationDays: null,
    releaseFutureBookings: true,
  });
  assert.deepEqual(validateReliabilityPolicyConfig(next), []);
});

test("timed sanctions last at least one day and warnings remain normalized", () => {
  const zeroDayRestriction = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  zeroDayRestriction.solo.sanctions[1].durationDays = 0;
  assert.ok(validateReliabilityPolicyConfig(zeroDayRestriction).some((issue) =>
    issue.path === "solo.sanctions.1.durationDays" && /1 to 3,650/.test(issue.message)));

  const expiringWarning = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  expiringWarning.clan.sanctions[0].durationDays = 1;
  assert.ok(validateReliabilityPolicyConfig(expiringWarning).some((issue) =>
    issue.path === "clan.sanctions.0.durationDays" && /must use 0 days/.test(issue.message)));
});

test("basis points stay exact while the admin displays ordinary percentages", () => {
  assert.equal(bpsToPercent(5_000), 50);
  assert.equal(bpsToPercent(12_000), 120);
  assert.equal(percentToBps(20), 2_000);
  assert.equal(percentToBps(12.34), 1_234);
});

test("the 8 PM worked example resolves the hard deadline and no-show cutoff", () => {
  const timeline = reliabilityTimelineForKickoff(
    reliabilityPolicyDefaults,
    "2026-07-16T20:00:00+03:00",
  );
  assert.equal(timeline.checkInOpensAt.toISOString(), "2026-07-16T15:00:00.000Z");
  assert.equal(timeline.checkInDeadline.toISOString(), "2026-07-16T16:45:00.000Z");
  assert.equal(timeline.kickoff.toISOString(), "2026-07-16T17:00:00.000Z");
  assert.equal(timeline.noShowCutoff.toISOString(), "2026-07-16T17:10:00.000Z");
});

test("policy resolution uses the newest published version effective at kickoff", () => {
  const config = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  const versions = [
    policy("old", 1, "PUBLISHED", "2026-01-01T00:00:00.000Z", config),
    policy("next", 2, "PUBLISHED", "2026-08-01T00:00:00.000Z", config),
    policy("replacement", 3, "PUBLISHED", "2026-08-01T00:00:00.000Z", config),
    policy("draft", 4, "DRAFT", "2026-07-01T00:00:00.000Z", config),
  ];

  assert.equal(resolveReliabilityPolicyAt(versions, "2026-07-31T23:59:59.999Z")?.id, "old");
  assert.equal(resolveReliabilityPolicyAt(versions, "2026-08-01T00:00:00.000Z")?.id, "replacement");
  assert.equal(resolveReliabilityPolicyAt(versions, "2025-12-31T23:59:59.999Z"), null);
});

test("history diff describes basis-point, boolean, and sanction changes", () => {
  const next = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  next.attendance.noShowGraceMinutes = 12;
  next.replacement.postCheckInDeadlineMarketplaceEnabled = true;
  next.solo.reliabilityDeposit.depositBps = 2_500;
  next.solo.sanctions[1].durationDays = 9;

  const diff = diffReliabilityPolicyConfigs(reliabilityPolicyDefaults, next);
  assert.ok(diff.some((change) =>
    change.path === "solo.reliabilityDeposit.depositBps" &&
    change.before === "20%" && change.after === "25%"));
  assert.ok(diff.some((change) =>
    change.path === "replacement.postCheckInDeadlineMarketplaceEnabled" &&
    change.before === "Disabled" && change.after === "Enabled"));
  assert.ok(diff.some((change) =>
    change.path === "solo.sanctions.1.durationDays" && change.after === "9"));
});

test("cloning protects the immutable baseline from editor mutations", () => {
  const next = cloneReliabilityPolicyConfig(reliabilityPolicyDefaults);
  next.attendance.noShowGraceMinutes = 17;
  next.solo.sanctions[0].threshold = 2;
  assert.equal(reliabilityPolicyDefaults.attendance.noShowGraceMinutes, 10);
  assert.equal(reliabilityPolicyDefaults.solo.sanctions[0].threshold, 1);
});

function policy(id, version, state, effectiveFrom, config) {
  return {
    id,
    version,
    state,
    schemaVersion: 1,
    effectiveFrom,
    config,
    summary: id,
    createdBy: null,
    createdByName: null,
    createdAt: effectiveFrom,
    updatedAt: effectiveFrom,
    publishedBy: null,
    publishedByName: null,
    publishedAt: state === "PUBLISHED" ? effectiveFrom : null,
    supersedesId: null,
  };
}
