import { strict as assert } from "node:assert";
import { assertCompletedSeasonZeroEvidence } from "./completion_evidence.ts";

function fixture() {
  const game = {
    id: "test-game",
    startsAt: "2026-10-21T18:00:00Z",
    endsAt: "2026-10-21T18:30:00Z",
    ratingPolicy: "field-sr-season0-v2",
  };
  const state = {
    game_id: game.id,
    policy_id: game.ratingPolicy,
    lifecycle: "FINAL",
    rating_status: "completed",
    settlement_status: "RATED",
    started_at: "2026-10-21T06:00:00.123456+00:00",
    scheduled_seconds: 1800,
    played_seconds: 1807,
    elapsed_seconds: 1807,
  };
  const events = [
    {
      game_id: game.id,
      event_type: "MATCH_STARTED",
      occurred_at: state.started_at,
      minute: null,
      second: null,
    },
    {
      game_id: game.id,
      event_type: "MATCH_ENDED",
      occurred_at: "2026-10-21T06:30:07.123456Z",
      minute: 30,
      second: 7,
    },
  ];
  const clock = {
    game_id: game.id,
    status: "ENDED",
    started_at: null,
    duration_seconds: 1800,
    accumulated_seconds: 1807,
  };
  return { game, state, events, clock };
}
type Fixture = ReturnType<typeof fixture>;
const verify = (f: Fixture) =>
  assertCompletedSeasonZeroEvidence(f.game, f.state, f.events, f.clock);

Deno.test("ordinary S0 completion before schedule passes without a legacy admin test-start audit", () => {
  verify(fixture());
});

Deno.test("kickoff accepts both exact ±24h boundaries and after-schedule play", () => {
  for (const hours of [-24, 0, 2, 24]) {
    const f = fixture();
    f.state.started_at = new Date(Date.parse(f.game.startsAt) + hours * 3600000)
      .toISOString();
    f.events[0].occurred_at = f.state.started_at;
    verify(f);
  }
});

const invalid: Array<[string, (f: Fixture) => void]> = [
  ["legacy policy", (f) => {
    f.game.ratingPolicy = "legacy";
  }],
  ["wrong participation game", (f) => {
    f.state.game_id = "other";
  }],
  ["wrong state policy", (f) => {
    f.state.policy_id = "legacy";
  }],
  ["still live", (f) => {
    f.state.lifecycle = "LIVE";
  }],
  ["unranked outcome", (f) => {
    f.state.rating_status = "unranked";
  }],
  ["unsettled ratings", (f) => {
    f.state.settlement_status = "PENDING";
  }],
  ["outside kickoff window", (f) => {
    f.state.started_at = "2026-10-20T17:59:59Z";
    f.events[0].occurred_at = f.state.started_at;
  }],
  ["invalid actual kickoff", (f) => {
    f.state.started_at = "invalid";
  }],
  ["invalid scheduled kickoff", (f) => {
    f.game.startsAt = "invalid";
  }],
  ["changed duration", (f) => {
    f.state.scheduled_seconds = 600;
  }],
  ["incomplete duration", (f) => {
    f.state.played_seconds = 1799;
  }],
  ["elapsed mismatch", (f) => {
    f.state.elapsed_seconds = 1806;
  }],
  ["wrong clock game", (f) => {
    f.clock.game_id = "other";
  }],
  ["running clock", (f) => {
    f.clock.status = "RUNNING";
  }],
  ["clock duration mismatch", (f) => {
    f.clock.duration_seconds = 600;
  }],
  ["clock elapsed mismatch", (f) => {
    f.clock.accumulated_seconds = 1806;
  }],
  ["missing kickoff event", (f) => {
    f.events.shift();
  }],
  ["duplicate kickoff", (f) => {
    f.events.push({ ...f.events[0] });
  }],
  ["different kickoff timestamp", (f) => {
    f.events[0].occurred_at = "2026-10-21T06:01:00Z";
  }],
  ["event from other game", (f) => {
    f.events[0].game_id = "other";
  }],
  ["missing finish event", (f) => {
    f.events.pop();
  }],
  ["duplicate finish", (f) => {
    f.events.push({ ...f.events[1] });
  }],
  ["finish elapsed mismatch", (f) => {
    f.events[1].second = 8;
  }],
  ["malformed seconds", (f) => {
    f.events[1].second = 60;
  }],
];
for (const [name, mutate] of invalid) {
  Deno.test(`completion evidence rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => verify(f), /Season 0 E2E completion evidence/);
  });
}

Deno.test("missing and malformed API data cannot count as completion", () => {
  const f = fixture();
  for (const malformed of [null, [], "FINAL", 0]) {
    assert.throws(() =>
      assertCompletedSeasonZeroEvidence(f.game, malformed, f.events, f.clock)
    );
    assert.throws(() =>
      assertCompletedSeasonZeroEvidence(f.game, f.state, f.events, malformed)
    );
  }
  for (const malformed of [null, {}, [null]]) {
    assert.throws(() =>
      assertCompletedSeasonZeroEvidence(f.game, f.state, malformed, f.clock)
    );
  }
});
