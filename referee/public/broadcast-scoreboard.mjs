const GOAL_BANNER_MILLISECONDS = 8_000;
const MAX_CLOCK_SECONDS = 10_800;

function finiteNumber(value, fallback = 0) {
  if (typeof value !== "number" && typeof value !== "string") return fallback;
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function instant(value) {
  if (typeof value !== "string" || !value.trim()) return NaN;
  return Date.parse(value);
}

function clockLabel(value) {
  const seconds = Math.floor(Math.max(0, value));
  return `${Math.floor(seconds / 60).toString().padStart(2, "0")}:${(seconds % 60).toString().padStart(2, "0")}`;
}

function teamLabel(team) {
  const tag = typeof team?.tag === "string" ? team.tag.trim() : "";
  const name = typeof team?.name === "string" ? team.name.trim() : "";
  return (tag || name || "TBD").toUpperCase();
}

/** Pure referee-state projection. A score correction is never a goal announcement. */
export function deriveScoreboard(payload, nowMs = Date.now()) {
  const data = payload ?? {};
  const clock = data.clock ?? {};
  const now = Number.isFinite(nowMs) ? nowMs : Date.now();
  const base = Math.max(0, finiteNumber(clock.accumulated_seconds));
  const startedAt = instant(clock.started_at);
  const running = clock.status === "RUNNING";
  const elapsed = Math.min(MAX_CLOCK_SECONDS, Math.floor(base + (
    running && Number.isFinite(startedAt) ? Math.max(0, (now - startedAt) / 1000) : 0
  )));
  const duration = finiteNumber(clock.duration_seconds, 3600);
  const halftime = finiteNumber(data.halftimeSeconds, duration > 0 ? duration / 2 : 1800);
  const ended = clock.status === "ENDED" || data.fixtureStatus === "FINAL";
  const beforeKickoff = !ended && clock.status !== "RUNNING" && clock.status !== "PAUSED" && elapsed === 0;
  const paused = clock.status === "PAUSED";
  const result = {
    homeLabel: teamLabel(data.home), awayLabel: teamLabel(data.away),
    homeScore: String(Math.floor(Math.min(999, Math.max(0, finiteNumber(data.homeScore))))),
    awayScore: String(Math.floor(Math.min(999, Math.max(0, finiteNumber(data.awayScore))))),
    clockText: clockLabel(elapsed), statusText: elapsed < halftime ? "1ST HALF" : "2ND HALF",
    variant: "clock", goalSide: null, showLiveDot: running && !ended,
  };
  if (ended) return { ...result, variant: "ended", statusText: "FT", showLiveDot: false };
  if (beforeKickoff) {
    let kickoff = "";
    if (Number.isFinite(instant(data.scheduledStart))) {
      try {
        kickoff = new Intl.DateTimeFormat("en-US", {
          hour: "numeric", minute: "2-digit", hour12: true, timeZone: data.timeZone || "UTC",
        }).format(new Date(data.scheduledStart)).replace(/\s/g, "");
      } catch { /* Invalid timezone must not break the scoreboard. */ }
    }
    return { ...result, variant: "kickoff", clockText: kickoff, statusText: "KICKOFF", showLiveDot: false };
  }
  if (paused && data.halftimePaused === true) return { ...result, variant: "halftime", statusText: "HT", showLiveDot: false };
  const goal = data.latestGoal;
  const goalAt = instant(goal?.createdAt);
  const goalAge = now - goalAt;
  if (goal && typeof goal.id === "string" && goal.id.trim() &&
      ["HOME", "AWAY"].includes(goal.team) && Number.isFinite(goalAt) &&
      goalAge >= -5_000 && goalAge < GOAL_BANNER_MILLISECONDS && (running || paused)) {
    const scorer = typeof goal.scorerName === "string" ? goal.scorerName.trim().slice(0, 40) : "";
    const minute = Math.max(0, Math.floor(finiteNumber(goal.minute)));
    return { ...result, variant: "goal", goalSide: goal.team,
      statusText: `GOAL${scorer ? ` ${scorer}` : ""} ${minute}′`, showLiveDot: false };
  }
  if (paused) return { ...result, variant: "paused", statusText: "PAUSED", showLiveDot: false };
  return result;
}

/** Deleting a goal must not announce a previous recent row again. */
export function createGoalWatermark() {
  let latest = -Infinity;
  let id = null;
  return (payload, nowMs = Date.now()) => {
    const goal = payload?.latestGoal;
    const createdAt = instant(goal?.createdAt);
    if (!goal || typeof goal.id !== "string" || !goal.id.trim() ||
        !["HOME", "AWAY"].includes(goal.team) || !Number.isFinite(createdAt) || createdAt > nowMs + 5_000) {
      return { ...payload, latestGoal: null };
    }
    if (createdAt < latest || (createdAt === latest && id !== null && goal.id !== id)) return { ...payload, latestGoal: null };
    latest = createdAt;
    id = goal.id;
    return payload;
  };
}

/** Serial polling prevents late responses from overwriting a newer score. */
export function startScoreboard(root, { fetcher = fetch, now = Date.now } = {}) {
  const token = new URLSearchParams(location.hash.replace(/^#/, "")).get("token") || "";
  let payload = null;
  let offset = 0;
  let loading = false;
  let active = true;
  const acceptGoal = createGoalWatermark();
  const text = (name, value) => {
    const element = root.querySelector(`[data-scoreboard="${name}"]`);
    if (element) element.textContent = value;
  };
  const render = () => {
    if (!payload || !active) return;
    const state = deriveScoreboard(payload, now() + offset);
    for (const name of ["homeLabel", "awayLabel", "homeScore", "awayScore", "clockText", "statusText"]) text(name, state[name]);
    root.dataset.variant = state.variant;
    root.dataset.goalSide = state.goalSide || "";
    root.dataset.running = String(state.showLiveDot);
    root.dataset.wideScore = String(state.homeScore.length > 1 || state.awayScore.length > 1);
    root.classList.add("ready");
  };
  const load = async () => {
    if (!active || loading || !token) return;
    loading = true;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5_000);
    const requestAt = now();
    try {
      const response = await fetcher(`${root.dataset.apiBase}${root.dataset.matchId}`, {
        headers: { authorization: `Bearer ${token}` }, cache: "no-store", signal: controller.signal,
      });
      if (!response.ok) return;
      const next = await response.json();
      if (!active || !next || next.fixtureId !== root.dataset.matchId || !next.clock || !next.home || !next.away) return;
      const serverAt = instant(next.serverTime);
      if (Number.isFinite(serverAt)) offset = serverAt - (requestAt + now()) / 2;
      payload = acceptGoal(next, now() + offset);
      render();
    } catch { /* Keep the last real score visible through a brief network drop. */ }
    finally { clearTimeout(timeout); loading = false; }
  };
  void load();
  const poll = setInterval(load, 1_000);
  const clock = setInterval(render, 250);
  return () => { active = false; clearInterval(poll); clearInterval(clock); };
}

if (typeof document !== "undefined") {
  const root = document.getElementById("broadcast-scoreboard-root");
  if (root) startScoreboard(root);
}
