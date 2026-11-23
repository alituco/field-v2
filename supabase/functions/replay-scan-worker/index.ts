import { createClient } from "https://esm.sh/@supabase/supabase-js@2.86.0";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.10.0";
import { permitsScanner } from "./auth.ts";

const issuer = "https://token.actions.githubusercontent.com";
const keys = createRemoteJWKSet(new URL(issuer + "/.well-known/jwks"));
const url = Deno.env.get("SUPABASE_URL")!;
const project = new URL(url).hostname.split(".")[0];
const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
type Job = {
  source_type: "SOLO" | "CLAN";
  match_id: string;
  video_id: string;
  next_attempt_at: string;
};
const table = "replay_goal_scans";
function identity(job: Job) {
  return {
    source_type: job.source_type,
    match_id: job.match_id,
    video_id: job.video_id,
  };
}
async function scoreEvents(job: Job) {
  const solo = job.source_type === "SOLO";
  const match = solo
    ? await db.from("open_queue_games").select("status").eq("id", job.match_id)
      .single()
    : await db.from("fixtures").select("status,home_clan_id,away_clan_id").eq(
      "id",
      job.match_id,
    ).single();
  if (match.error) throw match.error;
  if (match.data.status !== "FINAL") return null;
  const teams = match.data as { home_clan_id?: string; away_clan_id?: string };
  const result = await db.from(solo ? "open_queue_events" : "fixture_events")
    .select("id,event_type,goal_id," + (solo ? "team" : "clan_id"))
    .eq(solo ? "game_id" : "fixture_id", job.match_id)
    .in("event_type", ["GOAL", "CORRECTION"])
    .order("occurred_at").order("id").limit(500);
  if (result.error) throw result.error;
  if (result.data.length === 500) throw new Error("Event limit reached");
  const credit = await db.rpc("get_credited_replay_goals", {
    source_type_to_use: job.source_type,
    match_id_to_use: job.match_id,
  });
  if (credit.error) throw credit.error;
  const credited = new Set((credit.data as { id: string }[]).map((g) => g.id));
  const rows = result.data as unknown as {
    id: string;
    event_type: string;
    goal_id: string | null;
    team?: string;
    clan_id?: string;
  }[];
  return rows.filter((e) => e.event_type === "GOAL" || e.goal_id !== null)
    .map((e) => ({
      id: e.id,
      event_type: e.event_type,
      team: solo
        ? e.team
        : e.clan_id === teams.home_clan_id
        ? "HOME"
        : e.clan_id === teams.away_clan_id
        ? "AWAY"
        : null,
      goal_id: e.goal_id,
      is_credited: credited.has(e.id),
    }));
}
async function claim() {
  const now = new Date();
  const { data, error } = await db.from(table).select(
    "source_type,match_id,video_id,next_attempt_at",
  )
    .eq("status", "pending").lte("next_attempt_at", now.toISOString()).order(
      "next_attempt_at",
    ).limit(1).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const job = data as Job;
  // A crashed or cancelled runner automatically releases its lease.
  const lease = new Date(now.getTime() + 60 * 60 * 1000).toISOString();
  const claimed = await db.from(table).update({ next_attempt_at: lease })
    .match(identity(job)).eq("status", "pending").eq(
      "next_attempt_at",
      job.next_attempt_at,
    )
    .select("next_attempt_at").maybeSingle();
  if (claimed.error) throw claimed.error;
  if (!claimed.data) return null;
  job.next_attempt_at = claimed.data.next_attempt_at;
  const solo = job.source_type === "SOLO";
  const broadcast = await db.from(
    solo ? "open_queue_broadcasts" : "fixture_broadcasts",
  )
    .select("active_video_id,replay_hls_url,status").eq(
      solo ? "game_id" : "fixture_id",
      job.match_id,
    ).maybeSingle();
  if (broadcast.error) throw broadcast.error;
  if (!broadcast.data || broadcast.data.active_video_id !== job.video_id) {
    const retired = await db.from(table).update({ status: "unmatched" }).match(
      identity(job),
    ).eq("next_attempt_at", job.next_attempt_at);
    if (retired.error) throw retired.error;
    return { skip: true };
  }
  if (broadcast.data.status !== "REPLAY_READY") return { skip: true };
  const events = await scoreEvents(job);
  if (!events) return { skip: true };
  const hls = new URL(broadcast.data.replay_hls_url);
  if (
    hls.protocol !== "https:" ||
    !/^customer-[a-z0-9-]+\.cloudflarestream\.com$/.test(hls.hostname) ||
    !/^[a-f0-9]{32}$/.test(job.video_id) ||
    hls.pathname !== "/" + job.video_id + "/manifest/video.m3u8" ||
    hls.port || hls.username || hls.password
  ) throw new Error("Invalid replay source");
  return { job, events, hls: hls.href };
}
async function finish(
  body: {
    job: Job;
    status: string;
    positions: Record<string, number>;
    events: unknown;
  },
) {
  const { job, status, positions } = body;
  if (
    !job || !["SOLO", "CLAN"].includes(job.source_type) ||
    !["scanned", "unmatched"].includes(status) || !positions ||
    typeof positions !== "object" || Array.isArray(positions)
  ) {
    return new Response("Invalid scan result", { status: 400 });
  }
  const current = await scoreEvents(job);
  // Goal corrections made while decoding invalidate that attempt.
  if (!current || JSON.stringify(current) !== JSON.stringify(body.events)) {
    return new Response("Score changed", { status: 409 });
  }
  const ids = new Set(current.filter((e) => e.is_credited).map((e) => e.id));
  for (const [id, sec] of Object.entries(positions)) {
    if (
      status !== "scanned" || !ids.has(id) || !Number.isFinite(sec) ||
      sec < 0 || sec > 10800
    ) {
      return new Response("Invalid goal position", { status: 400 });
    }
  }
  if (status === "scanned" && Object.keys(positions).length !== ids.size) {
    return new Response("Incomplete scan", { status: 400 });
  }
  const { data, error } = await db.from(table).update({
    status,
    goal_positions: positions,
  })
    .match(identity(job)).eq("status", "pending").eq(
      "next_attempt_at",
      job.next_attempt_at,
    ).select("status").maybeSingle();
  if (error) throw error;
  return data
    ? Response.json({ status })
    : new Response("Lease changed", { status: 409 });
}
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response(null, { status: 405 });
  try {
    const token = req.headers.get("Authorization")?.match(/^Bearer (\S+)$/i)
      ?.[1];
    if (!token) throw new Error();
    const { payload } = await jwtVerify(token, keys, {
      issuer,
      audience: "fieldrush-replay-" + project,
      algorithms: ["RS256"],
      requiredClaims: ["exp", "iat"],
    });
    if (!permitsScanner(project, payload)) throw new Error();
  } catch {
    return new Response(null, { status: 403 });
  }
  try {
    const body = await req.json();
    if (body.action === "available") {
      const { data, error } = await db.from(table).select("video_id").eq(
        "status",
        "pending",
      )
        .lte("next_attempt_at", new Date().toISOString()).limit(1);
      if (error) throw error;
      return Response.json(!!data.length);
    }
    if (body.action === "claim") return Response.json(await claim());
    if (body.action === "finish") return await finish(body);
    return new Response(null, { status: 400 });
  } catch {
    console.error("Replay scan queue operation failed");
    return new Response("Queue operation failed", { status: 500 });
  }
});
