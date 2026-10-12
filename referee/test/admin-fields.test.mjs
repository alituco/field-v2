import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { adminFieldsErrorMessage, parseAdminFieldInput, parseFieldId, serializeAdminField } from "../src/lib/admin-fields.ts";

const base = { name: " Test pitch ", address: " 123 Test Avenue ", latitude: "33.4484", longitude: "-112.0740" };

test("saved fields require an address and valid map coordinates, with Phoenix defaults", () => {
  assert.deepEqual(parseAdminFieldInput(base), {
    name: "Test pitch", address: "123 Test Avenue", city: "Phoenix", state: "AZ", country_code: "US",
    latitude: 33.4484, longitude: -112.074,
  });
  for (const key of ["name", "address", "latitude", "longitude"]) {
    const invalid = { ...base }; delete invalid[key];
    assert.throws(() => parseAdminFieldInput(invalid), /required/);
  }
});

test("coordinate validation does not coerce blank, null, booleans or non-finite values to a location", () => {
  for (const value of [null, true, false, "", " ", NaN, Infinity, "Infinity", "NaN", "0x10", "33 degrees", [], {}]) {
    assert.throws(() => parseAdminFieldInput({ ...base, latitude: value }), /Latitude/);
    assert.throws(() => parseAdminFieldInput({ ...base, longitude: value }), /Longitude/);
  }
  for (const latitude of [-90.001, 90.001]) assert.throws(() => parseAdminFieldInput({ ...base, latitude }), /Latitude/);
  for (const longitude of [-180.001, 180.001]) assert.throws(() => parseAdminFieldInput({ ...base, longitude }), /Longitude/);
  assert.equal(parseAdminFieldInput({ ...base, latitude: 0, longitude: 0 }).latitude, 0);
});

test("partial edit/archive only sends specified attributes and rejects forged fields", () => {
  assert.deepEqual(parseAdminFieldInput({ isActive: false }, true), { is_active: false });
  assert.deepEqual(parseAdminFieldInput({ city: " Mesa " }, true), { city: "Mesa" });
  assert.deepEqual(parseAdminFieldInput({ countryCode: "us" }, true), { country_code: "US" });
  for (const invalid of [{}, { id: "forged" }, { created_by: "forged" }, { isActive: "false" }, { countryCode: "1!" }, { city: null }]) {
    assert.throws(() => parseAdminFieldInput(invalid, true));
  }
});

test("field payload does not expose creating admin identity", () => {
  const row = { id: "abc", name: "Park", address: "123 Road", city: "Phoenix", state: "AZ", country_code: "US",
    latitude: 33, longitude: -112, is_active: true, created_by: "private", created_at: "date", updated_at: "date" };
  const result = serializeAdminField(row);
  assert.equal(result.countryCode, "US");
  assert.equal(result.isActive, true);
  assert.equal(result.created_by, undefined);
  assert.equal(result.createdBy, undefined);
});

test("missing migration and duplicate field errors are actionable", () => {
  for (const code of ["42P01", "42703", "PGRST202", "PGRST204", "PGRST205"]) {
    assert.match(adminFieldsErrorMessage({ code }), /Apply the latest migration/);
  }
  assert.match(adminFieldsErrorMessage({ code: "23505" }), /already exists/);
  assert.throws(() => parseFieldId("park name"), /saved field/);
});

test("catalog and game endpoints enforce admin identity, never client venue coordinates", () => {
  for (const file of ["fields/route.ts", "fields/[id]/route.ts", "solo-games/route.ts"]) {
    const source = readFileSync(new URL(`../src/app/api/referee/admin/${file}`, import.meta.url), "utf8");
    assert.match(source, /await requireReferee\(request\)/);
    assert.match(source, /adminOnly\(context\.referee\)/);
    assert.match(source, /actor_admin_id: context\.referee\.profileId/);
  }
  const create = readFileSync(new URL("../src/app/api/referee/admin/solo-games/route.ts", import.meta.url), "utf8");
  assert.match(create, /field_id_to_use: input\.fieldId/);
  assert.doesNotMatch(create, /venue_to_use|latitude|longitude/);
});
