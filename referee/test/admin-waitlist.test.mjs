import assert from "node:assert/strict";
import test from "node:test";

import {
  filterAdminWaitlist,
  normalizeAdminWaitlistApplicant,
} from "../src/lib/admin-waitlist.ts";

const applicants = [
  normalizeAdminWaitlistApplicant({
    id: "11111111-1111-4111-8111-111111111111",
    full_name: "Ali Altaraif",
    email: "ali@example.com",
    phone: "+973 3900 0000",
    age: 22,
    preferred_position: "MIDFIELDER",
    interest: "SOLO_PLAYER",
    status: "WAITING",
    source: "FIELD_BH",
    created_at: "2026-07-17T23:58:00.000Z",
    updated_at: "2026-07-17T23:58:00.000Z",
  }),
  normalizeAdminWaitlistApplicant({
    id: "22222222-2222-4222-8222-222222222222",
    full_name: "Noor Saleh",
    email: "noor@example.com",
    phone: null,
    age: "16",
    preferred_position: "DEFENDER",
    interest: "CLAN_LEADER",
    status: "SELECTED",
    source: "FIELD_BH",
    created_at: "2026-07-17T22:00:00.000Z",
    updated_at: "2026-07-17T22:30:00.000Z",
  }),
];

test("waitlist applicants normalize private form data into the admin shape", () => {
  assert.deepEqual(applicants[0], {
    id: "11111111-1111-4111-8111-111111111111",
    fullName: "Ali Altaraif",
    email: "ali@example.com",
    phone: "+973 3900 0000",
    age: 22,
    preferredPosition: "MIDFIELDER",
    interest: "SOLO_PLAYER",
    status: "WAITING",
    source: "FIELD_BH",
    createdAt: "2026-07-17T23:58:00.000Z",
    updatedAt: "2026-07-17T23:58:00.000Z",
  });
});

test("waitlist normalization safely handles legacy and invalid optional values", () => {
  assert.deepEqual(
    normalizeAdminWaitlistApplicant({
      id: "33333333-3333-4333-8333-333333333333",
      full_name: " Legacy Applicant ",
      email: "legacy@example.com",
      age: null,
      preferred_position: "WINGER",
      interest: "UNKNOWN",
      status: "UNKNOWN",
    }),
    {
      id: "33333333-3333-4333-8333-333333333333",
      fullName: "Legacy Applicant",
      email: "legacy@example.com",
      phone: null,
      age: null,
      preferredPosition: null,
      interest: "SOLO_PLAYER",
      status: "WAITING",
      source: "FIELD_BH",
      createdAt: null,
      updatedAt: null,
    },
  );
});

test("waitlist search and filters can be combined", () => {
  assert.deepEqual(
    filterAdminWaitlist(applicants, {
      query: "noor",
      status: "SELECTED",
      interest: "CLAN_LEADER",
      position: "DEFENDER",
    }).map((applicant) => applicant.fullName),
    ["Noor Saleh"],
  );

  assert.deepEqual(
    filterAdminWaitlist(applicants, {
      query: "3900",
      status: "ALL",
      interest: "ALL",
      position: "ALL",
    }).map((applicant) => applicant.fullName),
    ["Ali Altaraif"],
  );

  assert.equal(
    filterAdminWaitlist(applicants, {
      status: "ONBOARDED",
    }).length,
    0,
  );
});
