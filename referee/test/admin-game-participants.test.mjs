import assert from "node:assert/strict";
import test from "node:test";

import {
  buildClanGameParticipants,
  buildSoloGameParticipants,
} from "../src/lib/admin-game-participants.ts";

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const C = "33333333-3333-4333-8333-333333333333";
const HOME = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const AWAY = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

function profile(id, name) {
  return { id, display_name: name, username: `@${name.toLowerCase()}`, avatar_url: null };
}

test("solo active roster keeps every confirmed booking and separates withdrawals", () => {
  const result = buildSoloGameParticipants({
    matchId: "game",
    status: "FULL",
    capacity: 12,
    bookingRows: [
      {
        id: "booking-a",
        profile_id: A,
        role: "DEF",
        status: "CONFIRMED",
        team: "WHITE",
        rating_at_team_assignment: 1210,
        played: false,
        booked_at: "2026-07-16T08:00:00Z",
        profile: profile(A, "Ali"),
      },
      {
        id: "booking-b",
        profile_id: B,
        role: "MID",
        status: "CONFIRMED",
        team: "BLACK",
        played: true,
        booked_at: "2026-07-16T09:00:00Z",
        profile: profile(B, "Bea"),
      },
      {
        id: "booking-c",
        profile_id: C,
        role: "ATT",
        status: "CANCELLED",
        team: null,
        played: false,
        booked_at: "2026-07-15T09:00:00Z",
        cancelled_at: "2026-07-16T07:00:00Z",
        profile: profile(C, "Cam"),
      },
    ],
    attendanceRows: [],
  });

  assert.equal(result.rosterSource, "CONFIRMED_BOOKINGS");
  assert.deepEqual(result.registeredPlayers.map((player) => player.profileId), [A, B]);
  assert.deepEqual(result.actualPlayers.map((player) => player.profileId), [B]);
  assert.deepEqual(result.withdrawnPlayers.map((player) => player.profileId), [C]);
  assert.deepEqual(result.counts, { registered: 2, actual: 1, withdrawn: 1 });
});

test("solo cancelled roster is reconstructed from attendance after booking sides are cleared", () => {
  const result = buildSoloGameParticipants({
    matchId: "game",
    status: "CANCELLED",
    capacity: 12,
    bookingRows: [
      {
        id: "booking-a",
        profile_id: A,
        role: "DEF",
        status: "CANCELLED",
        team: null,
        played: false,
        booked_at: "2026-07-16T08:00:00Z",
        cancelled_at: "2026-07-17T08:00:00Z",
        profile: profile(A, "Ali"),
      },
      {
        id: "booking-c",
        profile_id: C,
        role: "ATT",
        status: "CANCELLED",
        team: null,
        played: false,
        booked_at: "2026-07-15T08:00:00Z",
        cancelled_at: "2026-07-16T08:00:00Z",
        profile: profile(C, "Cam"),
      },
    ],
    attendanceRows: [
      {
        id: "attendance-a",
        booking_id: "booking-a",
        profile_id: A,
        side: "WHITE",
        role: "DEF",
        expected_for_match: true,
        checked_in_at: null,
        outcome: "FIELD_CANCELLED",
        profile: profile(A, "Ali"),
      },
    ],
  });

  assert.equal(result.rosterSource, "FIELD_CANCELLATION_ATTENDANCE");
  assert.equal(result.registeredPlayers[0].side, "WHITE");
  assert.deepEqual(result.withdrawnPlayers.map((player) => player.profileId), [C]);
});

test("clan response keeps planned, actual, and removed rosters distinct", () => {
  const result = buildClanGameParticipants({
    matchId: "fixture",
    status: "FINAL",
    homeClanId: HOME,
    awayClanId: AWAY,
    rosterRows: [
      {
        id: "roster-a",
        clan_id: HOME,
        profile_id: A,
        status: "CONFIRMED",
        confirmed_at: "2026-07-15T08:00:00Z",
        profile: profile(A, "Ali"),
      },
      {
        id: "roster-b",
        clan_id: AWAY,
        profile_id: B,
        status: "REPLACED",
        confirmed_at: "2026-07-14T08:00:00Z",
        ended_at: "2026-07-15T07:00:00Z",
        profile: profile(B, "Bea"),
      },
    ],
    appearanceRows: [
      {
        profile_id: C,
        clan_id: AWAY,
        side: "AWAY",
        played: true,
        rating_at_start: 1190,
        rating_change: 14,
        profile: profile(C, "Cam"),
      },
    ],
    attendanceRows: [
      {
        profile_id: A,
        clan_id: HOME,
        side: "HOME",
        expected_for_match: true,
        checked_in_at: "2026-07-16T15:45:00Z",
        outcome: "ON_TIME",
        profile: profile(A, "Ali"),
      },
      {
        profile_id: C,
        clan_id: AWAY,
        side: "AWAY",
        expected_for_match: false,
        checked_in_at: "2026-07-16T15:50:00Z",
        outcome: "ON_TIME",
        profile: profile(C, "Cam"),
      },
    ],
  });

  assert.deepEqual(result.plannedPlayers.map((player) => player.profileId), [A]);
  assert.deepEqual(result.actualPlayers.map((player) => player.profileId), [A, C]);
  assert.deepEqual(result.removedPlayers.map((player) => player.profileId), [B]);
  assert.deepEqual(result.counts, {
    planned: 1,
    plannedHome: 1,
    plannedAway: 0,
    actual: 2,
    actualHome: 1,
    actualAway: 1,
    removed: 1,
  });
});
