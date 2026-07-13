import { NextRequest, NextResponse } from "next/server";
import type { SupabaseClient } from "@supabase/supabase-js";

import { queueBroadcastStop } from "@/lib/broadcasts";
import { assertCanManageFixture } from "@/lib/fixture-access";
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
    | "correction_goal"
    | "delete_goal"
    | "blue_card"
    | "expire_blue_card"
    | "finish";
  durationSeconds?: number;
  clanId?: string;
  profileId?: string;
  assistProfileId?: string | null;
  blueCardId?: string;
  goalId?: string;
  elapsedSeconds?: number;
  minute?: number;
  note?: string;
  participantIds?: string[];
};

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
      case "correction_goal":
        assertAdmin(refereeContext.referee.role);
        await recordGoalCorrection(db, fixtureId, body);
        break;
      case "delete_goal":
        assertAdmin(refereeContext.referee.role);
        await deleteGoalCorrection(db, fixtureId, body.goalId);
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
      default:
        return NextResponse.json({ error: "Unknown action." }, { status: 400 });
    }

    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Action failed." },
      { status: 400 },
    );
  }
}

function assertAdmin(role: "admin" | "referee") {
  if (role !== "admin") {
    throw new Error("Admin access required for corrections.");
  }
}

async function startFixture(
  db: SupabaseClient,
  fixtureId: string,
  durationSeconds = 3600,
  participantIds: string[] | undefined = undefined,
) {
  const fixture = await loadFixture(db, fixtureId);

  if (fixture.status === "FINAL") {
    throw new Error("This match is already final.");
  }

  if (fixture.away_clan_id === null) {
    throw new Error("Cannot start a match without an opponent.");
  }

  if (fixture.status === "LIVE") {
    throw new Error("This match has already started.");
  }

  if (fixture.status !== "SCHEDULED") {
    throw new Error("Only scheduled matches can be started.");
  }

  const selectedParticipantIds = await validateParticipantIds(
    db,
    fixture,
    participantIds,
  );

  const safeDuration = clamp(Math.round(durationSeconds), 600, 7200);
  const now = new Date();

  await assertNoError(
    db.from("fixture_clock_states").upsert(
      {
        fixture_id: fixtureId,
        status: "RUNNING",
        started_at: now.toISOString(),
        accumulated_seconds: 0,
        duration_seconds: safeDuration,
      },
      { onConflict: "fixture_id" },
    ),
    "Could not start fixture clock",
  );
  await assertNoError(
    db.from("fixtures").update({ status: "LIVE" }).eq("id", fixtureId),
    "Could not start fixture",
  );
  await saveFixtureParticipants(db, fixtureId, selectedParticipantIds);
  await insertEvent(db, fixtureId, "MATCH_STARTED", 0, 0);
}

async function validateParticipantIds(
  db: SupabaseClient,
  fixture: FixtureRow,
  participantIds: string[] | undefined,
) {
  if (!Array.isArray(participantIds)) {
    throw new Error("Confirm the players taking part before starting.");
  }

  const selectedIds = [...new Set(participantIds.map((id) => String(id).trim()))]
    .filter(Boolean);
  if (selectedIds.length === 0) {
    throw new Error("Select at least one player from each team.");
  }

  const { data, error } = await db
    .from("clan_members")
    .select("profile_id,clan_id")
    .in("profile_id", selectedIds)
    .in("clan_id", [fixture.home_clan_id, fixture.away_clan_id])
    .is("left_at", null);

  if (error) throw new Error(`Could not verify the lineup: ${error.message}`);

  const activeMembers = new Map(
    (data ?? []).map((row) => [String(row.profile_id), String(row.clan_id)]),
  );
  if (
    activeMembers.size !== selectedIds.length ||
    selectedIds.some((profileId) => !activeMembers.has(profileId))
  ) {
    throw new Error(
      "Every selected player must be an active member of a team in this match.",
    );
  }

  const hasHomePlayer = selectedIds.some(
    (profileId) => activeMembers.get(profileId) === fixture.home_clan_id,
  );
  const hasAwayPlayer = selectedIds.some(
    (profileId) => activeMembers.get(profileId) === fixture.away_clan_id,
  );
  if (!hasHomePlayer || !hasAwayPlayer) {
    throw new Error("Select at least one player from each team.");
  }

  return selectedIds;
}

async function saveFixtureParticipants(
  db: SupabaseClient,
  fixtureId: string,
  participantIds: string[],
) {
  await assertNoError(
    db
      .from("fixture_player_appearances")
      .update({ played: false })
      .eq("fixture_id", fixtureId),
    "Could not clear the fixture lineup",
  );
  const { data, error } = await db
    .from("fixture_player_appearances")
    .update({ played: true })
    .eq("fixture_id", fixtureId)
    .in("profile_id", participantIds)
    .select("profile_id");

  if (error) {
    throw new Error(`Could not save the fixture lineup: ${error.message}`);
  }

  const savedIds = new Set((data ?? []).map((row) => String(row.profile_id)));
  if (
    savedIds.size !== participantIds.length ||
    participantIds.some((profileId) => !savedIds.has(profileId))
  ) {
    throw new Error(
      "Could not save every selected player in the fixture lineup.",
    );
  }
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

async function recordGoalCorrection(
  db: SupabaseClient,
  fixtureId: string,
  body: ActionBody,
) {
  const fixture = await loadFixture(db, fixtureId);
  const clanId = requireString(body.clanId, "Choose the scoring team.");
  const profileId = requireString(body.profileId, "Choose the scorer.");
  const assistProfileId = body.assistProfileId || null;
  const minute = clamp(Math.round(Number(body.minute ?? 1)), 1, 240);

  if (fixture.away_clan_id === null) {
    throw new Error("Cannot correct a match without an opponent.");
  }

  if (fixture.status !== "FINAL") {
    throw new Error(
      "Historic corrections are only available for final matches.",
    );
  }

  assertParticipatingClan(fixture, clanId);
  await assertPlayerInClan(db, clanId, profileId);

  if (assistProfileId) {
    await assertPlayerInClan(db, clanId, assistProfileId);
  }

  await assertNoError(
    db.from("fixture_scorers").insert({
      fixture_id: fixtureId,
      clan_id: clanId,
      profile_id: profileId,
      assist_profile_id: assistProfileId,
      minute,
    }),
    "Could not record goal correction",
  );
  await insertEvent(
    db,
    fixtureId,
    "GOAL",
    minute,
    0,
    clanId,
    profileId,
    assistProfileId,
    null,
    "Admin correction",
  );
  await syncScoreFromScorers(db, fixture);
}

async function deleteGoalCorrection(
  db: SupabaseClient,
  fixtureId: string,
  goalId?: string,
) {
  const fixture = await loadFixture(db, fixtureId);
  const id = requireString(goalId, "Missing goal id.");

  if (fixture.status !== "FINAL") {
    throw new Error(
      "Historic corrections are only available for final matches.",
    );
  }

  const { data: goal, error: goalError } = await db
    .from("fixture_scorers")
    .select("id,fixture_id,clan_id,profile_id,assist_profile_id,minute")
    .eq("id", id)
    .eq("fixture_id", fixtureId)
    .single();

  if (goalError) {
    throw new Error(`Could not load goal correction: ${goalError.message}`);
  }

  await assertNoError(
    db.from("fixture_scorers").delete().eq("id", id).eq(
      "fixture_id",
      fixtureId,
    ),
    "Could not remove goal",
  );

  await assertNoError(
    db
      .from("fixture_events")
      .delete()
      .eq("fixture_id", fixtureId)
      .eq("event_type", "GOAL")
      .eq("clan_id", String(goal.clan_id))
      .eq("profile_id", String(goal.profile_id))
      .eq("minute", Number(goal.minute ?? 1)),
    "Could not remove matching goal event",
  );

  await insertEvent(
    db,
    fixtureId,
    "CORRECTION",
    Number(goal.minute ?? 1),
    0,
    String(goal.clan_id),
    String(goal.profile_id),
    goal.assist_profile_id ? String(goal.assist_profile_id) : null,
    null,
    "Removed goal correction",
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
  const fixture = await loadFixture(db, fixtureId);

  if (fixture.status === "FINAL") {
    throw new Error("This match is already final.");
  }

  const clock = await loadClock(db, fixtureId);
  const elapsedSeconds = Math.min(elapsedFromClock(clock), MAX_MATCH_SECONDS);
  const { minute, second } = splitElapsed(elapsedSeconds);

  await assertNoError(
    db
      .from("fixture_clock_states")
      .update({
        status: "ENDED",
        started_at: null,
        accumulated_seconds: elapsedSeconds,
      })
      .eq("fixture_id", fixtureId),
    "Could not stop fixture clock",
  );
  await insertEvent(db, fixtureId, "MATCH_ENDED", minute, second);

  const { error } = await db.rpc("referee_complete_fixture", {
    fixture_id_to_complete: fixtureId,
  });

  if (error) {
    throw new Error(`Could not finalize fixture: ${error.message}`);
  }

  // The completion function also handles older clock rows and may clamp them to
  // the configured match duration. Restore the referee's actual stopped time.
  await assertNoError(
    db
      .from("fixture_clock_states")
      .update({
        status: "ENDED",
        started_at: null,
        accumulated_seconds: elapsedSeconds,
      })
      .eq("fixture_id", fixtureId),
    "Could not save final match time",
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
