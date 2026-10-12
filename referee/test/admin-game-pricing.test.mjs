import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

import { buildAdminGamePricing, loadAdminGamePricing, soloPriceLockedReason } from "../src/lib/admin-game-pricing.ts";

const now = new Date("2026-10-11T12:00:00Z");
const game = {
  id: "game-1", price_fils: 20000, currency: "USD", format_version: "FIELDRUSH_7V7",
  status: "OPEN", starts_at: "2026-10-17T23:00:00Z", operational_state: "NORMAL",
};
const booking = {
  id: "booking-1", profile_id: "player-1", profile: { display_name: "Ali A." },
  status: "CONFIRMED", booked_at: "2026-10-10T12:00:00Z", base_amount_fils: 13000,
  reliability_deposit_fils: 3000, amount_paid_fils: 16000, payment_status: "PAID",
  refund_status: "NOT_DUE", payment_intent_id: "intent-1",
};
const intent = { id: "intent-1", currency: "USD", status: "FINALIZED" };
const build = (overrides = {}) => buildAdminGamePricing({ game, bookings: [booking], paymentIntents: [intent], now, ...overrides });

test("each booking keeps its original paid price and deposit after the game price changes", () => {
  const result = build({ bookings: [booking, {
    ...booking, id: "booking-2", profile_id: "player-2", base_amount_fils: 15000,
    reliability_deposit_fils: 0, amount_paid_fils: 15000, payment_intent_id: "intent-2",
  }], paymentIntents: [intent, { ...intent, id: "intent-2" }] });
  assert.equal(result.priceFils, 20000);
  assert.deepEqual(result.bookings.map(({ matchFeeFils, depositFils, paidTotalFils }) =>
    [matchFeeFils, depositFils, paidTotalFils]), [[13000, 3000, 16000], [15000, 0, 15000]]);
});

test("cancelled and rebooked rows for the same player remain separate history entries", () => {
  const result = build({ bookings: [
    { ...booking, status: "CANCELLED" },
    { ...booking, id: "booking-2", booked_at: "2026-10-11T01:00:00Z", payment_intent_id: "intent-2" },
  ], paymentIntents: [intent, { ...intent, id: "intent-2" }] });
  assert.deepEqual(result.bookings.map(({ bookingId, profileId, status }) =>
    [bookingId, profileId, status]), [["booking-1", "player-1", "CANCELLED"], ["booking-2", "player-1", "CONFIRMED"]]);
});

test("free bookings retain actual zero while absent or invalid historical amounts stay unknown", () => {
  const result = build({ bookings: [
    { ...booking, id: "free", base_amount_fils: 0, reliability_deposit_fils: 0, amount_paid_fils: 0, payment_intent_id: null },
    { id: "unknown", profile_id: "player-2", base_amount_fils: null, reliability_deposit_fils: undefined, amount_paid_fils: "13000" },
    { id: "invalid", base_amount_fils: -1, reliability_deposit_fils: 2.5, amount_paid_fils: Infinity },
  ] });
  assert.deepEqual(result.bookings.map(({ matchFeeFils, depositFils, paidTotalFils }) =>
    [matchFeeFils, depositFils, paidTotalFils]), [[0, 0, 0], [null, null, null], [null, null, null]]);
  assert.equal(result.bookings[1].paymentStatus, "NOT_RECORDED");
  assert.equal(result.bookings[1].displayName, "Player");
  assert.equal(result.bookings[0].refundedFils, 0);
});

test("refund totals include actual successful transfers, not pending entitlements or rounding carries", () => {
  const result = build({
    bookings: [{ ...booking, refund_amount_fils: 16000, refund_status: "PROCESSING" }],
    refunds: [
      { intent_id: "intent-1", status: "SUCCEEDED", amount_fils: 6505, amount_minor: 650, currency: "USD", provider_refund_id: "re-1" },
      { intent_id: "intent-1", status: "SUCCEEDED", amount_fils: 7, amount_minor: 0, currency: "USD" },
      { intent_id: "intent-1", status: "PENDING", amount_minor: 100, currency: "USD" },
      { intent_id: "intent-1", status: "FAILED", amount_minor: 100, currency: "USD" },
      { intent_id: "different-intent", status: "SUCCEEDED", amount_minor: 900, currency: "USD" },
    ],
    externalRefunds: [
      { intent_id: "intent-1", provider_status: "succeeded", amount_minor: 650, currency: "USD", provider_refund_id: "re-1" },
      { intent_id: "intent-1", provider_status: "succeeded", amount_minor: 200, currency: "USD", provider_refund_id: "re-2" },
      { intent_id: "intent-1", provider_status: "pending", amount_minor: 100, currency: "USD", provider_refund_id: "re-3" },
    ],
    walletTransactions: [
      { booking_id: "booking-1", direction: "CREDIT", amount_fils: 300, currency: "USD" },
      { booking_id: "booking-1", direction: "DEBIT", amount_fils: 900, currency: "USD" },
      { booking_id: "other-booking", direction: "CREDIT", amount_fils: 900, currency: "USD" },
    ],
  });
  assert.equal(result.bookings[0].refundedFils, 8800);
});

test("a pending refund is zero refunded, not the requested refund amount", () => {
  const result = build({ bookings: [{ ...booking, refund_status: "DUE", refund_amount_fils: 16000 }],
    refunds: [{ intent_id: "intent-1", status: "PENDING", amount_minor: 1600, currency: "USD" }] });
  assert.equal(result.bookings[0].refundedFils, 0);
});

test("missing or inconsistent refund evidence stays unknown rather than inventing a historical total", () => {
  for (const overrides of [
    { bookings: [{ ...booking, refund_status: "PROCESSED" }] },
    { bookings: [{ ...booking, payment_status: "REFUNDED" }] },
    { paymentIntents: [{ ...intent, status: "REFUNDED" }] },
    { paymentIntents: [] },
    { refunds: [{ intent_id: "intent-1", status: "SUCCEEDED", amount_fils: 3000, amount_minor: null, currency: "USD" }] },
    { refunds: [{ intent_id: "intent-1", status: "SUCCEEDED", amount_minor: 300, currency: "BHD" }] },
  ]) assert.equal(build(overrides).bookings[0].refundedFils, null);
});

test("legacy BHD uses its recorded precision, wallet ledger and read-only game pricing", () => {
  const result = build({ game: { ...game, currency: "BHD", format_version: "LEGACY_6V6" },
    paymentIntents: [{ ...intent, currency: "BHD" }],
    refunds: [{ intent_id: "intent-1", status: "SUCCEEDED", amount_minor: 2505, currency: "BHD" }],
    walletTransactions: [{ booking_id: "booking-1", direction: "CREDIT", amount_fils: 1255, currency: "BHD" }],
  });
  assert.equal(result.currency, "BHD");
  assert.equal(result.bookings[0].currency, "BHD");
  assert.equal(result.bookings[0].refundedFils, 3760);
  assert.equal(result.canEdit, false);
  assert.match(result.lockedReason, /Historical/);
});

test("only future normal USD Fieldrush OPEN/FULL games with an unstarted clock can edit", () => {
  for (const status of ["OPEN", "FULL"]) {
    assert.equal(soloPriceLockedReason({ ...game, status }, null, now), null);
    assert.equal(soloPriceLockedReason({ ...game, status }, { status: "NOT_STARTED", started_at: null, accumulated_seconds: 0 }, now), null);
  }
  for (const changedGame of [
    ...["LIVE", "FINAL", "CANCELLED", "LOCKED"].map((status) => ({ ...game, status })),
    ...["NO_DATA", "UNDER_REVIEW", "RESOLVED"].map((operational_state) => ({ ...game, operational_state })),
    { ...game, starts_at: now.toISOString() }, { ...game, starts_at: "bad date" },
    { ...game, starts_at: "2026-10-10T00:00:00Z" }, { ...game, format_version: "LEGACY_6V6" },
  ]) assert.notEqual(soloPriceLockedReason(changedGame, null, now), null);
  for (const clock of [
    { status: "RUNNING", started_at: null, accumulated_seconds: 0 },
    { status: "NOT_STARTED", started_at: now.toISOString(), accumulated_seconds: 0 },
    { status: "NOT_STARTED", started_at: null, accumulated_seconds: 1 },
  ]) assert.notEqual(soloPriceLockedReason(game, clock, now), null);
});

test("the response never exposes raw provider data, identifiers or secret fields", () => {
  const result = build({
    bookings: [{ ...booking, provider_charge_id: "provider-secret", secret: "hidden" }],
    paymentIntents: [{ ...intent, client_secret: "secret-value", payload: { secret: "hidden" }, provider_intent_id: "pi-hidden" }],
    refunds: [{ intent_id: "intent-1", status: "SUCCEEDED", amount_minor: 100, currency: "USD", provider_refund_id: "re-hidden" }],
  });
  assert.doesNotMatch(JSON.stringify(result), /provider|secret|hidden|intent-1/);
  assert.throws(() => build({ game: { ...game, currency: null } }), /missing or unsupported/);
  assert.throws(() => build({ game: { ...game, price_fils: null } }), /missing or invalid/);
  assert.throws(() => build({ paymentIntents: [{ ...intent, currency: "BHD" }] }), /currencies do not match/);
});

function database(rowsByTable, errors = {}) {
  const calls = [];
  return {
    calls,
    from(table) {
      const call = { table, columns: "", filters: [], ordering: [], range: null, single: false };
      calls.push(call);
      const query = {
        select(columns) { call.columns = columns; return query; },
        eq(column, value) { call.filters.push({ column, value, type: "eq" }); return query; },
        in(column, value) { call.filters.push({ column, value, type: "in" }); return query; },
        order(column) { call.ordering.push(column); return query; },
        range(from, to) { call.range = [from, to]; return query; },
        single() { call.single = true; return query; },
        maybeSingle() { call.single = true; return query; },
        then(resolve, reject) {
          let rows = (rowsByTable[table] ?? []).filter((row) => call.filters.every(({ column, value, type }) =>
            type === "eq" ? row[column] === value : value.includes(row[column])));
          if (call.range) rows = rows.slice(call.range[0], call.range[1] + 1);
          return Promise.resolve({ data: call.single ? rows[0] ?? null : rows, error: errors[table] ? { message: errors[table] } : null }).then(resolve, reject);
        },
      };
      return query;
    },
  };
}

test("database loader includes cancelled rows, applies allowlists and does not fetch raw provider objects", async () => {
  const db = database({
    open_queue_games: [game],
    open_queue_bookings: [{ ...booking, game_id: game.id, status: "CANCELLED" }],
    payment_intents: [intent],
    payment_refunds: [{ id: "refund-1", intent_id: "intent-1", status: "SUCCEEDED", amount_minor: 200, currency: "USD" }],
  });
  const result = await loadAdminGamePricing(db, game.id);
  assert.equal(result.bookings[0].status, "CANCELLED");
  assert.equal(result.bookings[0].refundedFils, 2000);
  const bookingQuery = db.calls.find((call) => call.table === "open_queue_bookings");
  assert.deepEqual(bookingQuery.filters, [{ column: "game_id", value: game.id, type: "eq" }]);
  for (const call of db.calls) assert.doesNotMatch(call.columns, /\*|client_secret|provider_intent_id|payload|quote_snapshot/);
});

test("database loader reads beyond the default page and chunks identifiers without losing cancelled history", async () => {
  const bookings = Array.from({ length: 501 }, (_, index) => ({
    ...booking, id: `booking-${index}`, game_id: game.id, status: index % 2 ? "CANCELLED" : "CONFIRMED", payment_intent_id: `intent-${index}`,
  }));
  const db = database({ open_queue_games: [game], open_queue_bookings: bookings,
    payment_intents: bookings.map((row) => ({ ...intent, id: row.payment_intent_id })),
  });
  const result = await loadAdminGamePricing(db, game.id);
  assert.equal(result.bookings.length, 501);
  assert.equal(result.bookings[500].bookingId, "booking-500");
  assert.deepEqual(db.calls.filter((call) => call.table === "open_queue_bookings").map((call) => call.range), [[0, 499], [500, 999]]);
  for (const call of db.calls) for (const filter of call.filters) {
    if (filter.type === "in") assert.ok(filter.value.length <= 100);
  }
});

test("database errors are surfaced rather than showing an invented empty payment history", async () => {
  const db = database({ open_queue_games: [game], open_queue_bookings: [{ ...booking, game_id: game.id }], payment_intents: [intent] },
    { payment_refunds: "ledger unavailable" });
  await assert.rejects(loadAdminGamePricing(db, game.id), /Could not load completed refunds: ledger unavailable/);
});

test("only solo game details load the payment ledger; paused clan games return null pricing", () => {
  const source = readFileSync(new URL("../src/lib/admin-game-detail.ts", import.meta.url), "utf8");
  assert.match(source, /matchKind === "SOLO" \? loadAdminGamePricing\(db, matchId\) : Promise\.resolve\(null\)/);
});
