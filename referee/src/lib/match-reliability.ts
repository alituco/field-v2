import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  MatchKind,
  MatchReliabilityContext,
  ReliabilityAttendancePlayer,
  ReliabilityReplacementStep,
  ReliabilityShorthandedPeriod,
  ReliabilityVerifiedInjury,
} from "./types";

/**
 * Attendance timing is intentionally read from a server-authored RPC. Do not
 * derive check-in eligibility or attendance outcomes from the browser clock.
 */
export async function loadMatchReliabilityContext(
  db: SupabaseClient,
  matchKind: MatchKind,
  matchId: string,
): Promise<MatchReliabilityContext | null> {
  const { data, error } = await db.rpc("get_match_reliability_context", {
    match_kind_to_use: matchKind,
    match_id_to_use: matchId,
  });
  if (error) {
    console.error(
      `Could not load ${matchKind.toLowerCase()} attendance context for ${matchId}:`,
      error.message,
    );
    return null;
  }
  const context = normalizeMatchReliabilityContext(data);
  if (!context) return null;

  const matchColumn = matchKind === "SOLO"
    ? "open_queue_game_id"
    : "fixture_id";
  const [injuriesResult, periodsResult] = await Promise.all([
    db
      .from("match_verified_injuries")
      .select(
        "id,profile_id,side,match_second,unable_to_continue,replacement_available,match_continued,note",
      )
      .eq(matchColumn, matchId)
      .order("match_second"),
    db
      .from("match_shorthanded_periods")
      .select(
        "id,side,reason,caused_by_profile_id,replacement_profile_id,started_match_second,ended_match_second,note",
      )
      .eq(matchColumn, matchId)
      .is("ended_match_second", null)
      .order("started_match_second"),
  ]);

  if (injuriesResult.error) {
    console.error(
      `Could not load ${matchKind.toLowerCase()} verified injuries for ${matchId}:`,
      injuriesResult.error.message,
    );
  }
  if (periodsResult.error) {
    console.error(
      `Could not load ${matchKind.toLowerCase()} shorthanded periods for ${matchId}:`,
      periodsResult.error.message,
    );
  }

  return {
    ...context,
    verifiedInjuries: (injuriesResult.data ?? [])
      .map(normalizeVerifiedInjury)
      .filter((row): row is ReliabilityVerifiedInjury => row !== null),
    openShorthandedPeriods: (periodsResult.data ?? [])
      .map(normalizeShorthandedPeriod)
      .filter((row): row is ReliabilityShorthandedPeriod => row !== null),
  };
}

export function normalizeMatchReliabilityContext(
  raw: unknown,
): MatchReliabilityContext | null {
  const root = unwrapObject(raw);
  if (!root) return null;

  const playerRows = arrayValue(
    root.players ?? root.attendance ?? root.expected_players ?? root.roster,
  );
  const players = playerRows
    .map(normalizeAttendancePlayer)
    .filter((player): player is ReliabilityAttendancePlayer => player !== null);
  const expectedCount = integerValue(
    root.expected_count ?? root.expected_player_count,
    players.length,
  );
  const checkedInCount = integerValue(
    root.checked_in_count,
    players.filter((player) => player.isCheckedIn).length,
  );
  const onTimeCount = integerValue(
    root.on_time_count,
    players.filter((player) => player.status === "ON_TIME").length,
  );
  const lateCount = integerValue(
    root.late_count,
    players.filter((player) => player.status === "LATE").length,
  );
  const missingCount = integerValue(
    root.missing_count,
    players.filter((player) => player.status === "MISSING").length,
  );

  return {
    serverNow: nullableString(root.server_now),
    policyVersionId: nullableString(root.policy_version_id),
    kickoffAt: nullableString(root.kickoff_at),
    checkInDeadlineAt: nullableString(
      root.check_in_deadline_at ?? root.checkin_deadline_at,
    ),
    noShowCutoffAt: nullableString(root.no_show_cutoff_at),
    reserveActivationMinutesAfterKickoff: integerValue(
      root.reserve_activation_minutes_after_kickoff,
    ),
    reserveActivationAt: nullableString(root.reserve_activation_at),
    originalPlayerReclaimUntilMinutesAfterKickoff: integerValue(
      root.original_player_reclaim_until_minutes_after_kickoff,
    ),
    originalPlayerReclaimUntilAt: nullableString(
      root.original_player_reclaim_until_at,
    ),
    replacementOrder: replacementOrder(root.replacement_order),
    reservePlanAutomated: booleanValue(root.reserve_plan_automated),
    reservePlanAuthority: nullableString(root.reserve_plan_authority) === "FIELD_HOST"
      ? "FIELD_HOST"
      : null,
    canCheckIn: booleanValue(root.can_check_in),
    canFinalizeAttendance: booleanValue(
      root.can_finalize_attendance ?? root.can_finalize,
    ),
    attendanceFinalized: booleanValue(
      root.attendance_finalized ?? root.is_finalized,
    ),
    expectedCount,
    checkedInCount,
    onTimeCount,
    lateCount,
    missingCount,
    players,
    verifiedInjuries: arrayValue(root.verified_injuries)
      .map(normalizeVerifiedInjury)
      .filter((row): row is ReliabilityVerifiedInjury => row !== null),
    openShorthandedPeriods: arrayValue(
      root.open_shorthanded_periods ?? root.shorthanded_periods,
    )
      .map(normalizeShorthandedPeriod)
      .filter((row): row is ReliabilityShorthandedPeriod => row !== null),
  };
}

function normalizeAttendancePlayer(
  raw: unknown,
): ReliabilityAttendancePlayer | null {
  const row = unwrapObject(raw);
  if (!row) return null;
  const profile = unwrapObject(row.profile);
  const profileId = stringValue(
    row.profile_id ?? row.player_id ?? profile?.id,
  );
  if (!profileId) return null;

  const outcome = nullableString(
    row.attendance_outcome ?? row.outcome,
  )?.toUpperCase() ?? null;
  const checkedInAt = nullableString(row.checked_in_at ?? row.check_in_at);
  const rawStatus = nullableString(row.status)?.toUpperCase();
  const status = attendanceStatus(rawStatus, outcome, checkedInAt);

  return {
    attendanceRecordId: nullableString(
      row.attendance_record_id ?? row.record_id ?? row.id,
    ),
    profileId,
    displayName:
      nullableString(
        row.display_name ?? row.player_name ?? profile?.display_name,
      ) ?? "Unnamed player",
    expectedForMatch: booleanValue(row.expected_for_match, true),
    checkInEligible: booleanValue(row.check_in_eligible, true),
    teamId: nullableString(row.team_id ?? row.clan_id ?? row.team),
    teamName: nullableString(row.team_name ?? row.clan_name ?? row.side),
    side: reliabilitySide(row.side),
    role: nullableString(row.role ?? row.position),
    checkedInAt,
    outcome,
    status,
    isCheckedIn: booleanValue(
      row.is_checked_in,
      checkedInAt !== null || status === "ON_TIME" || status === "LATE",
    ),
    checkInRevision: integerValue(row.check_in_revision),
    canRemoveCheckIn: booleanValue(row.can_remove_check_in),
  };
}

function normalizeVerifiedInjury(
  raw: unknown,
): ReliabilityVerifiedInjury | null {
  const row = unwrapObject(raw);
  if (!row) return null;
  const id = stringValue(row.id ?? row.injury_id);
  const profileId = stringValue(row.profile_id);
  const side = reliabilitySide(row.side);
  if (!id || !profileId || !side) return null;
  return {
    id,
    profileId,
    side,
    matchSecond: integerValue(row.match_second),
    unableToContinue: booleanValue(row.unable_to_continue),
    replacementAvailable: booleanValue(row.replacement_available),
    matchContinued: booleanValue(row.match_continued),
    note: nullableString(row.note),
  };
}

function normalizeShorthandedPeriod(
  raw: unknown,
): ReliabilityShorthandedPeriod | null {
  const row = unwrapObject(raw);
  if (!row) return null;
  const id = stringValue(row.id ?? row.period_id);
  const side = reliabilitySide(row.side);
  const reason = nullableString(row.reason)?.toUpperCase();
  if (
    !id ||
    !side ||
    !["LATE_ARRIVAL", "NO_SHOW", "INJURY", "OTHER"].includes(reason ?? "")
  ) return null;
  return {
    id,
    side,
    reason: reason as ReliabilityShorthandedPeriod["reason"],
    causedByProfileId: nullableString(row.caused_by_profile_id),
    replacementProfileId: nullableString(row.replacement_profile_id),
    startedMatchSecond: integerValue(row.started_match_second),
    endedMatchSecond: row.ended_match_second == null
      ? null
      : integerValue(row.ended_match_second),
    note: nullableString(row.note),
  };
}

function reliabilitySide(
  value: unknown,
): ReliabilityAttendancePlayer["side"] {
  const normalized = nullableString(value)?.toUpperCase();
  return ["HOME", "AWAY", "WHITE", "BLACK"].includes(normalized ?? "")
    ? normalized as ReliabilityAttendancePlayer["side"]
    : null;
}

function attendanceStatus(
  rawStatus: string | null | undefined,
  outcome: string | null,
  checkedInAt: string | null,
): ReliabilityAttendancePlayer["status"] {
  if (["ON_TIME", "LATE", "NO_SHOW", "EXCUSED", "MISSING"].includes(
    rawStatus ?? "",
  )) {
    return rawStatus as ReliabilityAttendancePlayer["status"];
  }
  if (outcome === "ON_TIME") return "ON_TIME";
  if (outcome === "LATE") return "LATE";
  if (outcome === "NO_SHOW") return "NO_SHOW";
  if (outcome === "EXCUSED" || outcome === "FIELD_CANCELLED") return "EXCUSED";
  if (checkedInAt) return "CHECKED_IN";
  return "MISSING";
}

function unwrapObject(value: unknown): Record<string, unknown> | null {
  if (Array.isArray(value)) {
    return value.length > 0 ? unwrapObject(value[0]) : null;
  }
  if (!value || typeof value !== "object") return null;
  return value as Record<string, unknown>;
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function nullableString(value: unknown): string | null {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized ? normalized : null;
}

function stringValue(value: unknown): string {
  return nullableString(value) ?? "";
}

function integerValue(value: unknown, fallback = 0): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(0, Math.round(parsed)) : fallback;
}

function booleanValue(value: unknown, fallback = false): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    if (value.toLowerCase() === "true") return true;
    if (value.toLowerCase() === "false") return false;
  }
  return fallback;
}

function replacementOrder(value: unknown): ReliabilityReplacementStep[] {
  const allowed: ReliabilityReplacementStep[] = [
    "EMERGENCY_NOTIFICATION",
    "ON_FIELD_RESERVE",
    "PLAY_SHORTHANDED",
  ];
  return arrayValue(value)
    .map((item) => nullableString(item)?.toUpperCase())
    .filter((item): item is ReliabilityReplacementStep =>
      Boolean(item) && allowed.includes(item as ReliabilityReplacementStep));
}
