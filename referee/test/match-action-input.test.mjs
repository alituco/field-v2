import assert from "node:assert/strict";
import test from "node:test";

import {
  parseAdminCancellationInput,
  parseAdminForfeitReviewInput,
  parseAdminScoreOverrideInput,
  parseMatchStoppageInput,
  parseRefereeBulkCheckInInput,
  parseRefereeCheckInInput,
  parseRefereeClanForfeitInput,
  parseRefereeEndShorthandedInput,
  parseRefereeReportInput,
  parseRefereeStartShorthandedInput,
  parseRefereeVerifiedInjuryInput,
} from "../src/lib/match-action-input.ts";

const MATCH_ID = "11111111-1111-4111-8111-111111111111";
const PLAYER_ID = "22222222-2222-4222-8222-222222222222";

test("referee reports are normalized and pinned to their match context", () => {
  assert.deepEqual(
    parseRefereeReportInput(
      {
        subjectType: "player",
        subjectId: PLAYER_ID,
        category: "dangerous_play",
        details: "Late challenge after the whistle.",
        replayOffsetSeconds: 742,
      },
      "CLAN",
      MATCH_ID,
    ),
    {
      subjectType: "PLAYER",
      subjectId: PLAYER_ID,
      category: "DANGEROUS_PLAY",
      priority: "HIGH",
      details: "Late challenge after the whistle.",
      replayOffsetSeconds: 742,
    },
  );

  assert.throws(
    () =>
      parseRefereeReportInput(
        {
          subjectType: "MATCH",
          subjectId: PLAYER_ID,
          category: "OTHER",
          details: "Wrong match context.",
        },
        "CLAN",
        MATCH_ID,
      ),
    /does not match this fixture/,
  );

  assert.throws(
    () =>
      parseRefereeReportInput(
        {
          subjectType: "CLAN",
          subjectId: PLAYER_ID,
          category: "CHEATING",
          details: "A solo side is not a clan.",
        },
        "SOLO",
        MATCH_ID,
      ),
    /solo team is not a clan/i,
  );
});

test("safety stoppages require enumerated reasons and explain Other", () => {
  assert.deepEqual(
    parseMatchStoppageInput({
      mode: "temporary",
      reasonCode: "serious_injury",
      note: "Player is receiving treatment.",
    }),
    {
      mode: "TEMPORARY",
      reasonCode: "SERIOUS_INJURY",
      note: "Player is receiving treatment.",
    },
  );

  assert.throws(
    () =>
      parseMatchStoppageInput({
        mode: "ABANDON",
        reasonCode: "OTHER",
        note: "Too short",
      }),
    /short explanation/,
  );
});

test("clan forfeits require a reported clan and a team-attributable reason", () => {
  assert.deepEqual(
    parseRefereeClanForfeitInput({
      reportedClanId: PLAYER_ID,
      category: "no_show_or_match_manipulation",
      details: "The reported team walked off and refused to continue.",
      reasonCode: "team_walkout",
      replayOffsetSeconds: 1337,
    }),
    {
      reportedClanId: PLAYER_ID,
      category: "NO_SHOW_OR_MATCH_MANIPULATION",
      details: "The reported team walked off and refused to continue.",
      reasonCode: "TEAM_WALKOUT",
      note: "",
      replayOffsetSeconds: 1337,
    },
  );

  assert.throws(
    () => parseRefereeClanForfeitInput({
      category: "dangerous_play",
      details: "A team incident forced the referee to end the match.",
      reasonCode: "fighting_or_violence",
    }),
    /choose the team responsible/i,
  );
  assert.throws(
    () => parseRefereeClanForfeitInput({
      reportedClanId: "not-a-clan-id",
      category: "dangerous_play",
      details: "A team incident forced the referee to end the match.",
      reasonCode: "fighting_or_violence",
    }),
    /choose the team responsible/i,
  );
  assert.throws(
    () => parseRefereeClanForfeitInput({
      reportedClanId: PLAYER_ID,
      category: "safety_or_venue",
      details: "Heavy rain made the playing surface unsafe for everyone.",
      reasonCode: "unsafe_venue_or_weather",
    }),
    /team-related reason/i,
  );
  assert.throws(
    () => parseRefereeClanForfeitInput({
      reportedClanId: PLAYER_ID,
      category: "other",
      details: "The team caused an incident that ended the match.",
      reasonCode: "other",
      note: "Too short",
    }),
    /short explanation/i,
  );
});

test("admin forfeit reviews require an explicit decision and evidence note", () => {
  assert.deepEqual(
    parseAdminForfeitReviewInput({
      decisionId: MATCH_ID,
      action: "confirm",
      note: "The match replay and referee report support the decision.",
    }),
    {
      decisionId: MATCH_ID,
      action: "CONFIRM",
      note: "The match replay and referee report support the decision.",
    },
  );
  assert.throws(
    () => parseAdminForfeitReviewInput({
      decisionId: MATCH_ID,
      action: "dismiss",
      note: "The evidence does not support the forfeit result.",
    }),
    /confirm or overturn/i,
  );
});

test("admin match mutations require bounded values and meaningful reasons", () => {
  assert.deepEqual(
    parseAdminCancellationInput({
      reasonCode: "weather_or_venue",
      reason: "The pitch is unsafe after flooding.",
    }),
    {
      reasonCode: "WEATHER_OR_VENUE",
      reason: "The pitch is unsafe after flooding.",
    },
  );

  assert.deepEqual(
    parseAdminCancellationInput({
      reason: "Cancelled after an administrator review.",
    }),
    {
      reasonCode: "ADMIN_DECISION",
      reason: "Cancelled after an administrator review.",
    },
  );

  assert.deepEqual(
    parseAdminScoreOverrideInput({
      homeScore: 3,
      awayScore: 2,
      reason: "Verified against the complete match recording.",
    }),
    {
      homeScore: 3,
      awayScore: 2,
      reason: "Verified against the complete match recording.",
    },
  );

  assert.throws(
    () =>
      parseAdminScoreOverrideInput({
        homeScore: -1,
        awayScore: 2,
        reason: "Verified against the complete match recording.",
      }),
    /Home score/,
  );
  assert.throws(
    () =>
      parseAdminScoreOverrideInput({
        homeScore: 2,
        awayScore: 2,
        reason: "typo",
      }),
    /official score/,
  );
});

test("referee check-ins only accept normalized player ids", () => {
  assert.deepEqual(
    parseRefereeCheckInInput({ profileId: PLAYER_ID.toUpperCase() }),
    { profileId: PLAYER_ID },
  );
  assert.deepEqual(
    parseRefereeBulkCheckInInput({
      profileIds: [PLAYER_ID, PLAYER_ID, MATCH_ID],
    }),
    { profileIds: [PLAYER_ID, MATCH_ID] },
  );
  assert.throws(
    () => parseRefereeCheckInInput({ profileId: "someone-else" }),
    /choose a player/i,
  );
  assert.throws(
    () => parseRefereeBulkCheckInInput({ profileIds: [] }),
    /between 1 and 50/i,
  );
});

test("verified injury evidence requires a player and explicit boolean facts", () => {
  assert.deepEqual(
    parseRefereeVerifiedInjuryInput({
      profileId: PLAYER_ID.toUpperCase(),
      unableToContinue: true,
      replacementAvailable: false,
      matchContinued: true,
      note: "Player left the pitch after treatment.",
    }),
    {
      profileId: PLAYER_ID,
      unableToContinue: true,
      replacementAvailable: false,
      matchContinued: true,
      note: "Player left the pitch after treatment.",
    },
  );
  assert.throws(
    () => parseRefereeVerifiedInjuryInput({
      profileId: PLAYER_ID,
      unableToContinue: "yes",
      replacementAvailable: false,
      matchContinued: true,
    }),
    /confirm whether the player was unable/i,
  );
});

test("shorthanded evidence is constrained to the match kind and known reasons", () => {
  assert.deepEqual(
    parseRefereeStartShorthandedInput({
      side: "white",
      reason: "late_arrival",
      causedByProfileId: PLAYER_ID,
      note: "Play started one player short.",
    }, "SOLO"),
    {
      side: "WHITE",
      reason: "LATE_ARRIVAL",
      causedByProfileId: PLAYER_ID,
      note: "Play started one player short.",
    },
  );
  assert.throws(
    () => parseRefereeStartShorthandedInput({
      side: "HOME",
      reason: "NO_SHOW",
    }, "SOLO"),
    /choose a team/i,
  );
  assert.throws(
    () => parseRefereeStartShorthandedInput({
      side: "AWAY",
      reason: "OTHER",
      note: "why",
    }, "CLAN"),
    /concise factual note/i,
  );

  assert.deepEqual(
    parseRefereeEndShorthandedInput({
      periodId: MATCH_ID,
      replacementProfileId: PLAYER_ID,
      note: "Replacement entered the field.",
    }),
    {
      periodId: MATCH_ID,
      replacementProfileId: PLAYER_ID,
      note: "Replacement entered the field.",
    },
  );
});
