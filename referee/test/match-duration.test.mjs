import assert from "node:assert/strict";
import test from "node:test";

import {
  plannedMatchDurationSeconds,
  soloScheduledDurationSeconds,
  soloStartDurationSeconds,
} from "../src/lib/match-duration.ts";

const start = "2030-01-13T01:15:00.000Z";
const end = (minutes) => new Date(Date.parse(start) + minutes * 60000).toISOString();

test("solo clock defaults to the actual saved slot, including Saturday and 180 minutes", () => {
  for (const minutes of [30, 60, 90, 120, 180]) {
    assert.equal(soloScheduledDurationSeconds(start, end(minutes)), minutes * 60);
    assert.equal(soloStartDurationSeconds(start, end(minutes)), minutes * 60);
    assert.equal(soloStartDurationSeconds(start, end(minutes), null), minutes * 60);
  }
});

test("saved duration uses actual instants across midnight", () => {
  assert.equal(soloScheduledDurationSeconds("2030-01-12T23:15:00-07:00", "2030-01-13T00:45:00-07:00"), 5400);
});

test("invalid or legacy missing schedule falls back safely to one hour", () => {
  for (const [startsAt, endsAt] of [[null, null], [start, "invalid"], ["invalid", end(90)], [start, start], [end(90), start], [start, end(300)]]) {
    assert.equal(soloScheduledDurationSeconds(startsAt, endsAt), 3600);
  }
});

test("existing explicit duration override remains supported up to three hours", () => {
  assert.equal(soloStartDurationSeconds(start, end(90), 3600), 3600);
  assert.equal(soloStartDurationSeconds(start, end(90), 10800), 10800);
  assert.equal(soloStartDurationSeconds(start, end(90), 10801), 10800);
  assert.equal(soloStartDurationSeconds(start, end(90), 60), 600);
  assert.equal(soloStartDurationSeconds(start, end(90), 600.4), 600);
});

test("malformed duration override does not write a corrupt match clock", () => {
  for (const value of [NaN, Infinity, -Infinity, "5400", {}, []]) {
    assert.throws(() => soloStartDurationSeconds(start, end(90), value), /finite number/);
  }
});

test("solo pre-start timer uses planned duration while clan and old responses remain unchanged", () => {
  assert.equal(plannedMatchDurationSeconds({ matchKind: "SOLO", scheduledDurationSeconds: 5400 }), 5400);
  assert.equal(plannedMatchDurationSeconds({ matchKind: "SOLO", scheduledDurationSeconds: 10800 }), 10800);
  assert.equal(plannedMatchDurationSeconds({ matchKind: "CLAN", scheduledDurationSeconds: 5400 }), 3600);
  assert.equal(plannedMatchDurationSeconds({ matchKind: "SOLO" }), 3600);
  assert.equal(plannedMatchDurationSeconds({ matchKind: "SOLO", scheduledDurationSeconds: NaN }), 3600);
});
