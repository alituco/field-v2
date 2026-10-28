import assert from "node:assert/strict";
import test from "node:test";
import { parseFieldCoordinateInput } from "../src/lib/field-coordinate-input.ts";

test("field coordinates accept the reported Phoenix longitude as a decimal number", () => {
  assert.equal(parseFieldCoordinateInput("-111.975201", "longitude"), -111.975201);
  assert.equal(parseFieldCoordinateInput("33.4484", "latitude"), 33.4484);
});

test("copied coordinates normalize whitespace, Unicode minus and decimal commas", () => {
  for (const input of [" −111.975201 ", "-111,975201", " −111,975201 "]) {
    assert.equal(parseFieldCoordinateInput(input, "longitude"), -111.975201, input);
  }
  assert.equal(parseFieldCoordinateInput(" +33.4484 ", "latitude"), 33.4484);
  assert.equal(parseFieldCoordinateInput("33,4484", "latitude"), 33.4484);
});

test("zero and exact geographic range boundaries remain valid", () => {
  assert.equal(parseFieldCoordinateInput("0", "latitude"), 0);
  assert.equal(parseFieldCoordinateInput("0", "longitude"), 0);
  for (const value of [-90, 90]) assert.equal(parseFieldCoordinateInput(String(value), "latitude"), value);
  for (const value of [-180, 180]) assert.equal(parseFieldCoordinateInput(String(value), "longitude"), value);
});

test("each coordinate applies its own geographic range", () => {
  for (const value of ["-90.000001", "90.000001", "-111.975201", "180"]) {
    assert.equal(parseFieldCoordinateInput(value, "latitude"), null, value);
  }
  for (const value of ["-180.000001", "180.000001", "999"]) {
    assert.equal(parseFieldCoordinateInput(value, "longitude"), null, value);
  }
});

test("empty, non-finite, numeric syntax shortcuts and trailing text are rejected", () => {
  for (const axis of ["latitude", "longitude"]) {
    for (const input of ["", " ", "\t\n", "NaN", "Infinity", "-Infinity", "0x10", "0b10", "1e1", "1E+1", "33 degrees", "112 W", "--12", "+-12", ".", "-", "+", "1 2"]) {
      assert.equal(parseFieldCoordinateInput(input, axis), null, `${axis}: ${JSON.stringify(input)}`);
    }
  }
});

test("coordinate pairs and ambiguous mixed decimal separators are not accepted as a single coordinate", () => {
  for (const axis of ["latitude", "longitude"]) {
    for (const input of ["33.4484, -111.975201", "33,4484,-111,975201", "111,975.201", "111.975,201", "1,2,3", "1.2.3"]) {
      assert.equal(parseFieldCoordinateInput(input, axis), null, `${axis}: ${input}`);
    }
  }
});
