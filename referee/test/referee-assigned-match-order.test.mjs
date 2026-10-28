import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { refereeMatchKey, sortAssignedRefereeMatches } from "../src/lib/referee-assigned-matches.ts";

const now = new Date("2026-10-15T19:30:00Z");
const game = (id, status, date, time = "4:30 PM - 5:40 PM", extra = {}) => ({
  id, matchKind: "SOLO", status, matchDate: date, timeSlot: time, timezone: "America/Phoenix", ...extra,
});

test("all assigned states remain visible with live and upcoming games ahead of history", () => {
  const rows = [
    game("old-final", "FINAL", "2025-01-01"), game("next", "OPEN", "2026-10-17"),
    game("cancelled", "CANCELLED", "2026-12-01"), game("overdue", "OPEN", "2026-10-10"),
    game("live", "LIVE", "2026-09-01"), game("ready", "FULL", "2026-10-16"),
    game("recent-final", "FINAL", "2026-10-14"),
  ];
  const original = [...rows];
  const sorted = sortAssignedRefereeMatches(rows, now);
  assert.deepEqual(sorted.map(row => row.id), ["live", "ready", "next", "overdue", "cancelled", "recent-final", "old-final"]);
  assert.deepEqual(rows, original, "sorting does not mutate the API input");
  assert.equal(sorted.length, rows.length);
});

test("12-hour and 24-hour schedules sort chronologically including noon and midnight", () => {
  const times = ["4:30 PM - 5:40 PM", "12:00 PM - 1:00 PM", "9:00 AM - 10:00 AM", "12:00 AM - 1:00 AM", "20:30 - 21:30"];
  const rows = times.map((time, index) => game(String(index), "OPEN", "2026-10-17", time));
  assert.deepEqual(sortAssignedRefereeMatches(rows, now).map(row => row.timeSlot), [times[3], times[2], times[1], times[0], times[4]]);
});

test("today is interpreted in the venue timezone, not the server's UTC date", () => {
  const at = new Date("2026-10-16T02:00:00Z"); // October 15 in Phoenix.
  const today = game("phoenix-today", "OPEN", "2026-10-15");
  const tomorrow = game("phoenix-tomorrow", "OPEN", "2026-10-16");
  assert.deepEqual(sortAssignedRefereeMatches([tomorrow, today], at).map(row => row.id), [today.id, tomorrow.id]);
});

test("clan and solo identities cannot select or overwrite each other", () => {
  assert.notEqual(refereeMatchKey({ matchKind: "CLAN", id: "same-id" }), refereeMatchKey({ matchKind: "SOLO", id: "same-id" }));
});

test("the hosted journey selects its exact solo match using the same identity contract", () => {
  const journey = readFileSync(new URL("../e2e/staging-referee-admin.spec.ts", import.meta.url), "utf8");
  assert.match(journey, /selectOption\(refereeMatchKey\(\{ matchKind: "SOLO", id: manifest\.games\.match\.id \}\)\)/);
  assert.doesNotMatch(journey, /selectOption\(manifest\.games\.match\.id\)/);
});
