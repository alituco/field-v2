import assert from "node:assert/strict";
import test from "node:test";

import {
  hasGuaranteedNoSrChange,
  playerSrConsequenceLabel,
} from "../src/lib/admin-match-resolution-ui.ts";

test("void and neutral cancellations clearly show that SR does not change", () => {
  for (const resolutionType of [
    "ADMINISTRATIVE_VOID",
    "FIELD_OR_VENUE_CANCELLATION",
    "MUTUAL_CANCELLATION",
  ]) {
    assert.equal(hasGuaranteedNoSrChange(resolutionType), true);
    assert.equal(playerSrConsequenceLabel(resolutionType), "No change");
  }
});

test("rated outcomes retain the per-player SR explanation", () => {
  assert.equal(hasGuaranteedNoSrChange("RECORDED_RESULT"), false);
  assert.equal(
    playerSrConsequenceLabel("RECORDED_RESULT"),
    "Calculated per player",
  );
});
