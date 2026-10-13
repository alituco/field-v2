import type { SupabaseClient } from "@supabase/supabase-js";

import {
  loadAdminGameParticipants,
  type AdminGameParticipants,
} from "./admin-game-participants";
import {
  loadAdminGameReserves,
  type AdminGameReserve,
} from "./admin-game-reserves";
import { loadAdminOpenQueueGames } from "./open-queue-referee-data";
import { loadAdminFixtures } from "./referee-data";
import type { RefereeFixture } from "./types";
import { adminGameCurrency, type AdminGameCurrency } from "./admin-game-money";
import { refundRequiresManualReview } from "./payment-refunds";
import { loadAdminGamePricing, type AdminGamePricing } from "./admin-game-pricing";

export type AdminGameAuditItem = {
  id: string;
  action: string;
  reason: string;
  actorName: string;
  createdAt: string;
};

export type AdminGameReportSummary = {
  id: string;
  category: string;
  status: string;
  priority: string;
  details: string;
  createdAt: string;
};

export type AdminGameStoppageSummary = {
  id: string;
  mode: string;
  state: string;
  reasonCode: string;
  note: string | null;
  createdAt: string;
};

export type AdminGameResolutionRevision = {
  id: string;
  revision: number;
  resolutionType: string;
  reason: string;
  payload: Record<string, unknown>;
  consequenceSnapshot: Record<string, unknown>;
  createdBy: string | null;
  createdAt: string;
  supersedesRevisionId: string | null;
};

export type AdminGameResolutionRefund = {
  id: string;
  revisionId: string | null;
  recipientProfileId: string | null;
  clanId: string | null;
  side: string | null;
  amountFils: number;
  refundBps: number;
  destination: string;
  status: string;
  failureReason: string | null;
  walletTransactionId: string | null;
  paymentRefundId: string | null;
  requiresManualReview: boolean;
  createdAt: string;
  updatedAt: string;
};

export type AdminGameResolutionDispute = {
  id: string;
  revisionId: string | null;
  submittedBy: string | null;
  clanId: string | null;
  reason: string;
  status: string;
  submittedAt: string;
  resolvedAt: string | null;
  resolvedBy: string | null;
  resolutionNote: string | null;
};

export type AdminGameResolutionCase = {
  id: string;
  matchKind: "SOLO" | "CLAN";
  state: string;
  reasonCode: string;
  scheduledEndAt: string;
  detectedAt: string;
  highPriorityAt: string;
  resolvedAt: string | null;
  resolvedBy: string | null;
  currentRevision: number;
  evidenceSnapshot: Record<string, unknown>;
  policySnapshot: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
  revisions: AdminGameResolutionRevision[];
  refunds: AdminGameResolutionRefund[];
  disputes: AdminGameResolutionDispute[];
};

export type AdminGameDetail = {
  fixture: RefereeFixture;
  currency: AdminGameCurrency;
  pricing: AdminGamePricing | null;
  participants: AdminGameParticipants;
  reserves: {
    active: AdminGameReserve[];
    history: AdminGameReserve[];
  };
  assignedReferee: {
    profileId: string;
    displayName: string;
    phone: string;
  } | null;
  ratingSummary:
    | {
        kind: "CLAN";
        home: { skillRating: number; bahrainRank: number | null };
        away: { skillRating: number; bahrainRank: number | null };
      }
    | {
        kind: "SOLO";
        whiteAverageSr: number | null;
        blackAverageSr: number | null;
        matchAverageSr: number | null;
        teamSrSpread: number | null;
        ratedPlayers: number;
      };
  audit: AdminGameAuditItem[];
  reports: AdminGameReportSummary[];
  stoppages: AdminGameStoppageSummary[];
  resolutionCase: AdminGameResolutionCase | null;
};

type Row = Record<string, unknown>;

export async function loadAdminGameDetail(
  db: SupabaseClient,
  matchKind: "SOLO" | "CLAN",
  matchId: string,
): Promise<AdminGameDetail> {
  const gamePromise = matchKind === "SOLO"
    ? loadAdminOpenQueueGames(db)
    : loadAdminFixtures(db);
  const assignmentTable = matchKind === "SOLO"
    ? "open_queue_referee_assignments"
    : "fixture_referee_assignments";
  const assignmentKey = matchKind === "SOLO" ? "game_id" : "fixture_id";
  const entityType = matchKind === "SOLO" ? "SOLO_MATCH" : "CLAN_MATCH";
  const reportKey = matchKind === "SOLO" ? "open_queue_game_id" : "fixture_id";

  const [
    games,
    participants,
    reserves,
    assignmentResult,
    auditResult,
    reportResult,
    stoppageResult,
    ratingSummary,
    resolutionCase,
    currencyResult,
    pricing,
  ] = await Promise.all([
    gamePromise,
    loadAdminGameParticipants(db, matchKind, matchId),
    loadAdminGameReserves(db, matchKind, matchId),
    db.from(assignmentTable).select(`
      referee_id,
      referee:referee_profiles!${assignmentTable}_referee_id_fkey(
        profile_id,
        display_name,
        phone
      )
    `).eq(assignmentKey, matchId).maybeSingle(),
    db.from("admin_audit_events").select(`
      id,
      action,
      reason,
      created_at,
      actor:referee_profiles!admin_audit_events_actor_referee_id_fkey(
        display_name
      )
    `).eq("entity_type", entityType).eq("entity_id", matchId)
      .order("created_at", { ascending: false }).limit(30),
    db.from("moderation_reports")
      .select("id,category,status,priority,details,created_at")
      .eq(reportKey, matchId).order("created_at", { ascending: false }).limit(20),
    db.from("match_stoppages")
      .select("id,mode,state,reason_code,note,created_at")
      .eq(reportKey, matchId).order("created_at", { ascending: false }).limit(20),
    matchKind === "CLAN"
      ? loadClanRatingSummary(db, matchId)
      : loadSoloRatingSummary(db, matchId),
    loadAdminGameResolution(db, matchKind, matchId),
    db.from(matchKind === "SOLO" ? "open_queue_games" : "fixtures")
      .select("currency").eq("id", matchId).single(),
    matchKind === "SOLO" ? loadAdminGamePricing(db, matchId) : Promise.resolve(null),
  ]);

  const fixture = games.find((game) => game.id === matchId);
  if (!fixture) throw new Error(matchKind === "SOLO" ? "Solo game not found." : "Clan fixture not found.");
  if (assignmentResult.error) throw new Error(`Could not load referee: ${assignmentResult.error.message}`);
  if (auditResult.error) throw new Error(`Could not load game audit: ${auditResult.error.message}`);
  if (reportResult.error) throw new Error(`Could not load game reports: ${reportResult.error.message}`);
  if (stoppageResult.error) throw new Error(`Could not load stoppages: ${stoppageResult.error.message}`);
  if (currencyResult.error) throw new Error(`Could not load game currency: ${currencyResult.error.message}`);

  const assignment = assignmentResult.data as Row | null;
  const referee = relation(assignment?.referee);
  return {
    fixture,
    currency: adminGameCurrency(matchKind, currencyResult.data?.currency),
    pricing,
    participants,
    reserves,
    assignedReferee: assignment && referee.profile_id ? {
      profileId: text(referee.profile_id),
      displayName: text(referee.display_name, "Referee"),
      phone: text(referee.phone),
    } : null,
    ratingSummary,
    audit: rows(auditResult.data).map((row) => ({
      id: text(row.id),
      action: text(row.action),
      reason: text(row.reason),
      actorName: text(relation(row.actor).display_name, "Administrator"),
      createdAt: text(row.created_at),
    })),
    reports: rows(reportResult.data).map((row) => ({
      id: text(row.id),
      category: text(row.category),
      status: text(row.status),
      priority: text(row.priority),
      details: text(row.details),
      createdAt: text(row.created_at),
    })),
    stoppages: rows(stoppageResult.data).map((row) => ({
      id: text(row.id),
      mode: text(row.mode),
      state: text(row.state),
      reasonCode: text(row.reason_code),
      note: nullableText(row.note),
      createdAt: text(row.created_at),
    })),
    resolutionCase,
  };
}

async function loadAdminGameResolution(
  db: SupabaseClient,
  matchKind: "SOLO" | "CLAN",
  matchId: string,
): Promise<AdminGameResolutionCase | null> {
  const matchColumn = matchKind === "CLAN" ? "fixture_id" : "open_queue_game_id";
  const { data: caseData, error: caseError } = await db
    .from("match_resolution_cases")
    .select(
      "id,match_kind,fixture_id,open_queue_game_id,state,reason_code,scheduled_end_at,detected_at,high_priority_at,resolved_at,resolved_by,current_revision,evidence_snapshot,policy_snapshot,created_at,updated_at",
    )
    .eq("match_kind", matchKind)
    .eq(matchColumn, matchId)
    .maybeSingle();
  if (caseError) {
    throw new Error(`Could not load match resolution: ${caseError.message}`);
  }
  if (!caseData) return null;

  const caseRow = caseData as Row;
  const caseId = text(caseRow.id);
  const [revisionResult, refundResult, disputeResult] = await Promise.all([
    db.from("match_resolution_revisions")
      .select(
        "id,case_id,revision,resolution_type,reason,payload,consequence_snapshot,created_by,created_at,supersedes_revision_id",
      )
      .eq("case_id", caseId)
      .order("revision", { ascending: false }),
    db.from("match_resolution_refunds")
      .select(
        "id,case_id,revision_id,recipient_profile_id,clan_id,side,amount_fils,refund_bps,destination,status,failure_reason,wallet_transaction_id,payment_refund_id,created_at,updated_at,payment_refund:payment_refunds(provider_status,payment_intent:payment_intents(external_refund_review_required))",
      )
      .eq("case_id", caseId)
      .order("created_at", { ascending: false }),
    db.from("match_resolution_disputes")
      .select(
        "id,case_id,revision_id,submitted_by,clan_id,reason,status,submitted_at,resolved_at,resolved_by,resolution_note",
      )
      .eq("case_id", caseId)
      .order("submitted_at", { ascending: false }),
  ]);
  const firstError = [
    revisionResult,
    refundResult,
    disputeResult,
  ].find((result) => result.error)?.error;
  if (firstError) {
    throw new Error(`Could not load match resolution history: ${firstError.message}`);
  }

  return {
    id: caseId,
    matchKind,
    state: text(caseRow.state, "NO_DATA").toUpperCase(),
    reasonCode: text(caseRow.reason_code, "NO_ACTIVITY").toUpperCase(),
    scheduledEndAt: text(caseRow.scheduled_end_at),
    detectedAt: text(caseRow.detected_at),
    highPriorityAt: text(caseRow.high_priority_at),
    resolvedAt: nullableText(caseRow.resolved_at),
    resolvedBy: nullableText(caseRow.resolved_by),
    currentRevision: integer(caseRow.current_revision),
    evidenceSnapshot: record(caseRow.evidence_snapshot),
    policySnapshot: record(caseRow.policy_snapshot),
    createdAt: text(caseRow.created_at),
    updatedAt: text(caseRow.updated_at),
    revisions: rows(revisionResult.data).map((row) => ({
      id: text(row.id),
      revision: integer(row.revision),
      resolutionType: text(row.resolution_type),
      reason: text(row.reason),
      payload: record(row.payload),
      consequenceSnapshot: record(row.consequence_snapshot),
      createdBy: nullableText(row.created_by),
      createdAt: text(row.created_at),
      supersedesRevisionId: nullableText(row.supersedes_revision_id),
    })),
    refunds: rows(refundResult.data).map((row) => ({
      id: text(row.id),
      revisionId: nullableText(row.revision_id),
      recipientProfileId: nullableText(row.recipient_profile_id),
      clanId: nullableText(row.clan_id),
      side: nullableText(row.side),
      amountFils: integer(row.amount_fils),
      refundBps: integer(row.refund_bps),
      destination: text(row.destination, "FIELD_WALLET"),
      status: text(row.status, "PENDING").toUpperCase(),
      failureReason: nullableText(row.failure_reason),
      walletTransactionId: nullableText(row.wallet_transaction_id),
      paymentRefundId: nullableText(row.payment_refund_id),
      requiresManualReview: refundRequiresManualReview(relation(row.payment_refund)),
      createdAt: text(row.created_at),
      updatedAt: text(row.updated_at),
    })),
    disputes: rows(disputeResult.data).map((row) => ({
      id: text(row.id),
      revisionId: nullableText(row.revision_id),
      submittedBy: nullableText(row.submitted_by),
      clanId: nullableText(row.clan_id),
      reason: text(row.reason),
      status: text(row.status, "OPEN").toUpperCase(),
      submittedAt: text(row.submitted_at),
      resolvedAt: nullableText(row.resolved_at),
      resolvedBy: nullableText(row.resolved_by),
      resolutionNote: nullableText(row.resolution_note),
    })),
  };
}

async function loadClanRatingSummary(
  db: SupabaseClient,
  fixtureId: string,
): Promise<Extract<AdminGameDetail["ratingSummary"], { kind: "CLAN" }>> {
  const [{ data: fixture, error: fixtureError }, { data: clans, error: clansError }] =
    await Promise.all([
      db.from("fixtures")
        .select("home_clan_id,away_clan_id")
        .eq("id", fixtureId)
        .maybeSingle(),
      db.from("clans")
        .select("id,skill_rating")
        .is("archived_at", null)
        .order("skill_rating", { ascending: false })
        .order("name", { ascending: true }),
    ]);
  if (fixtureError) throw new Error(`Could not load clan ratings: ${fixtureError.message}`);
  if (clansError) throw new Error(`Could not load clan rankings: ${clansError.message}`);

  const homeId = text((fixture as Row | null)?.home_clan_id);
  const awayId = text((fixture as Row | null)?.away_clan_id);
  const ranked = rows(clans);
  const home = ranked.find((row) => text(row.id) === homeId);
  const away = ranked.find((row) => text(row.id) === awayId);
  return {
    kind: "CLAN",
    home: {
      skillRating: integer(home?.skill_rating, 1500),
      bahrainRank: rankOf(ranked, homeId),
    },
    away: {
      skillRating: integer(away?.skill_rating, 1500),
      bahrainRank: rankOf(ranked, awayId),
    },
  };
}

async function loadSoloRatingSummary(
  db: SupabaseClient,
  gameId: string,
): Promise<Extract<AdminGameDetail["ratingSummary"], { kind: "SOLO" }>> {
  const { data: bookings, error: bookingError } = await db
    .from("open_queue_bookings")
    .select("profile_id,role,rating_track,team,rating_at_team_assignment")
    .eq("game_id", gameId)
    .eq("status", "CONFIRMED");
  if (bookingError) throw new Error(`Could not load solo ratings: ${bookingError.message}`);

  const bookingRows = rows(bookings);
  const missingRatingIds = bookingRows
    .filter((row) => nullableInteger(row.rating_at_team_assignment) === null)
    .map((row) => text(row.profile_id))
    .filter(Boolean);
  const currentRatings = new Map<string, number>();
  if (missingRatingIds.length) {
    const { data, error } = await db.from("fieldrush_player_rating_tracks")
      .select("profile_id,rating_track,skill_rating")
      .in("profile_id", [...new Set(missingRatingIds)]);
    if (error) throw new Error(`Could not load current player ratings: ${error.message}`);
    for (const row of rows(data)) {
      currentRatings.set(`${text(row.profile_id)}:${text(row.rating_track)}`, integer(row.skill_rating, 1200));
    }
  }

  const rated = bookingRows.map((row) => ({
    team: text(row.team).toUpperCase(),
    rating: nullableInteger(row.rating_at_team_assignment) ??
      currentRatings.get(`${text(row.profile_id)}:${text(row.rating_track, text(row.role).toUpperCase() === "GK" ? "GOALKEEPER" : "OUTFIELD")}`) ?? 1200,
  }));
  const whiteAverageSr = average(rated.filter((row) => row.team === "WHITE").map((row) => row.rating));
  const blackAverageSr = average(rated.filter((row) => row.team === "BLACK").map((row) => row.rating));
  return {
    kind: "SOLO",
    whiteAverageSr,
    blackAverageSr,
    matchAverageSr: average(rated.map((row) => row.rating)),
    teamSrSpread: whiteAverageSr === null || blackAverageSr === null
      ? null
      : Math.abs(whiteAverageSr - blackAverageSr),
    ratedPlayers: rated.length,
  };
}

function rankOf(ranked: Row[], id: string) {
  const index = ranked.findIndex((row) => text(row.id) === id);
  return index < 0 ? null : index + 1;
}

function average(values: number[]) {
  if (!values.length) return null;
  return Math.round(values.reduce((sum, value) => sum + value, 0) / values.length);
}

function integer(value: unknown, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.round(parsed) : fallback;
}

function nullableInteger(value: unknown) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.round(parsed) : null;
}

function relation(value: unknown): Row {
  if (Array.isArray(value)) return relation(value[0]);
  return value && typeof value === "object" ? value as Row : {};
}

function rows(value: unknown): Row[] {
  return Array.isArray(value)
    ? value.filter((row): row is Row => Boolean(row) && typeof row === "object")
    : [];
}

function record(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Row
    : {};
}

function text(value: unknown, fallback = "") {
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function nullableText(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}
