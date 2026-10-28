import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { adminFieldsErrorMessage, parseAdminFieldInput, parseFeaturedFieldInput, parseFieldId, serializeAdminField } from "../src/lib/admin-fields.ts";

const base = { name: " Test pitch ", address: " 123 Test Avenue ", marketCityId: "phoenix", latitude: "33.4484", longitude: "-112.0740" };

test("saved fields require an address and valid map coordinates, with Phoenix defaults", () => {
  assert.deepEqual(parseAdminFieldInput(base), {
    name: "Test pitch", address: "123 Test Avenue", city: "Phoenix", state: "AZ", country_code: "US",
    market_city_id: "phoenix",
    latitude: 33.4484, longitude: -112.074,
  });
  for (const key of ["name", "address", "marketCityId", "latitude", "longitude"]) {
    const invalid = { ...base }; delete invalid[key];
    assert.throws(() => parseAdminFieldInput(invalid), /required/);
  }
});

test("competition city is independent of postal city and rejects forged market data", () => {
  const input = parseAdminFieldInput({ ...base, city: "Tempe", marketCityId: "phoenix" });
  assert.equal(input.city, "Tempe");
  assert.equal(input.market_city_id, "phoenix");
  for (const marketCityId of ["", "Phoenix", "new york", "../phoenix", null, 12]) assert.throws(() => parseAdminFieldInput({ ...base, marketCityId }), /Competition city/);
  assert.throws(() => parseAdminFieldInput({ ...base, timezone: "America/New_York" }), /Unknown field/);
  const field = serializeAdminField({ ...input, id: "test", market: { display_name: "Phoenix", timezone: "America/Phoenix", active: true } });
  assert.equal(field.marketCityName, "Phoenix");
  assert.equal(field.marketTimezone, "America/Phoenix");
  assert.equal(field.marketActive, true);
  assert.equal(field.city, "Tempe");
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

test("featured field commands require a boolean and a valid competition city", () => {
  assert.deepEqual(parseFeaturedFieldInput({ cityId: "phoenix", featured: true }), { cityId: "phoenix", featured: true });
  assert.deepEqual(parseFeaturedFieldInput({ cityId: "new-york", featured: false }), { cityId: "new-york", featured: false });
  for (const invalid of [null, [], {}, { cityId: "phoenix", featured: "true" }, { cityId: "Phoenix", featured: true },
    { cityId: "phoenix", featured: true, actor_admin_id: "forged" }, { cityId: "phoenix", featured: null }]) {
    assert.throws(() => parseFeaturedFieldInput(invalid));
  }
});

test("a featured badge requires an active field in its active selected city", () => {
  const row = { id: "field", is_active: true, market: { active: true, featured_field_id: "field" } };
  assert.equal(serializeAdminField(row).isFeatured, true);
  assert.equal(serializeAdminField({ ...row, is_active: false }).isFeatured, false);
  assert.equal(serializeAdminField({ ...row, market: { active: false, featured_field_id: "field" } }).isFeatured, false);
  assert.equal(serializeAdminField({ ...row, market: { active: true, featured_field_id: "another" } }).isFeatured, false);
  assert.equal(serializeAdminField({ ...row, market: null }).isFeatured, false);
});

test("missing migration and duplicate field errors are actionable", () => {
  for (const code of ["42P01", "42703", "PGRST202", "PGRST204", "PGRST205"]) {
    assert.match(adminFieldsErrorMessage({ code }), /Apply the latest migration/);
  }
  assert.match(adminFieldsErrorMessage({ code: "23505" }), /already exists/);
  assert.throws(() => parseFieldId("park name"), /saved field/);
});

test("catalog and game endpoints enforce admin identity, never client venue coordinates", () => {
  for (const file of ["fields/route.ts", "fields/[id]/route.ts", "fields/[id]/feature/route.ts", "solo-games/route.ts"]) {
    const source = readFileSync(new URL(`../src/app/api/referee/admin/${file}`, import.meta.url), "utf8");
    assert.match(source, /await requireReferee\(request\)/);
    assert.match(source, /adminOnly\(context\.referee\)/);
    assert.match(source, /actor_admin_id: context\.referee\.profileId/);
  }
  const create = readFileSync(new URL("../src/app/api/referee/admin/solo-games/route.ts", import.meta.url), "utf8");
  assert.match(create, /field_id_to_use: input\.fieldId/);
  assert.match(create, /highest_division_to_use: input\.highestDivision/);
  assert.match(create, /lowest_division_to_use: input\.lowestDivision/);
  assert.doesNotMatch(create, /venue_to_use|latitude|longitude/);
});
