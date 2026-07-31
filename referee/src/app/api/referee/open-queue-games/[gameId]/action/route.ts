import { NextRequest, NextResponse } from "next/server";
import type { SupabaseClient } from "@supabase/supabase-js";

import { queueOpenQueueBroadcastStop } from "@/lib/broadcasts";
import { assertCanManageOpenQueueGame } from "@/lib/fixture-access";
import {
  parseAdminCancellationInput,
  parseAdminScoreOverrideInput,
  parseMatchStoppageInput,
  parseRefereeBulkCheckInInput,
  parseRefereeCheckInInput,
  parseRefereeRemoveCheckInInput,
  parseRefereeEndShorthandedInput,
  parseRefereeReportInput,
  parseRefereeStartShorthandedInput,
  parseRefereeVerifiedInjuryInput,
} from "@/lib/match-action-input";
import { canRefereePerformOperationalAction } from "@/lib/match-operational-lock";
import { isRefereeContext, requireReferee } from "@/lib/referee-session";

type RouteContext = { params: Promise<{ gameId: string }> };

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

type GameRow = { id: string; status: string };
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
  const { gameId } = await context.params;
  const db = refereeContext.db;

  try {
    await assertCanManageOpenQueueGame(
      db,
      gameId,
      refereeContext.referee.profileId,
      refereeContext.referee.role,
    );
    const body = (await request.json()) as ActionBody;
    const { data: operationalGame, error: operationalError } = await db
      .from("open_queue_games")
      .select("operational_state")
      .eq("id", gameId)
      .single();
    if (operationalError) {
      throw new Error(
        `Could not verify the match review state: ${operationalError.message}`,
      );
    }
    if (
      !canRefereePerformOperationalAction(
        operationalGame.operational_state,
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
        await startGame(
          db,
          gameId,
          body.durationSeconds,
          body.participantIds,
          refereeContext.referee.profileId,
          refereeContext.referee.role === "admin",
        );
        break;
      case "pause":
        await pauseGame(db, gameId);
        break;
      case "resume":
        await resumeGame(db, gameId);
        break;
      case "set_time":
        await setGameTime(db, gameId, body.elapsedSeconds);
        break;
      case "goal":
        await recordGoal(db, gameId, body, requestReceivedAt);
        break;
      case "blue_card":
        await recordBlueCard(db, gameId, body);
        break;
      case "expire_blue_card":
        await expireBlueCard(db, gameId, body.blueCardId);
        break;
      case "finish":
        await finishGame(db, gameId);
        try {
          await queueOpenQueueBroadcastStop(
            db,
            gameId,
            refereeContext.referee.profileId,
            30,
          );
        } catch (broadcastError) {
          console.error("Could not queue automatic solo broadcast stop", broadcastError);
        }
        break;
      case "report": {
        const report = parseRefereeReportInput(body, "SOLO", gameId);
        const { data, error } = await db.rpc("submit_referee_moderation_report", {
          reporter_referee_id_to_use: refereeContext.referee.profileId,
          subject_type_to_use: report.subjectType,
          subject_id_to_use: report.subjectId,
          category_to_use: report.category,
          details_to_use: report.details,
          priority_to_use: report.priority,
          fixture_id_to_use: null,
          open_queue_game_id_to_use: gameId,
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
          match_kind_to_use: "SOLO",
          match_id_to_use: gameId,
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
            match_kind_to_use: "SOLO",
            match_id_to_use: gameId,
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
            match_kind_to_use: "SOLO",
            match_id_to_use: gameId,
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
            match_kind_to_use: "SOLO",
            match_id_to_use: gameId,
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
            match_kind_to_use: "SOLO",
            match_id_to_use: gameId,
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
        const period = parseRefereeStartShorthandedInput(body, "SOLO");
        const { data, error } = await db.rpc(
          "referee_start_shorthanded_period",
          {
            actor_referee_id: refereeContext.referee.profileId,
            match_kind_to_use: "SOLO",
            match_id_to_use: gameId,
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
      case "stop": {
        const stoppage = parseMatchStoppageInput(body);
        const { data, error } = await db.rpc("referee_record_match_stoppage", {
          actor_referee_id: refereeContext.referee.profileId,
          match_kind_to_use: "SOLO",
          match_id_to_stop: gameId,
          mode_to_use: stoppage.mode,
          reason_code_to_use: stoppage.reasonCode,
          note_to_use: stoppage.note || null,
        });
        if (error) throw new Error(`Could not stop match: ${error.message}`);
        result = { stoppageId: String(data), mode: stoppage.mode };

        if (stoppage.mode === "ABANDON") {
          try {
            await queueOpenQueueBroadcastStop(
              db,
              gameId,
              refereeContext.referee.profileId,
            );
          } catch (broadcastError) {
            console.error(
              "Could not stop abandoned solo match broadcast",
              broadcastError,
            );
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
          match_kind_to_use: "SOLO",
          match_id_to_cancel: gameId,
          reason_code_to_use: cancellation.reasonCode,
          reason_to_use: cancellation.reason,
        });
        if (error) throw new Error(`Could not cancel match: ${error.message}`);
        try {
          await queueOpenQueueBroadcastStop(
            db,
            gameId,
            refereeContext.referee.profileId,
          );
        } catch (broadcastError) {
          console.error(
            "Could not stop cancelled solo match broadcast",
            broadcastError,
          );
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
          match_kind_to_use: "SOLO",
          match_id_to_update: gameId,
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

async function startGame(
  db: SupabaseClient,
  gameId: string,
  durationSeconds: number | undefined,
  participantIds: string[] | undefined,
  actorRefereeId: string,
  actorIsAdmin: boolean,
) {
  if (!Array.isArray(participantIds)) {
    throw new Error("Confirm the players taking part before starting.");
  }
  const selectedIds = [...new Set(participantIds.map(String).map((id) => id.trim()))]
    .filter(Boolean);
  if (selectedIds.length === 0) {
    throw new Error("Select at least one player from each team.");
  }
  const safeDuration = clamp(Math.round(durationSeconds ?? 3600), 600, 7200);

  const { data: game, error: gameError } = await db
    .from("open_queue_games")
    .select("status,starts_at,teams_assigned_at,capacity")
    .eq("id", gameId)
    .single();
  if (gameError || !game) {
    throw new Error(`Could not load solo game: ${gameError?.message ?? "Game not found."}`);
  }

  const scheduledStartMs = new Date(String(game.starts_at)).getTime();
  const isEarlyStart = Number.isFinite(scheduledStartMs) &&
    Date.now() < scheduledStartMs;

  if (isEarlyStart) {
    if (!actorIsAdmin) {
      throw new Error(
        "This match has not reached its scheduled kickoff. Only an admin can start an early test match.",
      );
    }

    const { data: confirmedBookings, error: bookingsError } = await db
      .from("open_queue_bookings")
      .select("profile_id")
      .eq("game_id", gameId)
      .eq("status", "CONFIRMED");
    if (bookingsError) {
      throw new Error(`Could not verify the early-start roster: ${bookingsError.message}`);
    }
    const confirmedIds = new Set(
      (confirmedBookings ?? []).map((booking) => String(booking.profile_id)),
    );
    const expectedCount = Number(game.capacity ?? confirmedIds.size);
    if (
      confirmedIds.size !== expectedCount ||
      selectedIds.length !== confirmedIds.size ||
      selectedIds.some((profileId) => !confirmedIds.has(profileId))
    ) {
      throw new Error(
        `Check in and select all ${expectedCount} booked players before starting this match early.`,
      );
    }

    const { error: assignmentError } = await db.rpc(
      "admin_force_assign_open_queue_teams",
      {
        actor_admin_id: actorRefereeId,
        game_id_to_assign: gameId,
        reason_to_use: "Admin started this assigned match early from the referee console.",
      },
    );
    if (assignmentError) {
      throw new Error(`Could not prepare teams for the early start: ${assignmentError.message}`);
    }
  }

  await assertNoError(
    db.rpc("referee_start_open_queue_game", {
      game_id_to_start: gameId,
      participant_ids_to_use: selectedIds,
      duration_seconds_to_use: safeDuration,
    }),
    "Could not start solo game",
  );
}

async function pauseGame(db: SupabaseClient, gameId: string) {
  await loadLiveGame(db, gameId);
  const elapsed = Math.min(elapsedFromClock(await loadClock(db, gameId)), MAX_MATCH_SECONDS);
  const { minute, second } = splitElapsed(elapsed);
  await assertNoError(
    db.from("open_queue_clock_states").update({
      status: "PAUSED",
      started_at: null,
      accumulated_seconds: elapsed,
    }).eq("game_id", gameId),
    "Could not pause solo game clock",
  );
  await insertEvent(db, gameId, "MATCH_PAUSED", minute, second);
}

async function resumeGame(db: SupabaseClient, gameId: string) {
  await loadLiveGame(db, gameId);
  const { minute, second } = splitElapsed(await currentElapsed(db, gameId));
  await assertNoError(
    db.from("open_queue_clock_states").update({
      status: "RUNNING",
      started_at: new Date().toISOString(),
    }).eq("game_id", gameId),
    "Could not resume solo game clock",
  );
  await insertEvent(db, gameId, "MATCH_RESUMED", minute, second);
}

async function recordGoal(
  db: SupabaseClient,
  gameId: string,
  body: ActionBody,
  occurredAt: string,
) {
  await loadLiveGame(db, gameId);
  const team = requireTeam(body.clanId);
  const profileId = requireString(body.profileId, "Choose the scorer.");
  const assistProfileId = body.assistProfileId || null;
  await assertPlayerOnTeam(db, gameId, team, profileId);
  if (assistProfileId) await assertPlayerOnTeam(db, gameId, team, assistProfileId);

  const elapsed = await currentElapsed(db, gameId);
  const split = splitElapsed(elapsed);
  const minute = clamp(split.minute === 0 ? 1 : split.minute, 1, 240);

  await assertNoError(
    db.from("open_queue_goals").insert({
      game_id: gameId,
      team,
      profile_id: profileId,
      assist_profile_id: assistProfileId,
      minute,
    }),
    "Could not record goal",
  );
  await insertEvent(
    db,
    gameId,
    "GOAL",
    minute,
    split.second,
    team,
    profileId,
    assistProfileId,
    null,
    "",
    occurredAt,
  );
  await syncScore(db, gameId);
}

async function recordBlueCard(db: SupabaseClient, gameId: string, body: ActionBody) {
  await loadLiveGame(db, gameId);
  const team = requireTeam(body.clanId);
  const profileId = requireString(body.profileId, "Choose the player.");
  await assertPlayerOnTeam(db, gameId, team, profileId);
  const now = new Date();
  const { minute, second } = splitElapsed(await currentElapsed(db, gameId));
  const { data, error } = await db.from("open_queue_blue_cards").insert({
    game_id: gameId,
    team,
    profile_id: profileId,
    started_at: now.toISOString(),
    expires_at: new Date(now.getTime() + 120_000).toISOString(),
    duration_seconds: 120,
    status: "ACTIVE",
    minute,
    second,
  }).select("id").single();
  if (error) throw new Error(`Could not record blue card: ${error.message}`);
  await insertEvent(
    db,
    gameId,
    "BLUE_CARD",
    minute,
    second,
    team,
    profileId,
    null,
    String(data.id),
  );
}

async function expireBlueCard(db: SupabaseClient, gameId: string, blueCardId?: string) {
  const id = requireString(blueCardId, "Missing blue card id.");
  const { data, error } = await db.from("open_queue_blue_cards")
    .update({ status: "EXPIRED" })
    .eq("id", id)
    .eq("game_id", gameId)
    .select("team,profile_id")
    .single();
  if (error) throw new Error(`Could not clear blue card: ${error.message}`);
  const { minute, second } = splitElapsed(await currentElapsed(db, gameId));
  await insertEvent(
    db,
    gameId,
    "BLUE_CARD_EXPIRED",
    minute,
    second,
    String(data.team),
    String(data.profile_id),
    null,
    id,
  );
}

async function finishGame(db: SupabaseClient, gameId: string) {
  await assertNoError(
    db.rpc("referee_complete_open_queue_game", { game_id_to_complete: gameId }),
    "Could not finalize solo game",
  );
}

async function setGameTime(
  db: SupabaseClient,
  gameId: string,
  requestedElapsedSeconds?: number,
) {
  const game = await loadGame(db, gameId);
  if (game.status !== "FINAL") throw new Error("Stop the match before correcting its time.");
  const raw = Number(requestedElapsedSeconds);
  if (!Number.isFinite(raw) || raw < 0 || raw > MAX_MATCH_SECONDS) {
    throw new Error("Match time must be between 0:00 and 180:00.");
  }
  const elapsed = Math.round(raw);
  const clock = await loadClock(db, gameId);
  const { minute, second } = splitElapsed(elapsed);
  await assertNoError(
    db.from("open_queue_clock_states").upsert({
      game_id: gameId,
      status: "ENDED",
      started_at: null,
      accumulated_seconds: elapsed,
      duration_seconds: clock.duration_seconds,
    }, { onConflict: "game_id" }),
    "Could not correct match time",
  );
  const { data: ended, error } = await db.from("open_queue_events")
    .select("id")
    .eq("game_id", gameId)
    .eq("event_type", "MATCH_ENDED")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw new Error(`Could not load final whistle event: ${error.message}`);
  if (ended) {
    await assertNoError(
      db.from("open_queue_events").update({ minute, second }).eq("id", ended.id),
      "Could not correct final whistle time",
    );
  } else {
    await insertEvent(db, gameId, "MATCH_ENDED", minute, second);
  }
  await insertEvent(
    db,
    gameId,
    "CORRECTION",
    minute,
    second,
    null,
    null,
    null,
    null,
    `Match time corrected to ${formatElapsed(elapsed)}`,
  );
}

async function syncScore(db: SupabaseClient, gameId: string) {
  const { data, error } = await db.from("open_queue_goals")
    .select("team")
    .eq("game_id", gameId);
  if (error) throw new Error(`Could not recalculate score: ${error.message}`);
  const whiteScore = (data ?? []).filter((goal) => goal.team === "WHITE").length;
  const blackScore = (data ?? []).filter((goal) => goal.team === "BLACK").length;
  await assertNoError(
    db.from("open_queue_games").update({
      white_score: whiteScore,
      black_score: blackScore,
    }).eq("id", gameId),
    "Could not update final score",
  );
}

async function assertPlayerOnTeam(
  db: SupabaseClient,
  gameId: string,
  team: string,
  profileId: string,
) {
  const { data, error } = await db.from("open_queue_bookings")
    .select("profile_id")
    .eq("game_id", gameId)
    .eq("profile_id", profileId)
    .eq("status", "CONFIRMED")
    .eq("team", team)
    .eq("played", true)
    .maybeSingle();
  if (error) throw new Error(`Could not verify player: ${error.message}`);
  if (!data) throw new Error("That player is not in the selected solo team lineup.");
}

async function loadGame(db: SupabaseClient, gameId: string): Promise<GameRow> {
  const { data, error } = await db.from("open_queue_games")
    .select("id,status")
    .eq("id", gameId)
    .single();
  if (error) throw new Error(`Could not load solo game: ${error.message}`);
  return { id: String(data.id), status: String(data.status) };
}

async function loadLiveGame(db: SupabaseClient, gameId: string) {
  const game = await loadGame(db, gameId);
  if (game.status !== "LIVE") throw new Error("Start the match before recording events.");
  return game;
}

async function loadClock(db: SupabaseClient, gameId: string): Promise<ClockRow> {
  const { data, error } = await db.from("open_queue_clock_states")
    .select("status,started_at,accumulated_seconds,duration_seconds")
    .eq("game_id", gameId)
    .maybeSingle();
  if (error) throw new Error(`Could not load clock: ${error.message}`);
  return data
    ? {
        status: String(data.status),
        started_at: data.started_at ? String(data.started_at) : null,
        accumulated_seconds: Number(data.accumulated_seconds ?? 0),
        duration_seconds: Number(data.duration_seconds ?? 3600),
      }
    : {
        status: "NOT_STARTED",
        started_at: null,
        accumulated_seconds: 0,
        duration_seconds: 3600,
      };
}

async function currentElapsed(db: SupabaseClient, gameId: string) {
  return elapsedFromClock(await loadClock(db, gameId));
}

function elapsedFromClock(clock: ClockRow) {
  if (clock.status !== "RUNNING" || !clock.started_at) {
    return Math.max(0, Math.round(clock.accumulated_seconds));
  }
  return Math.max(
    0,
    Math.round(
      clock.accumulated_seconds +
        Math.max(0, Math.floor((Date.now() - Date.parse(clock.started_at)) / 1000)),
    ),
  );
}

async function insertEvent(
  db: SupabaseClient,
  gameId: string,
  eventType: string,
  minute: number,
  second: number,
  team: string | null = null,
  profileId: string | null = null,
  assistProfileId: string | null = null,
  blueCardId: string | null = null,
  note = "",
  occurredAt: string | null = null,
) {
  await assertNoError(
    db.from("open_queue_events").insert({
      game_id: gameId,
      event_type: eventType,
      team,
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

function requireTeam(value: string | null | undefined) {
  const team = requireString(value, "Choose the scoring team.").toUpperCase();
  if (team !== "WHITE" && team !== "BLACK") throw new Error("Choose White or Black.");
  return team;
}

function requireString(value: string | null | undefined, message: string) {
  if (!value?.trim()) throw new Error(message);
  return value.trim();
}

function splitElapsed(totalSeconds: number) {
  const safe = Math.max(0, Math.round(totalSeconds));
  return { minute: Math.min(240, Math.floor(safe / 60)), second: safe % 60 };
}

function formatElapsed(totalSeconds: number) {
  return `${Math.floor(totalSeconds / 60)}:${String(totalSeconds % 60).padStart(2, "0")}`;
}

async function assertNoError(
  query: PromiseLike<{ error: { message: string } | null }>,
  action: string,
) {
  const { error } = await query;
  if (error) throw new Error(`${action}: ${error.message}`);
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}
