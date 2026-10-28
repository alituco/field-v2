import assert from "node:assert/strict";
import test from "node:test";

import {
  buildClanGameParticipants,
  loadAdminGameParticipants,
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

test("a rebooked solo player uses fresh attendance without a duplicate withdrawal", () => {
  const result = buildSoloGameParticipants({
    matchId: "game",
    status: "OPEN",
    capacity: 14,
    bookingRows: [
      {
        id: "old-booking-a",
        profile_id: A,
        role: "GK",
        status: "CANCELLED",
        booked_at: "2026-10-12T08:00:00Z",
        cancelled_at: "2026-10-12T09:00:00Z",
        profile: profile(A, "Ali"),
      },
      {
        id: "new-booking-a",
        profile_id: A,
        role: "DEF",
        status: "CONFIRMED",
        booked_at: "2026-10-12T10:00:00Z",
        profile: profile(A, "Ali"),
      },
    ],
    attendanceRows: [
      {
        id: "old-attendance-a",
        booking_id: "old-booking-a",
        profile_id: A,
        is_current: false,
        role: "GK",
        side: "WHITE",
        checked_in_at: "2026-10-12T08:30:00Z",
        outcome: "CANCELLED_LATE",
        profile: profile(A, "Ali"),
      },
      {
        id: "new-attendance-a",
        booking_id: "new-booking-a",
        profile_id: A,
        is_current: true,
        expected_for_match: true,
        role: "DEF",
        checked_in_at: null,
        outcome: null,
        profile: profile(A, "Ali"),
      },
    ],
  });

  assert.deepEqual(result.counts, { registered: 1, actual: 0, withdrawn: 0 });
  assert.equal(result.registeredPlayers[0].bookingId, "new-booking-a");
  assert.equal(result.registeredPlayers[0].role, "DEF");
  assert.deepEqual(result.actualPlayers, []);
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


test("a long cancellation history cannot hide the current solo roster after the REST row limit", async () => {
  const bookings = Array.from({ length: 1214 }, (_, index) => ({
    id: `booking-${String(index).padStart(4, "0")}`, game_id: "game", profile_id: `player-${index}`,
    status: index < 1200 ? "CANCELLED" : "CONFIRMED", role: "MID", team: index % 2 ? "BLACK" : "WHITE",
    booked_at: `2099-01-01T00:00:00Z`, profile: { display_name: `Player ${index}` },
  }));
  const pages = [];
  const db = { from(table) {
    const filters = [];
    let range = [0, 999];
    const chain = {
      select() { return chain; },
      eq(key, value) { filters.push((row) => row[key] === value); return chain; },
      order() { return chain; },
      range(from, to) { range = [from, to]; return chain; },
      async maybeSingle() { return { data: { id: "game", status: "FULL", capacity: 14 }, error: null }; },
      then(resolve, reject) {
        pages.push({ table, from: range[0] });
        const rows = table === "open_queue_bookings" ? bookings : [];
        return Promise.resolve({ data: rows.filter((row) => filters.every((filter) => filter(row))).slice(range[0], range[1] + 1), error: null }).then(resolve, reject);
      },
    };
    return chain;
  } };
  const roster = await loadAdminGameParticipants(db, "SOLO", "game");
  assert.equal(roster.registeredPlayers.length, 14);
  assert.equal(roster.withdrawnPlayers.length, 1200);
  assert.ok(pages.some((page) => page.table === "open_queue_bookings" && page.from === 1000));
});
