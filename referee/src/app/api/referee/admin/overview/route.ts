import { NextRequest, NextResponse } from "next/server";

import { OPEN_REPORT_STATUSES } from "@/lib/admin-moderation";
import { paymentIntentAttention, paymentRefundAttention, refundNeedsAttention } from "@/lib/payment-refunds";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type Row = Record<string, unknown>;

function rows(value: unknown): Row[] {
  return Array.isArray(value)
    ? value.filter((item): item is Row => Boolean(item) && typeof item === "object")
    : [];
}

function dateOnly(date: Date) {
  return date.toISOString().slice(0, 10);
}

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const now = new Date();
  const nowIso = now.toISOString();
  const twoWeeks = new Date(now.getTime() + 14 * 24 * 60 * 60 * 1000);
  const staleProcessing = new Date(now.getTime() - 2 * 60 * 60 * 1000);

  const [
    reportsResult,
    activeActionsResult,
    forfeitsResult,
    stoppagesResult,
    fixtureResult,
    soloResult,
    fixtureAssignmentsResult,
    soloAssignmentsResult,
    fixtureReservesResult,
    soloReservesResult,
    fixtureBroadcastResult,
    soloBroadcastResult,
    paymentReconciliationResult,
    paymentRefundsResult,
    resolutionCasesResult,
    auditResult,
    liveFixtureCount,
    liveSoloCount,
  ] = await Promise.all([
    context.db
      .from("moderation_reports")
      .select("id,priority,category,details,subject_type,created_at,status", {
        count: "exact",
      })
      .in("status", OPEN_REPORT_STATUSES)
      .order("created_at", { ascending: false })
      .limit(100),
    context.db
      .from("moderation_actions")
      .select("id", { count: "exact", head: true })
      .in("action_type", ["SUSPENSION", "BAN"])
      .is("revoked_at", null)
      .lte("starts_at", nowIso)
      .or(`ends_at.is.null,ends_at.gt.${nowIso}`),
    context.db
      .from("match_forfeit_decisions")
      .select(
        "id,fixture_id,stoppage_id,source_report_id,stoppage_report_id,reported_clan_id,awarded_clan_id,provisional_home_score,provisional_away_score,created_by,created_at",
      )
      .eq("state", "PENDING_REVIEW")
      .order("created_at", { ascending: false })
      .limit(30),
    context.db
      .from("match_stoppages")
      .select("id,match_kind,fixture_id,open_queue_game_id,mode,reason_code,note,created_at")
      .eq("state", "PENDING_REVIEW")
      .order("created_at", { ascending: false })
      .limit(30),
    context.db
      .from("fixtures")
      .select("id,match_date,time_slot,venue,status")
      .in("status", ["OPEN", "SCHEDULED"])
      .gte("match_date", dateOnly(now))
      .lte("match_date", dateOnly(twoWeeks)),
    context.db
      .from("open_queue_games")
      .select("id,starts_at,venue,status")
      .in("status", ["OPEN", "FULL"])
      .gte("starts_at", nowIso)
      .lte("starts_at", twoWeeks.toISOString()),
    context.db.from("fixture_referee_assignments").select("fixture_id"),
    context.db.from("open_queue_referee_assignments").select("game_id"),
    context.db.from("match_reserve_assignments").select("fixture_id")
      .eq("status", "ACTIVE").not("fixture_id", "is", null),
    context.db.from("match_reserve_assignments").select("open_queue_game_id")
      .eq("status", "ACTIVE").not("open_queue_game_id", "is", null),
    context.db
      .from("fixture_broadcasts")
      .select("fixture_id,status,error_message,updated_at")
      .in("status", ["ERROR", "PROCESSING"]),
    context.db
      .from("open_queue_broadcasts")
      .select("game_id,status,error_message,updated_at")
      .in("status", ["ERROR", "PROCESSING"]),
    context.db
      .from("payment_intents")
      .select(
        "id,purpose,amount_fils,currency,provider,provider_intent_id,provider_payment_id,payment_method,failure_reason,created_at,external_refund_review_required,external_payment_refunds(provider_refund_id,amount_minor,currency,provider_status)",
      )
      .or("status.eq.REQUIRES_REFUND,external_refund_review_required.eq.true")
      .order("external_refund_review_required", { ascending: false })
      .order("created_at", { ascending: true })
      .limit(100),
    context.db
      .from("payment_refunds")
      .select("id,intent_id,amount_fils,currency,status,last_error,provider_refund_id,provider_status,created_at,updated_at,payment_intent:payment_intents(external_refund_review_required)")
      .or(`status.eq.FAILED,and(status.in.(PENDING,PROCESSING),updated_at.lt.${staleProcessing.toISOString()})`)
      .order("updated_at", { ascending: true })
      .limit(100),
    context.db
      .from("match_resolution_cases")
      .select(
        "id,match_kind,fixture_id,open_queue_game_id,state,reason_code,scheduled_end_at,detected_at,high_priority_at,current_revision",
      )
      .in("state", ["NO_DATA", "UNDER_REVIEW"])
      .order("high_priority_at", { ascending: true })
      .limit(100),
    context.db
      .from("admin_audit_events")
      .select("id,actor_referee_id,action,entity_type,entity_id,reason,created_at")
      .order("created_at", { ascending: false })
      .limit(30),
    context.db.from("fixtures").select("id", { count: "exact", head: true }).eq("status", "LIVE"),
    context.db.from("open_queue_games").select("id", { count: "exact", head: true }).eq("status", "LIVE"),
  ]);

  const firstError = [
    reportsResult,
    activeActionsResult,
    forfeitsResult,
    stoppagesResult,
    fixtureResult,
    soloResult,
    fixtureAssignmentsResult,
    soloAssignmentsResult,
    fixtureReservesResult,
    soloReservesResult,
    fixtureBroadcastResult,
    soloBroadcastResult,
    paymentReconciliationResult,
    paymentRefundsResult,
    resolutionCasesResult,
    auditResult,
    liveFixtureCount,
    liveSoloCount,
  ].find((result) => result.error)?.error;
  if (firstError) {
    return NextResponse.json(
      { error: `Could not load admin overview: ${firstError.message}` },
      { status: 500 },
    );
  }

  const reports = rows(reportsResult.data);
  const forfeits = rows(forfeitsResult.data);
  const stoppages = rows(stoppagesResult.data);
  const linkedForfeitStoppageIds = new Set(
    forfeits.map((forfeit) => String(forfeit.stoppage_id)),
  );
  const standaloneStoppages = stoppages.filter(
    (stoppage) => !linkedForfeitStoppageIds.has(String(stoppage.id)),
  );
  const assignedFixtures = new Set(
    rows(fixtureAssignmentsResult.data).map((row) => String(row.fixture_id)),
  );
  const assignedSolo = new Set(
    rows(soloAssignmentsResult.data).map((row) => String(row.game_id)),
  );
  const reservedFixtures = new Set(
    rows(fixtureReservesResult.data).map((row) => String(row.fixture_id)),
  );
  const reservedSolo = new Set(
    rows(soloReservesResult.data).map((row) => String(row.open_queue_game_id)),
  );
  const unassignedFixtures = rows(fixtureResult.data).filter(
    (row) => !assignedFixtures.has(String(row.id)),
  );
  const unassignedSolo = rows(soloResult.data).filter(
    (row) => !assignedSolo.has(String(row.id)),
  );
  const fixturesWithoutReserve = rows(fixtureResult.data).filter(
    (row) => !reservedFixtures.has(String(row.id)),
  );
  const soloWithoutReserve = rows(soloResult.data).filter(
    (row) => !reservedSolo.has(String(row.id)),
  );
  const broadcastCandidates: Array<Row & { matchKind: "CLAN" | "SOLO" }> = [
    ...rows(fixtureBroadcastResult.data).map(
      (row): Row & { matchKind: "CLAN" } => Object.assign({}, row, { matchKind: "CLAN" as const }),
    ),
    ...rows(soloBroadcastResult.data).map(
      (row): Row & { matchKind: "SOLO" } => Object.assign({}, row, { matchKind: "SOLO" as const }),
    ),
  ];
  const broadcastProblems = broadcastCandidates.filter((row) =>
    row.status === "ERROR" ||
    (row.status === "PROCESSING" && new Date(String(row.updated_at)).getTime() < staleProcessing.getTime()),
  );
  const paymentReconciliations = rows(paymentReconciliationResult.data);
  const paymentRefunds = rows(paymentRefundsResult.data).filter((row) =>
    refundNeedsAttention({ status: row.status, updated_at: row.updated_at }, now),
  );
  const resolutionCases = rows(resolutionCasesResult.data);

  const attention = [
    ...resolutionCases.map((resolutionCase) => {
      const matchKind = String(resolutionCase.match_kind).toUpperCase() === "SOLO"
        ? "SOLO"
        : "CLAN";
      const state = String(resolutionCase.state).toUpperCase();
      const highPriorityAt = new Date(String(resolutionCase.high_priority_at));
      const isCritical = Number.isFinite(highPriorityAt.getTime()) &&
        highPriorityAt.getTime() <= now.getTime();
      const gameId = matchKind === "CLAN"
        ? String(resolutionCase.fixture_id)
        : String(resolutionCase.open_queue_game_id);
      return {
        id: `resolution-${resolutionCase.id}`,
        kind: state === "UNDER_REVIEW"
          ? "MATCH_UNDER_REVIEW"
          : "MATCH_NO_DATA",
        severity: isCritical ? "CRITICAL" : "HIGH",
        title: state === "UNDER_REVIEW"
          ? `${matchKind === "CLAN" ? "Clan" : "Solo"} match is under review`
          : `${matchKind === "CLAN" ? "Clan" : "Solo"} match has no data`,
        detail: `${String(resolutionCase.reason_code).replaceAll("_", " ")} · scheduled end ${new Date(String(resolutionCase.scheduled_end_at)).toLocaleString("en-BH", { timeZone: "Asia/Bahrain" })}`,
        createdAt: resolutionCase.detected_at,
        matchKind,
        gameId,
        resolution: "RESOLVE_NO_DATA",
        dismissible: false,
      };
    }),
    ...paymentReconciliations.map(paymentIntentAttention),
    ...paymentRefunds.map(paymentRefundAttention),
    ...forfeits.slice(0, 12).map((forfeit) => ({
      id: String(forfeit.id),
      kind: "FORFEIT_REVIEW",
      severity: "CRITICAL",
      title: `Provisional ${forfeit.provisional_home_score}-${forfeit.provisional_away_score} forfeit`,
      detail: `Admin confirmation required · fixture ${String(forfeit.fixture_id).slice(0, 8)} · report ${String(forfeit.source_report_id).slice(0, 8)}`,
      createdAt: forfeit.created_at,
      decisionId: String(forfeit.id),
      fixtureId: String(forfeit.fixture_id),
      reportId: String(forfeit.source_report_id),
      stoppageReportId: forfeit.stoppage_report_id
        ? String(forfeit.stoppage_report_id)
        : null,
      stoppageId: String(forfeit.stoppage_id),
      reportedClanId: String(forfeit.reported_clan_id),
      awardedClanId: String(forfeit.awarded_clan_id),
      provisionalHomeScore: Number(forfeit.provisional_home_score),
      provisionalAwayScore: Number(forfeit.provisional_away_score),
      refereeId: String(forfeit.created_by),
    })),
    ...reports
      .filter((report) => ["HIGH", "URGENT"].includes(String(report.priority)))
      .slice(0, 12)
      .map((report) => ({
        id: String(report.id),
        kind: "REPORT",
        severity: report.priority === "URGENT" ? "CRITICAL" : "HIGH",
        title: `${String(report.category).replaceAll("_", " ")} report`,
        detail: String(report.details || `${report.subject_type} report needs review.`),
        createdAt: report.created_at,
      })),
    ...standaloneStoppages.slice(0, 10).map((stoppage) => ({
      id: String(stoppage.id),
      kind: "MATCH_STOPPAGE",
      severity: stoppage.mode === "ABANDON" ? "CRITICAL" : "HIGH",
      title: stoppage.mode === "ABANDON" ? "Match abandoned" : "Match stopped",
      detail: `${String(stoppage.reason_code).replaceAll("_", " ")}${stoppage.note ? ` · ${stoppage.note}` : ""}`,
      createdAt: stoppage.created_at,
    })),
    ...unassignedFixtures.map((fixture) => ({
      id: `fixture-${fixture.id}`,
      kind: "GAME_MISSING_REFEREE",
      severity: fixture.status === "LIVE" ? "CRITICAL" : "HIGH",
      title: "Clan game has no referee",
      detail: `${fixture.match_date} · ${fixture.time_slot} · ${fixture.venue}`,
      createdAt: null,
      matchKind: "CLAN",
      gameId: String(fixture.id),
      resolution: "ASSIGN_REFEREE",
      dismissible: false,
    })),
    ...unassignedSolo.map((game) => ({
      id: `solo-${game.id}`,
      kind: "GAME_MISSING_REFEREE",
      severity: game.status === "LIVE" ? "CRITICAL" : "HIGH",
      title: "Solo game has no referee",
      detail: `${new Date(String(game.starts_at)).toLocaleString("en-BH", { timeZone: "Asia/Bahrain" })} · ${game.venue}`,
      createdAt: null,
      matchKind: "SOLO",
      gameId: String(game.id),
      resolution: "ASSIGN_REFEREE",
      dismissible: false,
    })),
    ...fixturesWithoutReserve.map((fixture) => ({
      id: `fixture-reserve-${fixture.id}`,
      kind: "GAME_MISSING_RESERVE",
      severity: fixture.status === "LIVE" ? "CRITICAL" : "HIGH",
      title: "Clan game has no reserve player",
      detail: `${fixture.match_date} · ${fixture.time_slot} · ${fixture.venue}`,
      createdAt: null,
      matchKind: "CLAN",
      gameId: String(fixture.id),
      resolution: "ASSIGN_RESERVE",
      dismissible: false,
    })),
    ...soloWithoutReserve.map((game) => ({
      id: `solo-reserve-${game.id}`,
      kind: "GAME_MISSING_RESERVE",
      severity: game.status === "LIVE" ? "CRITICAL" : "HIGH",
      title: "Solo game has no reserve player",
      detail: `${new Date(String(game.starts_at)).toLocaleString("en-BH", { timeZone: "Asia/Bahrain" })} · ${game.venue}`,
      createdAt: null,
      matchKind: "SOLO",
      gameId: String(game.id),
      resolution: "ASSIGN_RESERVE",
      dismissible: false,
    })),
    ...broadcastProblems.slice(0, 8).map((broadcast) => ({
      id: `broadcast-${broadcast.matchKind}-${broadcast.fixture_id ?? broadcast.game_id}`,
      kind: "BROADCAST",
      severity: broadcast.status === "ERROR" ? "HIGH" : "MEDIUM",
      title: broadcast.status === "ERROR" ? "Replay or stream error" : "Replay processing is delayed",
      detail: String(broadcast.error_message ?? `${broadcast.matchKind} recording needs attention.`),
      createdAt: broadcast.updated_at,
    })),
  ];

  attention.sort((left, right) =>
    Number("resolution" in right && right.resolution === "PAYMENT_MANUAL_RECONCILIATION") -
    Number("resolution" in left && left.resolution === "PAYMENT_MANUAL_RECONCILIATION"),
  );

  const auditRows = rows(auditResult.data);
  const actorIds = [...new Set(auditRows.map((row) => String(row.actor_referee_id)))];
  const actorResult = actorIds.length
    ? await context.db
        .from("referee_profiles")
        .select("profile_id,display_name")
        .in("profile_id", actorIds)
    : { data: [], error: null };
  if (actorResult.error) {
    return NextResponse.json(
      { error: `Could not load audit actors: ${actorResult.error.message}` },
      { status: 500 },
    );
  }
  const actors = new Map(
    rows(actorResult.data).map((row) => [String(row.profile_id), String(row.display_name)]),
  );

  const operationalAttention = forfeits.length + standaloneStoppages.length + unassignedFixtures.length +
    unassignedSolo.length + fixturesWithoutReserve.length + soloWithoutReserve.length +
    broadcastProblems.length + paymentReconciliations.length + paymentRefunds.length + resolutionCases.length;
  return NextResponse.json({
    metrics: {
      openReports: reportsResult.count ?? reports.length,
      urgentReports: reports.filter((report) => ["HIGH", "URGENT"].includes(String(report.priority))).length,
      liveGames: (liveFixtureCount.count ?? 0) + (liveSoloCount.count ?? 0),
      activeRestrictions: activeActionsResult.count ?? 0,
      pendingStoppages: stoppages.length,
      standalonePendingStoppages: standaloneStoppages.length,
      pendingForfeits: forfeits.length,
      gamesNeedingAttention: operationalAttention,
    },
    attention,
    audit: auditRows.map((row) => ({
      id: String(row.id),
      action: String(row.action),
      actor: actors.get(String(row.actor_referee_id)) ?? "Field admin",
      target: `${String(row.entity_type).replaceAll("_", " ")} · ${String(row.entity_id).slice(0, 8)}`,
      detail: String(row.reason ?? ""),
      createdAt: row.created_at,
    })),
  });
}
