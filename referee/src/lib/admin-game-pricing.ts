import type { SupabaseClient } from "@supabase/supabase-js";
import type { AdminGameCurrency } from "./admin-game-money";

type Row = Record<string, unknown>;

export type AdminGameBookingPayment = {
  bookingId: string;
  profileId: string;
  displayName: string;
  status: string;
  bookedAt: string;
  matchFeeFils: number | null;
  depositFils: number | null;
  paidTotalFils: number | null;
  refundedFils: number | null;
  currency: AdminGameCurrency;
  paymentStatus: string;
};

export type AdminGamePricing = {
  priceFils: number;
  currency: AdminGameCurrency;
  canEdit: boolean;
  lockedReason: string | null;
  bookings: AdminGameBookingPayment[];
};

type PricingRecords = {
  game: Row;
  bookings: Row[];
  clock?: Row | null;
  paymentIntents?: Row[];
  refunds?: Row[];
  externalRefunds?: Row[];
  walletTransactions?: Row[];
  now?: Date;
};

function text(value: unknown, fallback = ""): string {
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

/** Missing/invalid historical values are unknown, never silently zero. */
function money(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) return null;
  return value;
}

function currency(value: unknown): AdminGameCurrency {
  if (value === "USD" || value === "BHD") return value;
  throw new Error("The recorded payment currency is missing or unsupported.");
}

function relation(value: unknown): Row {
  if (Array.isArray(value)) return relation(value[0]);
  return value && typeof value === "object" ? value as Row : {};
}

export function soloPriceLockedReason(game: Row, clock: Row | null = null, now = new Date()): string | null {
  if (game.currency !== "USD" || game.format_version !== "FIELDRUSH_7V7") {
    return "Historical game prices are read-only. Only Fieldrush USD games can be edited.";
  }
  if (!["OPEN", "FULL"].includes(text(game.status))) {
    return "Only upcoming open or full games can have their price changed.";
  }
  const startsAt = Date.parse(text(game.starts_at));
  if (!Number.isFinite(startsAt) || startsAt <= now.getTime()) {
    return "The game has reached its scheduled kickoff. Its price can no longer change.";
  }
  if (game.operational_state !== "NORMAL") {
    return "Resolve the game's operational review before changing its price.";
  }
  if (clock && (clock.status !== "NOT_STARTED" || clock.started_at != null || clock.accumulated_seconds !== 0)) {
    return "The match clock has already started. Its price can no longer change.";
  }
  return null;
}

function actualRefundedAmount(booking: Row, intent: Row | undefined, records: PricingRecords, paidCurrency: AdminGameCurrency): number | null {
  const intentId = text(booking.payment_intent_id);
  const bookedId = text(booking.id);
  const successful = (records.refunds ?? []).filter((row) => row.intent_id === intentId && row.status === "SUCCEEDED");
  const external = (records.externalRefunds ?? []).filter((row) => row.intent_id === intentId && row.provider_status === "succeeded");
  const credits = (records.walletTransactions ?? []).filter((row) => row.booking_id === bookedId && row.direction === "CREDIT");
  if (intentId && !intent) return null;

  let amount = 0;
  let hasEvidence = false;
  const providerRefundIds = new Set<string>();
  for (const row of [...successful, ...external]) {
    const providerId = text(row.provider_refund_id);
    if (providerId && providerRefundIds.has(providerId)) continue;
    if (providerId) providerRefundIds.add(providerId);
    const minor = money(row.amount_minor);
    if (row.currency !== paidCurrency || minor === null) return null;
    // amount_fils is the policy entitlement. A successful rounding-carry row
    // may transfer zero cents; only the provider's actual minor units count.
    amount += paidCurrency === "USD" ? minor * 10 : minor;
    hasEvidence = true;
  }
  for (const row of credits) {
    const credited = money(row.amount_fils);
    if (row.currency !== paidCurrency || credited === null) return null;
    amount += credited;
    hasEvidence = true;
  }
  if (!Number.isSafeInteger(amount)) return null;
  if (!hasEvidence && (booking.refund_status === "PROCESSED" || booking.payment_status === "REFUNDED" || intent?.status === "REFUNDED")) {
    // Older records can report a completed refund without its transfer ledger.
    // Do not substitute a requested refund or the game's present-day price.
    return null;
  }
  return amount;
}

export function buildAdminGamePricing(records: PricingRecords): AdminGamePricing {
  const gameCurrency = currency(records.game.currency);
  const priceFils = money(records.game.price_fils);
  if (priceFils === null) throw new Error("The recorded game price is missing or invalid.");
  const lockedReason = soloPriceLockedReason(records.game, records.clock, records.now);
  const intents = new Map((records.paymentIntents ?? []).map((row) => [text(row.id), row]));
  return {
    priceFils,
    currency: gameCurrency,
    canEdit: lockedReason === null,
    lockedReason,
    bookings: records.bookings.map((booking) => {
      const intent = intents.get(text(booking.payment_intent_id));
      const recordedCurrency = intent ? currency(intent.currency) : gameCurrency;
      if (recordedCurrency !== gameCurrency) throw new Error("The booking and game currencies do not match. Review the payment ledger.");
      return {
        bookingId: text(booking.id),
        profileId: text(booking.profile_id),
        displayName: text(relation(booking.profile).display_name, "Player"),
        status: text(booking.status, "UNKNOWN"),
        bookedAt: text(booking.booked_at),
        matchFeeFils: money(booking.base_amount_fils),
        depositFils: money(booking.reliability_deposit_fils),
        paidTotalFils: money(booking.amount_paid_fils),
        refundedFils: actualRefundedAmount(booking, intent, records, recordedCurrency),
        currency: recordedCurrency,
        paymentStatus: text(booking.payment_status, "NOT_RECORDED"),
      };
    }),
  };
}

/** Admin-only caller; every SELECT is an allowlist, never raw provider objects. */
export async function loadAdminGamePricing(db: SupabaseClient, gameId: string): Promise<AdminGamePricing> {
  const [{ data: game, error: gameError }, { data: clock, error: clockError }] = await Promise.all([
    db.from("open_queue_games").select("id,price_fils,currency,format_version,status,starts_at,operational_state").eq("id", gameId).single(),
    db.from("open_queue_clock_states").select("status,started_at,accumulated_seconds").eq("game_id", gameId).maybeSingle(),
  ]);
  if (gameError || !game) throw new Error(`Could not load game pricing: ${gameError?.message ?? "Game not found."}`);
  if (clockError) throw new Error(`Could not load game pricing state: ${clockError.message}`);
  const bookings = await allRows((from, to) => db.from("open_queue_bookings")
    .select("id,profile_id,status,booked_at,base_amount_fils,reliability_deposit_fils,amount_paid_fils,payment_status,refund_status,payment_intent_id,profile:profiles!open_queue_bookings_profile_id_fkey(display_name)")
    .eq("game_id", gameId).order("booked_at").order("id").range(from, to), "booking payment history");
  const intentIds = [...new Set(bookings.map((row) => text(row.payment_intent_id)).filter(Boolean))];
  const bookingIds = bookings.map((row) => text(row.id));
  const [paymentIntents, refunds, externalRefunds, walletTransactions] = await Promise.all([
    byIds(intentIds, (ids, from, to) => db.from("payment_intents").select("id,currency,status").in("id", ids).order("id").range(from, to), "recorded payments"),
    byIds(intentIds, (ids, from, to) => db.from("payment_refunds").select("id,intent_id,status,amount_minor,currency,provider_refund_id").in("intent_id", ids).eq("status", "SUCCEEDED").order("id").range(from, to), "completed refunds"),
    byIds(intentIds, (ids, from, to) => db.from("external_payment_refunds").select("intent_id,provider_status,amount_minor,currency,provider_refund_id").in("intent_id", ids).eq("provider_status", "succeeded").order("provider_refund_id").range(from, to), "external refunds"),
    byIds(bookingIds, (ids, from, to) => db.from("field_wallet_transactions").select("id,booking_id,direction,amount_fils,currency").in("booking_id", ids).eq("direction", "CREDIT").order("id").range(from, to), "historical wallet refunds"),
  ]);
  return buildAdminGamePricing({ game, clock, bookings, paymentIntents, refunds, externalRefunds, walletTransactions });
}

type QueryResult = PromiseLike<{ data: unknown; error: { message: string } | null }>;
async function allRows(query: (from: number, to: number) => QueryResult, label: string): Promise<Row[]> {
  const result: Row[] = [];
  const pageSize = 500;
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await query(from, from + pageSize - 1);
    if (error) throw new Error(`Could not load ${label}: ${error.message}`);
    const page = Array.isArray(data) ? data as Row[] : [];
    result.push(...page);
    if (page.length < pageSize) return result;
  }
}

async function byIds(ids: string[], query: (ids: string[], from: number, to: number) => QueryResult, label: string): Promise<Row[]> {
  const result: Row[] = [];
  // Bound the REST URL size as well as Supabase's default response row limit.
  for (let index = 0; index < ids.length; index += 100) {
    result.push(...await allRows((from, to) => query(ids.slice(index, index + 100), from, to), label));
  }
  return result;
}
