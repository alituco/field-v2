import type { SupabaseClient } from "@supabase/supabase-js";

type Row = Record<string, unknown>;

function rows(value: unknown): Row[] {
  return Array.isArray(value)
    ? value.filter((item): item is Row => Boolean(item) && typeof item === "object")
    : [];
}

function nullableString(value: unknown): string | null {
  return value == null ? null : String(value);
}

export const FORFEIT_REVIEW_STATES = [
  "PENDING_REVIEW",
  "CONFIRMED",
  "OVERTURNED",
] as const;

export type ForfeitReviewState = (typeof FORFEIT_REVIEW_STATES)[number];

export async function loadAdminForfeits(
  db: SupabaseClient,
  state?: ForfeitReviewState | null,
) {
  let decisionQuery = db
    .from("match_forfeit_decisions")
    .select("*")
    .order("created_at", { ascending: false })
    .limit(250);
  if (state) decisionQuery = decisionQuery.eq("state", state);

  const { data, error } = await decisionQuery;
  if (error) throw new Error(`Could not load forfeit reviews: ${error.message}`);
  const decisions = rows(data);
  if (decisions.length === 0) return [];

  const fixtureIds = [...new Set(decisions.map((row) => String(row.fixture_id)))];
  const reportIds = [...new Set(decisions.map((row) => String(row.source_report_id)))];
  const stoppageIds = [...new Set(decisions.map((row) => String(row.stoppage_id)))];
  const refereeIds = [...new Set(decisions.flatMap((row) => [
    String(row.created_by),
    nullableString(row.reviewed_by),
  ]).filter((id): id is string => Boolean(id)))];
  const clanIds = [...new Set(decisions.flatMap((row) => [
    String(row.reported_clan_id),
    String(row.awarded_clan_id),
  ]))];

  const [fixtureResult, reportResult, stoppageResult, refereeResult, clanResult] =
    await Promise.all([
      db
        .from("fixtures")
        .select(
          "id,status,match_date,time_slot,venue,home_clan_id,away_clan_id,home_score,away_score,cancellation_context",
        )
        .in("id", fixtureIds),
      db
        .from("moderation_reports")
        .select("id,status,priority,category,details,replay_offset_seconds")
        .in("id", reportIds),
      db
        .from("match_stoppages")
        .select("id,state,mode,reason_code,note,elapsed_seconds")
        .in("id", stoppageIds),
      db
        .from("referee_profiles")
        .select("profile_id,display_name,role")
        .in("profile_id", refereeIds),
      db
        .from("clans")
        .select("id,name,tag,emblem")
        .in("id", clanIds),
    ]);

  const firstError = [
    fixtureResult,
    reportResult,
    stoppageResult,
    refereeResult,
    clanResult,
  ].find((result) => result.error)?.error;
  if (firstError) {
    throw new Error(`Could not hydrate forfeit reviews: ${firstError.message}`);
  }

  const fixtures = new Map(rows(fixtureResult.data).map((row) => [String(row.id), row]));
  const reports = new Map(rows(reportResult.data).map((row) => [String(row.id), row]));
  const stoppages = new Map(rows(stoppageResult.data).map((row) => [String(row.id), row]));
  const referees = new Map(
    rows(refereeResult.data).map((row) => [String(row.profile_id), row]),
  );
  const clans = new Map(rows(clanResult.data).map((row) => [String(row.id), row]));

  return decisions.map((decision) => {
    const fixture = fixtures.get(String(decision.fixture_id));
    const report = reports.get(String(decision.source_report_id));
    const stoppage = stoppages.get(String(decision.stoppage_id));
    const reportedClan = clans.get(String(decision.reported_clan_id));
    const awardedClan = clans.get(String(decision.awarded_clan_id));
    const referee = referees.get(String(decision.created_by));
    const reviewer = decision.reviewed_by
      ? referees.get(String(decision.reviewed_by))
      : undefined;

    return {
      id: String(decision.id),
      status: String(decision.state),
      fixtureId: String(decision.fixture_id),
      fixtureStatus: String(fixture?.status ?? "CANCELLED"),
      matchDate: nullableString(fixture?.match_date),
      timeSlot: nullableString(fixture?.time_slot),
      venue: nullableString(fixture?.venue),
      homeClanId: nullableString(fixture?.home_clan_id),
      awayClanId: nullableString(fixture?.away_clan_id),
      reportedClan: {
        id: String(decision.reported_clan_id),
        name: String(reportedClan?.name ?? "Unknown clan"),
        tag: nullableString(reportedClan?.tag),
        emblem: nullableString(reportedClan?.emblem),
      },
      awardedClan: {
        id: String(decision.awarded_clan_id),
        name: String(awardedClan?.name ?? "Unknown clan"),
        tag: nullableString(awardedClan?.tag),
        emblem: nullableString(awardedClan?.emblem),
      },
      provisionalHomeScore: Number(decision.provisional_home_score),
      provisionalAwayScore: Number(decision.provisional_away_score),
      previousHomeScore: decision.previous_home_score == null
        ? null
        : Number(decision.previous_home_score),
      previousAwayScore: decision.previous_away_score == null
        ? null
        : Number(decision.previous_away_score),
      reportId: String(decision.source_report_id),
      stoppageReportId: nullableString(decision.stoppage_report_id),
      reportStatus: nullableString(report?.status),
      reportCategory: nullableString(report?.category),
      reportPriority: nullableString(report?.priority),
      reportDetails: nullableString(report?.details),
      replayOffsetSeconds: report?.replay_offset_seconds == null
        ? null
        : Number(report.replay_offset_seconds),
      stoppageId: String(decision.stoppage_id),
      stoppageStatus: nullableString(stoppage?.state),
      reasonCode: nullableString(stoppage?.reason_code),
      reason: nullableString(stoppage?.note),
      elapsedSeconds: Number(stoppage?.elapsed_seconds ?? 0),
      referee: {
        id: String(decision.created_by),
        name: String(referee?.display_name ?? "Assigned referee"),
        role: String(referee?.role ?? "referee"),
      },
      reviewer: reviewer
        ? {
            id: String(decision.reviewed_by),
            name: String(reviewer.display_name ?? "Field admin"),
          }
        : null,
      reviewNote: nullableString(decision.review_note),
      reviewedAt: nullableString(decision.reviewed_at),
      createdAt: nullableString(decision.created_at),
      ratingPolicy: decision.state === "PENDING_REVIEW"
        ? "DEFER_UNTIL_ADMIN_CONFIRMATION"
        : decision.state === "CONFIRMED"
          ? "NORMAL_FINALIZATION_ON_CONFIRMATION"
          : "NO_RATING_CHANGE",
    };
  });
}
