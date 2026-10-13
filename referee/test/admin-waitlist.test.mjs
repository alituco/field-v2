import assert from "node:assert/strict";
import test from "node:test";

import {
  filterAdminWaitlist,
  isLaunchUpdatesSubscriber,
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
    launchUpdatesConsentedAt: null,
    launchUpdatesConsentVersion: null,
    signupPlacement: null,
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
      interest: null,
      status: "WAITING",
      source: "FIELD_BH",
      createdAt: null,
      updatedAt: null,
      launchUpdatesConsentedAt: null,
      launchUpdatesConsentVersion: null,
      signupPlacement: null,
    },
  );
});

test("email-only launch signup retains consent without inventing player details", () => {
  const signup = normalizeAdminWaitlistApplicant({
    id: "44444444-4444-4444-8444-444444444444",
    email: "launch@example.com",
    full_name: null,
    age: null,
    preferred_position: null,
    interest: "LAUNCH_UPDATES",
    status: "WAITING",
    source: "FIELDRUSH_GG",
    launch_updates_consented_at: "2026-10-12T20:00:00Z",
    launch_updates_consent_version: "launch-updates-v1",
    signup_placement: "desktop-hero",
  });

  assert.equal(signup.fullName, null);
  assert.equal(signup.age, null);
  assert.equal(signup.phone, null);
  assert.equal(signup.preferredPosition, null);
  assert.equal(signup.interest, "LAUNCH_UPDATES");
  assert.equal(signup.source, "FIELDRUSH_GG");
  assert.equal(signup.signupPlacement, "desktop-hero");
  assert.equal(signup.launchUpdatesConsentVersion, "launch-updates-v1");
  assert.equal(isLaunchUpdatesSubscriber(signup), true);
  assert.deepEqual(filterAdminWaitlist([signup], { query: "launch@example.com" }), [signup]);
});

test("launch updates filter includes opted-in existing applicants without changing their interests", () => {
  const subscribedApplicant = {
    ...applicants[1],
    launchUpdatesConsentedAt: "2026-10-12T21:00:00Z",
    launchUpdatesConsentVersion: "launch-updates-v1",
    signupPlacement: "mobile-footer",
  };
  const entries = [applicants[0], subscribedApplicant];

  assert.equal(isLaunchUpdatesSubscriber(applicants[0]), false);
  assert.equal(subscribedApplicant.interest, "CLAN_LEADER");
  assert.equal(subscribedApplicant.source, "FIELD_BH");
  assert.equal(subscribedApplicant.status, "SELECTED");
  assert.deepEqual(
    filterAdminWaitlist(entries, { interest: "LAUNCH_UPDATES" }),
    [subscribedApplicant],
  );
  assert.deepEqual(
    filterAdminWaitlist(entries, { interest: "LAUNCH_UPDATES", query: "launch", status: "SELECTED" }),
    [subscribedApplicant],
  );
  assert.deepEqual(
    filterAdminWaitlist(entries, { interest: "LAUNCH_UPDATES", query: "hero" }),
    [],
  );
  assert.deepEqual(
    filterAdminWaitlist(entries, { interest: "CLAN_LEADER", position: "DEFENDER" }),
    [subscribedApplicant],
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
