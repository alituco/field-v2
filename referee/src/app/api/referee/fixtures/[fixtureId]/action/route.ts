import { NextRequest, NextResponse } from "next/server";
import type { SupabaseClient } from "@supabase/supabase-js";

import { refereeAuthError } from "@/lib/referee-auth";
import { createSupabaseAdmin } from "@/lib/supabase-admin";

type RouteContext = {
  params: Promise<{ fixtureId: string }>;
};

type ActionBody = {
  action:
    | "start"
    | "pause"
    | "resume"
    | "goal"
    | "blue_card"
    | "expire_blue_card"
    | "finish";
  durationSeconds?: number;
  clanId?: string;
  profileId?: string;
  assistProfileId?: string | null;
  blueCardId?: string;
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

export async function POST(request: NextRequest, context: RouteContext) {
  const authError = refereeAuthError(request);
  if (authError) return authError;

  const { fixtureId } = await context.params;
  const db = createSupabaseAdmin();

  try {
    const body = (await request.json()) as ActionBody;

    switch (body.action) {
      case "start":
        await startFixture(db, fixtureId, body.durationSeconds);
        break;
      case "pause":
        await pauseFixture(db, fixtureId);
        break;
      case "resume":
        await resumeFixture(db, fixtureId);
        break;
      case "goal":
        await recordGoal(db, fixtureId, body);
        break;
      case "blue_card":
        await recordBlueCard(db, fixtureId, body);
        break;
      case "expire_blue_card":
        await expireBlueCard(db, fixtureId, body.blueCardId);
        break;
      case "finish":
        await finishFixture(db, fixtureId);
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

async function startFixture(
  db: SupabaseClient,
  fixtureId: string,
  durationSeconds = 3600,
) {
  const fixture = await loadFixture(db, fixtureId);

  if (fixture.status === "FINAL") {
    throw new Error("This match is already final.");
  }

  if (fixture.away_clan_id === null) {
    throw new Error("Cannot start a match without an opponent.");
  }

  const safeDuration = clamp(Math.round(durationSeconds), 600, 7200);
  const now = new Date();

  await assertNoError(
    db.from("fixtures").update({ status: "LIVE" }).eq("id", fixtureId),
    "Could not start fixture",
  );
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
  await insertEvent(db, fixtureId, "MATCH_STARTED", 0, 0);
}

async function pauseFixture(db: SupabaseClient, fixtureId: string) {
  await loadFixture(db, fixtureId);
  const clock = await loadClock(db, fixtureId);
  const elapsedSeconds = elapsedFromClock(clock);
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
  const scoringMinute = clamp(minute === 0 ? 1 : minute, 1, 130);

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
  );
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
  const elapsedSeconds = elapsedFromClock(clock);
  const { minute, second } = splitElapsed(elapsedSeconds);

  await assertNoError(
    db
      .from("fixture_clock_states")
      .update({
        status: "ENDED",
        started_at: null,
        accumulated_seconds: Math.min(elapsedSeconds, clock.duration_seconds),
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
    minute: Math.min(130, Math.floor(safeSeconds / 60)),
    second: safeSeconds % 60,
  };
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
