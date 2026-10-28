import {
  bookedRoleRatingBaselines,
  ratingTrackForRole,
} from "./rating_tracks.ts";

Deno.test("E2E baselines follow booked positions even when both ratings differ", () => {
  const rows = [
    { profile_id: "keeper", rating_track: "OUTFIELD", skill_rating: 1800 },
    { profile_id: "keeper", rating_track: "GOALKEEPER", skill_rating: 1215 },
    { profile_id: "defender", rating_track: "OUTFIELD", skill_rating: 1430 },
    { profile_id: "defender", rating_track: "GOALKEEPER", skill_rating: 1900 },
  ];
  const baselines = bookedRoleRatingBaselines(rows, {
    keeper: "GK",
    defender: "DEF",
  });
  assertEquals(baselines, { keeper: 1215, defender: 1430 });
  assertEquals(ratingTrackForRole("ATT"), "OUTFIELD");
  assertEquals(ratingTrackForRole("MID"), "OUTFIELD");
});

Deno.test("E2E keeper baselines never silently substitute the Outfield rating", () => {
  assertThrows(() =>
    bookedRoleRatingBaselines([
      { profile_id: "keeper", rating_track: "OUTFIELD", skill_rating: 1800 },
    ], { keeper: "GK" }), "Missing or invalid GOALKEEPER SR");
});

Deno.test("E2E baseline validation rejects duplicate, invalid and unknown-role data", () => {
  const row = {
    profile_id: "player",
    rating_track: "OUTFIELD",
    skill_rating: 1200,
  };
  assertThrows(
    () => bookedRoleRatingBaselines([row, row], { player: "ATT" }),
    "Missing or invalid OUTFIELD SR",
  );
  for (const rating of [NaN, -1, Infinity]) {
    assertThrows(
      () =>
        bookedRoleRatingBaselines([{ ...row, skill_rating: rating }], {
          player: "ATT",
        }),
      "Missing or invalid OUTFIELD SR",
    );
  }
  assertThrows(
    () => ratingTrackForRole("ANY"),
    "Unsupported E2E booked position",
  );
});

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}.`,
    );
  }
}

function assertThrows(run: () => unknown, message: string): void {
  try {
    run();
  } catch (error) {
    if (error instanceof Error && error.message.includes(message)) return;
    throw error;
  }
  throw new Error(`Expected failure containing: ${message}`);
}
