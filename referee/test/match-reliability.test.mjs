import assert from "node:assert/strict";
import test from "node:test";

import { normalizeMatchReliabilityContext } from "../src/lib/match-reliability.ts";

test("match reliability context preserves server timing and attendance states", () => {
  assert.deepEqual(
    normalizeMatchReliabilityContext({
      server_now: "2026-07-21T16:46:00Z",
      policy_version_id: "11111111-1111-4111-8111-111111111111",
      kickoff_at: "2026-07-21T17:00:00Z",
      check_in_deadline_at: "2026-07-21T16:45:00Z",
      no_show_cutoff_at: "2026-07-21T17:10:00Z",
      reserve_activation_minutes_after_kickoff: 12,
      reserve_activation_at: "2026-07-21T17:12:00Z",
      original_player_reclaim_until_minutes_after_kickoff: 8,
      original_player_reclaim_until_at: "2026-07-21T17:08:00Z",
      replacement_order: [
        "ON_FIELD_RESERVE",
        "EMERGENCY_NOTIFICATION",
        "PLAY_SHORTHANDED",
      ],
      reserve_plan_automated: false,
      reserve_plan_authority: "FIELD_HOST",
      can_check_in: true,
      can_finalize_attendance: false,
      attendance_finalized: false,
      players: [
        {
          attendance_record_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          profile_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          display_name: "Dana Alawi",
          expected_for_match: true,
          check_in_eligible: true,
          team: "WHITE",
          side: "WHITE",
          role: "DEF",
          checked_in_at: "2026-07-21T16:44:00Z",
          attendance_outcome: "on_time",
        },
        {
          profile_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          display_name: "Ali Altaraif",
          expected_for_match: false,
          check_in_eligible: true,
          team: "BLACK",
          side: "BLACK",
          role: "MID",
        },
      ],
    }),
    {
      serverNow: "2026-07-21T16:46:00Z",
      policyVersionId: "11111111-1111-4111-8111-111111111111",
      kickoffAt: "2026-07-21T17:00:00Z",
      checkInDeadlineAt: "2026-07-21T16:45:00Z",
      noShowCutoffAt: "2026-07-21T17:10:00Z",
      reserveActivationMinutesAfterKickoff: 12,
      reserveActivationAt: "2026-07-21T17:12:00Z",
      originalPlayerReclaimUntilMinutesAfterKickoff: 8,
      originalPlayerReclaimUntilAt: "2026-07-21T17:08:00Z",
      replacementOrder: [
        "ON_FIELD_RESERVE",
        "EMERGENCY_NOTIFICATION",
        "PLAY_SHORTHANDED",
      ],
      reservePlanAutomated: false,
      reservePlanAuthority: "FIELD_HOST",
      canCheckIn: true,
      canFinalizeAttendance: false,
      attendanceFinalized: false,
      expectedCount: 2,
      checkedInCount: 1,
      onTimeCount: 1,
      lateCount: 0,
      missingCount: 1,
      verifiedInjuries: [],
      openShorthandedPeriods: [],
      players: [
        {
          attendanceRecordId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          profileId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          displayName: "Dana Alawi",
          expectedForMatch: true,
          checkInEligible: true,
          teamId: "WHITE",
          teamName: "WHITE",
          side: "WHITE",
          role: "DEF",
          checkedInAt: "2026-07-21T16:44:00Z",
          outcome: "ON_TIME",
          status: "ON_TIME",
          isCheckedIn: true,
        },
        {
          attendanceRecordId: null,
          profileId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          displayName: "Ali Altaraif",
          expectedForMatch: false,
          checkInEligible: true,
          teamId: "BLACK",
          teamName: "BLACK",
          side: "BLACK",
          role: "MID",
          checkedInAt: null,
          outcome: null,
          status: "MISSING",
          isCheckedIn: false,
        },
      ],
    },
  );
});

test("browser eligibility defaults closed when the server omits flags", () => {
  const context = normalizeMatchReliabilityContext({ players: [] });
  assert.equal(context?.canCheckIn, false);
  assert.equal(context?.canFinalizeAttendance, false);
  assert.deepEqual(context?.verifiedInjuries, []);
  assert.deepEqual(context?.openShorthandedPeriods, []);
});

test("match reliability context normalizes server-authored effect evidence", () => {
  const context = normalizeMatchReliabilityContext({
    players: [],
    verified_injuries: [{
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      profile_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      side: "WHITE",
      match_second: 612,
      unable_to_continue: true,
      replacement_available: false,
      match_continued: true,
      note: "Left after treatment.",
    }],
    open_shorthanded_periods: [{
      id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      side: "WHITE",
      reason: "INJURY",
      caused_by_profile_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      started_match_second: 612,
    }],
  });

  assert.deepEqual(context?.verifiedInjuries, [{
    id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    profileId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    side: "WHITE",
    matchSecond: 612,
    unableToContinue: true,
    replacementAvailable: false,
    matchContinued: true,
    note: "Left after treatment.",
  }]);
  assert.deepEqual(context?.openShorthandedPeriods, [{
    id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    side: "WHITE",
    reason: "INJURY",
    causedByProfileId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    replacementProfileId: null,
    startedMatchSecond: 612,
    endedMatchSecond: null,
    note: null,
  }]);
});
