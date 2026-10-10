import assert from "node:assert/strict";
import test from "node:test";

import {
  normalizeAdminSupportTicket,
  parseAdminSupportActionInput,
  parseSupportTicketStatusFilter,
  supportTicketReference,
} from "../src/lib/admin-support.ts";

const TICKET_ID = "11111111-1111-4111-8111-111111111111";
const PLAYER_ID = "22222222-2222-4222-8222-222222222222";
const ADMIN_ID = "33333333-3333-4333-8333-333333333333";

test("support status filters include the active queue without accepting arbitrary input", () => {
  assert.equal(parseSupportTicketStatusFilter(undefined), "ACTIVE");
  assert.equal(parseSupportTicketStatusFilter(" in_progress "), "IN_PROGRESS");
  assert.equal(parseSupportTicketStatusFilter("all"), "ALL");
  assert.throws(
    () => parseSupportTicketStatusFilter("DELETED"),
    /unknown support ticket status/i,
  );
});

test("support actions require an optimistic revision and appropriate notes", () => {
  assert.deepEqual(
    parseAdminSupportActionInput({
      action: "start",
      expectedRevision: 2,
      adminNote: "  Reproducing this on iOS. ",
    }),
    {
      action: "START",
      expectedRevision: 2,
      resolutionNote: null,
      adminNote: "Reproducing this on iOS.",
    },
  );

  assert.deepEqual(
    parseAdminSupportActionInput({
      action: "resolve",
      expectedRevision: 3,
      resolutionNote: "  Your booking was restored.  ",
      adminNote: "Verified against the payment ledger.",
    }),
    {
      action: "RESOLVE",
      expectedRevision: 3,
      resolutionNote: "Your booking was restored.",
      adminNote: "Verified against the payment ledger.",
    },
  );

  assert.throws(
    () => parseAdminSupportActionInput({
      action: "resolve",
      expectedRevision: 3,
      adminNote: "Resolved internally.",
    }),
    /response for the player/i,
  );
  assert.throws(
    () => parseAdminSupportActionInput({
      action: "duplicate",
      expectedRevision: 3,
      resolutionNote: "This request duplicates another ticket.",
    }),
    /which request this duplicates/i,
  );
  assert.deepEqual(
    parseAdminSupportActionInput({
      action: "close",
      expectedRevision: 4,
      adminNote: "Closing after the player-facing resolution was delivered.",
    }),
    {
      action: "CLOSE",
      expectedRevision: 4,
      resolutionNote: null,
      adminNote: "Closing after the player-facing resolution was delivered.",
    },
  );
  assert.throws(
    () => parseAdminSupportActionInput({
      action: "start",
      expectedRevision: 1.5,
    }),
    /refresh this ticket/i,
  );
  assert.throws(
    () => parseAdminSupportActionInput({
      action: "resolve",
      expectedRevision: 5,
      resolutionNote: "x".repeat(2001),
    }),
    /response to the player is too long/i,
  );
  assert.equal(
    parseAdminSupportActionInput({
      action: "start",
      expectedRevision: 5,
      adminNote: "x".repeat(3000),
    }).adminNote?.length,
    3000,
  );
});

test("support tickets hydrate requester and assigned admin without leaking raw rows", () => {
  const profiles = new Map([
    [
      PLAYER_ID,
      {
        id: PLAYER_ID,
        display_name: "Ali Altaraif",
        username: "aliiii",
        avatar_url: "https://example.com/ali.jpg",
      },
    ],
  ]);
  const referees = new Map([
    [
      ADMIN_ID,
      {
        profile_id: ADMIN_ID,
        display_name: "Field Admin",
      },
    ],
  ]);

  assert.deepEqual(
    normalizeAdminSupportTicket(
      {
        id: TICKET_ID,
        requester_profile_id: PLAYER_ID,
        category: "APP_OR_TECHNICAL",
        details: "The replay stays on a loading screen.",
        source: "MOBILE",
        priority: "NORMAL",
        status: "IN_PROGRESS",
        assigned_admin_id: ADMIN_ID,
        resolution_note: null,
        admin_note: "Investigating the recording.",
        revision: 4,
        created_at: "2026-07-16T12:00:00.000Z",
        updated_at: "2026-07-16T12:05:00.000Z",
      },
      profiles,
      referees,
    ),
    {
      id: TICKET_ID,
      reference: "SUP-11111111",
      status: "IN_PROGRESS",
      priority: "NORMAL",
      category: "APP_OR_TECHNICAL",
      subject: "App or technical problem",
      description: "The replay stays on a loading screen.",
      source: "MOBILE",
      requesterId: PLAYER_ID,
      requesterName: "Ali Altaraif",
      requesterUsername: "aliiii",
      requesterAvatarUrl: "https://example.com/ali.jpg",
      assignedTo: "Field Admin",
      resolutionNote: null,
      adminNote: "Investigating the recording.",
      revision: 4,
      createdAt: "2026-07-16T12:00:00.000Z",
      updatedAt: "2026-07-16T12:05:00.000Z",
    },
  );
});

test("support references stay short and stable", () => {
  assert.equal(supportTicketReference(TICKET_ID), "SUP-11111111");
  assert.equal(supportTicketReference(""), "SUP-UNKNOWN");
});
