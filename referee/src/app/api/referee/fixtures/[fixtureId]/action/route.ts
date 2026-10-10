import { NextRequest, NextResponse } from "next/server";
import type { SupabaseClient } from "@supabase/supabase-js";

import { queueBroadcastStop } from "@/lib/broadcasts";
import { assertCanManageFixture } from "@/lib/fixture-access";
import {
  parseAdminCancellationInput,
  parseAdminScoreOverrideInput,
  parseMatchStoppageInput,
  parseRefereeBulkCheckInInput,
  parseRefereeCheckInInput,
  parseRefereeRemoveCheckInInput,
  parseRefereeClanForfeitInput,
  parseRefereeEndShorthandedInput,
  parseRefereeReportInput,
  parseRefereeStartShorthandedInput,
  parseRefereeVerifiedInjuryInput,
} from "@/lib/match-action-input";
import { canRefereePerformOperationalAction } from "@/lib/match-operational-lock";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";

type RouteContext = {
  params: Promise<{ fixtureId: string }>;
};

type ActionBody = {
  action:
    | "start"
    | "pause"
    | "resume"
    | "set_time"
    | "goal"
    | "blue_card"
    | "expire_blue_card"
    | "finish"
    | "report"
    | "check_in_player"
    | "remove_check_in"
    | "check_in_players"
    | "finalize_attendance"
    | "record_verified_injury"
    | "start_shorthanded"
    | "end_shorthanded"
    | "forfeit"
    | "stop"
    | "cancel"
    | "override_score";
  durationSeconds?: number;
  clanId?: string;
  profileId?: string;
  checkInTiming?: string;
  assistProfileId?: string | null;
  blueCardId?: string;
  elapsedSeconds?: number;
  participantIds?: string[];
  profileIds?: string[];
  subjectType?: string;
  subjectId?: string;
  reportedClanId?: string;
  category?: string;
  details?: string;
  priority?: string;
  replayOffsetSeconds?: number;
  mode?: string;
  reasonCode?: string;
  reason?: string;
  note?: string;
  homeScore?: number;
  awayScore?: number;
  unableToContinue?: boolean;
  replacementAvailable?: boolean;
  matchContinued?: boolean;
  side?: string;
  causedByProfileId?: string | null;
  periodId?: string;
  replacementProfileId?: string | null;
} & Record<string, unknown>;

type FixtureRow = {
  id: string;
  status: string;
  home_clan_id: string;
  away_clan_id: string | null;
};

type ClockRow = {
  status: string;
  started_at: string | null;
  accumulated_seconds: number;
  duration_seconds: number;
};

const MAX_MATCH_SECONDS = 3 * 60 * 60;

export async function POST(request: NextRequest, context: RouteContext) {
  const requestReceivedAt = new Date().toISOString();
  const refereeContext = await requireReferee(request);
  if (!isRefereeContext(refereeContext)) return refereeContext;

  const { fixtureId } = await context.params;
  const db = refereeContext.db;

  try {
    await assertCanManageFixture(
      db,
      fixtureId,
      refereeContext.referee.profileId,
      refereeContext.referee.role,
    );

    const body = (await request.json()) as ActionBody;
    const { data: operationalFixture, error: operationalError } = await db
      .from("fixtures")
      .select("operational_state")
      .eq("id", fixtureId)
      .single();
    if (operationalError) {
      throw new Error(
        `Could not verify the match review state: ${operationalError.message}`,
      );
    }
    if (
      !canRefereePerformOperationalAction(
        operationalFixture.operational_state,
        body.action,
      )
    ) {
      return NextResponse.json(
        {
          error:
            "This match is locked for admin review. You can still submit a report, but attendance, clock, score, and result changes are paused.",
        },
        { status: 409 },
      );
    }

    let result: Record<string, unknown> = {};

    switch (body.action) {
      case "start":
        await startFixture(
          db,
          fixtureId,
          body.durationSeconds,
          body.participantIds,
        );
        break;
      case "pause":
        await pauseFixture(db, fixtureId);
        break;
      case "resume":
        await resumeFixture(db, fixtureId);
        break;
      case "set_time":
        await setFixtureTime(db, fixtureId, body.elapsedSeconds);
        break;
      case "goal":
        await recordGoal(db, fixtureId, body, requestReceivedAt);
        break;
      case "blue_card":
        await recordBlueCard(db, fixtureId, body);
        break;
      case "expire_blue_card":
        await expireBlueCard(db, fixtureId, body.blueCardId);
        break;
      case "finish":
        await finishFixture(db, fixtureId);
        try {
          await queueBroadcastStop(
            db,
            fixtureId,
            refereeContext.referee.profileId,
            30,
          );
        } catch (broadcastError) {
          console.error("Could not queue automatic broadcast stop", broadcastError);
        }
        break;
      case "report": {
        const report = parseRefereeReportInput(body, "CLAN", fixtureId);
        const { data, error } = await db.rpc("submit_referee_moderation_report", {
          reporter_referee_id_to_use: refereeContext.referee.profileId,
          subject_type_to_use: report.subjectType,
          subject_id_to_use: report.subjectId,
          category_to_use: report.category,
          details_to_use: report.details,
          priority_to_use: report.priority,
          fixture_id_to_use: fixtureId,
          open_queue_game_id_to_use: null,
          replay_offset_seconds_to_use: report.replayOffsetSeconds,
        });
        if (error) throw new Error(`Could not submit report: ${error.message}`);
        result = { reportId: String(data) };
        break;
      }
      case "check_in_player": {
        const checkIn = parseRefereeCheckInInput(body);
        const { data, error } = await db.rpc("referee_check_in_player_with_timing", {
          actor_referee_id: refereeContext.referee.profileId,
          match_kind_to_use: "CLAN",
          match_id_to_use: fixtureId,
          profile_id_to_check_in: checkIn.profileId,
          check_in_timing_to_use: checkIn.timing,
        });
        if (error) throw new Error(`Could not check in player: ${error.message}`);
        result = { reliabilityContext: data };
        break;
      }
      case "remove_check_in": {
        const correction = parseRefereeRemoveCheckInInput(body);
        const { data, error } = await db.rpc(
          "referee_remove_player_check_in",
          {
            actor_referee_id: refereeContext.referee.profileId,
            match_kind_to_use: "CLAN",
            match_id_to_use: fixtureId,
            profile_id_to_remove: correction.profileId,
            expected_revision_to_use: correction.expectedRevision,
            reason_code_to_use: correction.reasonCode,
            reason_note_to_use: correction.note || null,
          },
        );
        if (error) {
          throw new Error(`Could not remove check-in: ${error.message}`);
        }
        result = { reliabilityContext: data };
        break;
      }
      case "check_in_players": {
        const checkIn = parseRefereeBulkCheckInInput(body);
        let reliabilityContext: unknown = null;
        for (const profileId of checkIn.profileIds) {
          const { data, error } = await db.rpc("referee_check_in_player_with_timing", {
            actor_referee_id: refereeContext.referee.profileId,
            match_kind_to_use: "CLAN",
            match_id_to_use: fixtureId,
            profile_id_to_check_in: profileId,
            check_in_timing_to_use: "EARLY",
          });
          if (error) {
            throw new Error(`Could not check in all players: ${error.message}`);
          }
          reliabilityContext = data;
        }
        result = { reliabilityContext };
        break;
      }
      case "finalize_attendance": {
        const { data, error } = await db.rpc(
          "referee_finalize_match_attendance",
          {
            actor_referee_id: refereeContext.referee.profileId,
            match_kind_to_use: "CLAN",
            match_id_to_use: fixtureId,
          },
        );
        if (error) {
          throw new Error(`Could not finalize attendance: ${error.message}`);
        }
        result = { reliabilityContext: data };
        break;
      }
      case "record_verified_injury": {
        const injury = parseRefereeVerifiedInjuryInput(body);
        const { data, error } = await db.rpc(
          "referee_record_verified_injury",
          {
            actor_referee_id: refereeContext.referee.profileId,
            match_kind_to_use: "CLAN",
            match_id_to_use: fixtureId,
            injured_profile_id_to_use: injury.profileId,
            unable_to_continue_to_use: injury.unableToContinue,
            replacement_available_to_use: injury.replacementAvailable,
            match_continued_to_use: injury.matchContinued,
            note_to_use: injury.note || null,
          },
        );
        if (error) {
          throw new Error(`Could not record verified injury: ${error.message}`);
        }
        result = { evidence: data };
        break;
      }
      case "start_shorthanded": {
        const period = parseRefereeStartShorthandedInput(body, "CLAN");
        const { data, error } = await db.rpc(
          "referee_start_shorthanded_period",
          {
            actor_referee_id: refereeContext.referee.profileId,
            match_kind_to_use: "CLAN",
            match_id_to_use: fixtureId,
            side_to_use: period.side,
            reason_to_use: period.reason,
            caused_by_profile_id_to_use: period.causedByProfileId,
            note_to_use: period.note || null,
          },
        );
        if (error) {
          throw new Error(`Could not start shorthanded period: ${error.message}`);
        }
        result = { periodId: String(data) };
        break;
      }
      case "end_shorthanded": {
        const period = parseRefereeEndShorthandedInput(body);
        const { data, error } = await db.rpc(
          "referee_end_shorthanded_period",
          {
            actor_referee_id: refereeContext.referee.profileId,
            period_id_to_end: period.periodId,
            replacement_profile_id_to_use: period.replacementProfileId,
            note_to_use: period.note || null,
          },
        );
        if (error) {
          throw new Error(`Could not end shorthanded period: ${error.message}`);
        }
        result = { evidence: data };
        break;
      }
      case "forfeit": {
        const forfeit = parseRefereeClanForfeitInput(body);
        const { data, error } = await db.rpc("referee_report_clan_forfeit", {
          actor_referee_id: refereeContext.referee.profileId,
          fixture_id_to_stop: fixtureId,
          reported_clan_id_to_use: forfeit.reportedClanId,
          category_to_use: forfeit.category,
          details_to_use: forfeit.details,
          reason_code_to_use: forfeit.reasonCode,
          note_to_use: forfeit.note || null,
          replay_offset_seconds_to_use: forfeit.replayOffsetSeconds,
        });
        if (error) {
          throw new Error(`Could not award provisional forfeit: ${error.message}`);
        }
        result = data && typeof data === "object"
          ? data as Record<string, unknown>
          : { decisionId: String(data), status: "PENDING_REVIEW" };

        try {
          await queueBroadcastStop(
            db,
            fixtureId,
            refereeContext.referee.profileId,
          );
        } catch (broadcastError) {
          console.error("Could not stop forfeited match broadcast", broadcastError);
        }
        break;
      }
      case "stop": {
        const stoppage = parseMatchStoppageInput(body);
        const { data, error } = await db.rpc("referee_record_match_stoppage", {
          actor_referee_id: refereeContext.referee.profileId,
          match_kind_to_use: "CLAN",
          match_id_to_stop: fixtureId,
          mode_to_use: stoppage.mode,
          reason_code_to_use: stoppage.reasonCode,
          note_to_use: stoppage.note || null,
        });
        if (error) throw new Error(`Could not stop match: ${error.message}`);
        result = { stoppageId: String(data), mode: stoppage.mode };

        if (stoppage.mode === "ABANDON") {
          try {
            await queueBroadcastStop(
              db,
              fixtureId,
              refereeContext.referee.profileId,
            );
          } catch (broadcastError) {
            console.error("Could not stop abandoned match broadcast", broadcastError);
          }
        }
        break;
      }
      case "cancel": {
        if (refereeContext.referee.role !== "admin") {
          return NextResponse.json(
            { error: "Admin referee access required." },
            { status: 403 },
          );
        }
        const cancellation = parseAdminCancellationInput(body);
        const { error } = await db.rpc("admin_cancel_match", {
          actor_admin_id: refereeContext.referee.profileId,
          match_kind_to_use: "CLAN",
          match_id_to_cancel: fixtureId,
          reason_code_to_use: cancellation.reasonCode,
          reason_to_use: cancellation.reason,
        });
        if (error) throw new Error(`Could not cancel match: ${error.message}`);
        try {
          await queueBroadcastStop(
            db,
            fixtureId,
            refereeContext.referee.profileId,
          );
        } catch (broadcastError) {
          console.error("Could not stop cancelled match broadcast", broadcastError);
        }
        break;
      }
      case "override_score": {
        if (refereeContext.referee.role !== "admin") {
          return NextResponse.json(
            { error: "Admin referee access required." },
            { status: 403 },
          );
        }
        const score = parseAdminScoreOverrideInput(body);
        const { data, error } = await db.rpc("admin_override_match_score", {
          actor_admin_id: refereeContext.referee.profileId,
          match_kind_to_use: "CLAN",
          match_id_to_update: fixtureId,
          home_score_to_use: score.homeScore,
          away_score_to_use: score.awayScore,
          reason_to_use: score.reason,
        });
        if (error) throw new Error(`Could not correct score: ${error.message}`);
        result = { revisionId: String(data) };
        break;
      }
      default:
        return NextResponse.json({ error: "Unknown action." }, { status: 400 });
    }

    return NextResponse.json({ ok: true, ...result });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Action failed." },
      { status: 400 },
    );
  }
}

async function startFixture(
  db: SupabaseClient,
  fixtureId: string,
  durationSeconds = 3600,
  participantIds: string[] | undefined = undefined,
) {
  if (!Array.isArray(participantIds)) {
    throw new Error("Confirm the players taking part before starting.");
  }
  const selectedIds = [...new Set(participantIds.map((id) => String(id).trim()))]
    .filter(Boolean);
  if (selectedIds.length === 0) {
    throw new Error("Select at least one player from each team.");
  }
  const safeDuration = clamp(Math.round(durationSeconds), 600, 7200);

  await assertNoError(
    db.rpc("referee_start_fixture_atomic", {
      fixture_id_to_start: fixtureId,
      participant_ids_to_use: selectedIds,
      duration_seconds_to_use: safeDuration,
    }),
    "Could not start fixture",
  );
}

async function pauseFixture(db: SupabaseClient, fixtureId: string) {
  await loadFixture(db, fixtureId);
  const clock = await loadClock(db, fixtureId);
  const elapsedSeconds = Math.min(elapsedFromClock(clock), MAX_MATCH_SECONDS);
  const { minute, second } = splitElapsed(elapsedSeconds);

  await assertNoError(
    db
      .from("fixture_clock_states")
      .update({
        status: "PAUSED",
        started_at: null,
        accumulated_seconds: elapsedSeconds,
      })
      .eq("fixture_id", fixtureId),
    "Could not pause fixture clock",
  );
  await insertEvent(db, fixtureId, "MATCH_PAUSED", minute, second);
}

async function resumeFixture(db: SupabaseClient, fixtureId: string) {
  await loadFixture(db, fixtureId);
  const clock = await loadClock(db, fixtureId);
  const { minute, second } = splitElapsed(elapsedFromClock(clock));

  await assertNoError(
    db
      .from("fixture_clock_states")
      .update({
        status: "RUNNING",
        started_at: new Date().toISOString(),
      })
      .eq("fixture_id", fixtureId),
    "Could not resume fixture clock",
  );
  await insertEvent(db, fixtureId, "MATCH_RESUMED", minute, second);
}

async function recordGoal(
  db: SupabaseClient,
  fixtureId: string,
  body: ActionBody,
  occurredAt: string,
) {
  const fixture = await loadLiveFixture(db, fixtureId);
  const clanId = requireString(body.clanId, "Choose the scoring team.");
  const profileId = requireString(body.profileId, "Choose the scorer.");
  const assistProfileId = body.assistProfileId || null;

  assertParticipatingClan(fixture, clanId);
  await assertPlayerInClan(db, clanId, profileId);

  if (assistProfileId) {
    await assertPlayerInClan(db, clanId, assistProfileId);
  }

  const { minute, second } = splitElapsed(await currentElapsed(db, fixtureId));
  const scoringMinute = clamp(minute === 0 ? 1 : minute, 1, 240);

  await assertNoError(
    db.from("fixture_scorers").insert({
      fixture_id: fixtureId,
      clan_id: clanId,
      profile_id: profileId,
      assist_profile_id: assistProfileId,
      minute: scoringMinute,
    }),
    "Could not record goal",
  );
  await insertEvent(
    db,
    fixtureId,
    "GOAL",
    scoringMinute,
    second,
    clanId,
    profileId,
    assistProfileId,
    null,
    "",
    occurredAt,
  );
  await syncScoreFromScorers(db, fixture);
}

async function recordBlueCard(
  db: SupabaseClient,
  fixtureId: string,
  body: ActionBody,
) {
  const fixture = await loadLiveFixture(db, fixtureId);
  const clanId = requireString(body.clanId, "Choose the team.");
  const profileId = requireString(body.profileId, "Choose the player.");

  assertParticipatingClan(fixture, clanId);
  await assertPlayerInClan(db, clanId, profileId);

  const now = new Date();
  const expiresAt = new Date(now.getTime() + 120_000);
  const { minute, second } = splitElapsed(await currentElapsed(db, fixtureId));

  const { data, error } = await db
    .from("fixture_blue_cards")
    .insert({
      fixture_id: fixtureId,
      clan_id: clanId,
      profile_id: profileId,
      started_at: now.toISOString(),
      expires_at: expiresAt.toISOString(),
      duration_seconds: 120,
      status: "ACTIVE",
      minute,
      second,
    })
    .select("id")
    .single();

  if (error) throw new Error(`Could not record blue card: ${error.message}`);

  await insertEvent(
    db,
    fixtureId,
    "BLUE_CARD",
    minute,
    second,
    clanId,
    profileId,
    null,
    String(data.id),
  );
}

async function expireBlueCard(
  db: SupabaseClient,
  fixtureId: string,
  blueCardId?: string,
) {
  const cardId = requireString(blueCardId, "Missing blue card id.");

  const { data: card, error: cardError } = await db
    .from("fixture_blue_cards")
    .update({ status: "EXPIRED" })
    .eq("id", cardId)
    .eq("fixture_id", fixtureId)
    .select("clan_id,profile_id")
    .single();

  if (cardError) {
    throw new Error(`Could not clear blue card: ${cardError.message}`);
  }

  const { minute, second } = splitElapsed(await currentElapsed(db, fixtureId));
  await insertEvent(
    db,
    fixtureId,
    "BLUE_CARD_EXPIRED",
    minute,
    second,
    String(card.clan_id),
    String(card.profile_id),
    null,
    cardId,
  );
}

async function finishFixture(db: SupabaseClient, fixtureId: string) {
  await assertNoError(
    db.rpc("referee_finish_fixture_atomic", {
      fixture_id_to_complete: fixtureId,
    }),
    "Could not finalize fixture",
  );
}

async function setFixtureTime(
  db: SupabaseClient,
  fixtureId: string,
  requestedElapsedSeconds?: number,
) {
  const fixture = await loadFixture(db, fixtureId);
  if (fixture.status !== "FINAL") {
    throw new Error("Stop the match before correcting its time.");
  }

  const rawElapsedSeconds = Number(requestedElapsedSeconds);
  if (
    !Number.isFinite(rawElapsedSeconds) ||
    rawElapsedSeconds < 0 ||
    rawElapsedSeconds > MAX_MATCH_SECONDS
  ) {
    throw new Error("Match time must be between 0:00 and 180:00.");
  }

  const elapsedSeconds = Math.round(rawElapsedSeconds);
  const clock = await loadClock(db, fixtureId);
  const { minute, second } = splitElapsed(elapsedSeconds);

  await assertNoError(
    db.from("fixture_clock_states").upsert(
      {
        fixture_id: fixtureId,
        status: "ENDED",
        started_at: null,
        accumulated_seconds: elapsedSeconds,
        duration_seconds: clock.duration_seconds,
      },
      { onConflict: "fixture_id" },
    ),
    "Could not correct match time",
  );

  const { data: endedEvent, error: endedEventError } = await db
    .from("fixture_events")
    .select("id")
    .eq("fixture_id", fixtureId)
    .eq("event_type", "MATCH_ENDED")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (endedEventError) {
    throw new Error(
      `Could not load final whistle event: ${endedEventError.message}`,
    );
  }

  if (endedEvent) {
    await assertNoError(
      db
        .from("fixture_events")
        .update({ minute, second })
        .eq("id", String(endedEvent.id)),
      "Could not correct final whistle time",
    );
  } else {
    await insertEvent(db, fixtureId, "MATCH_ENDED", minute, second);
  }

  await insertEvent(
    db,
    fixtureId,
    "CORRECTION",
    minute,
    second,
    null,
    null,
    null,
    null,
    `Match time corrected to ${formatElapsed(elapsedSeconds)}`,
  );
}

async function syncScoreFromScorers(
  db: SupabaseClient,
  fixture: FixtureRow,
) {
  const { data: rows, error } = await db
    .from("fixture_scorers")
    .select("clan_id")
    .eq("fixture_id", fixture.id);

  if (error) throw new Error(`Could not recalculate score: ${error.message}`);

  const homeScore = (rows ?? []).filter(
    (row) => String(row.clan_id) === fixture.home_clan_id,
  ).length;
  const awayScore = (rows ?? []).filter(
    (row) => String(row.clan_id) === fixture.away_clan_id,
  ).length;
  const winnerClanId = homeScore > awayScore
    ? fixture.home_clan_id
    : awayScore > homeScore
    ? fixture.away_clan_id
    : null;

  await assertNoError(
    db
      .from("fixtures")
      .update({
        home_score: homeScore,
        away_score: awayScore,
        winner_clan_id: winnerClanId,
      })
      .eq("id", fixture.id),
    "Could not update final score",
  );
}

async function loadLiveFixture(db: SupabaseClient, fixtureId: string) {
  const fixture = await loadFixture(db, fixtureId);
  if (fixture.status !== "LIVE") {
    throw new Error("Start the match before recording events.");
  }
  return fixture;
}

async function loadFixture(
  db: SupabaseClient,
  fixtureId: string,
): Promise<FixtureRow> {
  const { data, error } = await db
    .from("fixtures")
    .select("id,status,home_clan_id,away_clan_id")
    .eq("id", fixtureId)
    .single();

  if (error) throw new Error(`Could not load fixture: ${error.message}`);

  return {
    id: String(data.id),
    status: String(data.status),
    home_clan_id: String(data.home_clan_id),
    away_clan_id: data.away_clan_id ? String(data.away_clan_id) : null,
  };
}

async function loadClock(
  db: SupabaseClient,
  fixtureId: string,
): Promise<ClockRow> {
  const { data, error } = await db
    .from("fixture_clock_states")
    .select("status,started_at,accumulated_seconds,duration_seconds")
    .eq("fixture_id", fixtureId)
    .maybeSingle();

  if (error) throw new Error(`Could not load clock: ${error.message}`);

  if (!data) {
    return {
      status: "NOT_STARTED",
      started_at: null,
      accumulated_seconds: 0,
      duration_seconds: 3600,
    };
  }

  return {
    status: String(data.status),
    started_at: data.started_at ? String(data.started_at) : null,
    accumulated_seconds: Number(data.accumulated_seconds ?? 0),
    duration_seconds: Number(data.duration_seconds ?? 3600),
  };
}

async function currentElapsed(db: SupabaseClient, fixtureId: string) {
  return elapsedFromClock(await loadClock(db, fixtureId));
}

function elapsedFromClock(clock: ClockRow) {
  if (clock.status !== "RUNNING" || !clock.started_at) {
    return Math.max(0, Math.round(clock.accumulated_seconds));
  }

  const startedAt = new Date(clock.started_at).getTime();
  const delta = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
  return Math.max(0, Math.round(clock.accumulated_seconds + delta));
}

function splitElapsed(totalSeconds: number) {
  const safeSeconds = Math.max(0, Math.round(totalSeconds));
  return {
    minute: Math.min(240, Math.floor(safeSeconds / 60)),
    second: safeSeconds % 60,
  };
}

function formatElapsed(totalSeconds: number) {
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}

async function assertPlayerInClan(
  db: SupabaseClient,
  clanId: string,
  profileId: string,
) {
  const { data, error } = await db
    .from("clan_members")
    .select("profile_id")
    .eq("clan_id", clanId)
    .eq("profile_id", profileId)
    .is("left_at", null)
    .maybeSingle();

  if (error) throw new Error(`Could not verify player: ${error.message}`);
  if (!data) throw new Error("That player is not in the selected clan.");
}

function assertParticipatingClan(fixture: FixtureRow, clanId: string) {
  if (fixture.home_clan_id !== clanId && fixture.away_clan_id !== clanId) {
    throw new Error("Selected team is not playing this match.");
  }
}

async function insertEvent(
  db: SupabaseClient,
  fixtureId: string,
  eventType: string,
  minute: number,
  second: number,
  clanId: string | null = null,
  profileId: string | null = null,
  assistProfileId: string | null = null,
  blueCardId: string | null = null,
  note = "",
  occurredAt: string | null = null,
) {
  await assertNoError(
    db.from("fixture_events").insert({
      fixture_id: fixtureId,
      event_type: eventType,
      clan_id: clanId,
      profile_id: profileId,
      assist_profile_id: assistProfileId,
      blue_card_id: blueCardId,
      minute,
      second,
      note,
      ...(occurredAt ? { occurred_at: occurredAt } : {}),
    }),
    `Could not record ${eventType.toLowerCase()} event`,
  );
}

async function assertNoError(
  query: PromiseLike<{ error: { message: string } | null }>,
  action: string,
) {
  const { error } = await query;
  if (error) throw new Error(`${action}: ${error.message}`);
}

function requireString(value: string | null | undefined, message: string) {
  if (!value || value.trim().length === 0) {
    throw new Error(message);
  }
  return value.trim();
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}
