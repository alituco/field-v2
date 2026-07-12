import { NextResponse } from "next/server";

type RouteContext = {
  params: Promise<{ fixtureId: string }>;
};

export async function GET(_request: Request, context: RouteContext) {
  const { fixtureId } = await context.params;
  if (!isUuid(fixtureId)) {
    return new NextResponse("Invalid fixture.", { status: 404 });
  }

  return new NextResponse(overlayHtml(fixtureId), {
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "text/html; charset=utf-8",
    },
  });
}

function overlayHtml(fixtureId: string) {
  const serializedFixtureId = JSON.stringify(fixtureId);
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Field Scoreboard</title>
  <style>
    * { box-sizing: border-box; }
    html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; background: transparent !important; }
    body { color: #fff; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    #root { position: fixed; inset: 0; visibility: hidden; }
    #root.ready { visibility: visible; }
    .live-badge { position: absolute; top: 56px; right: 64px; display: flex; align-items: center; gap: 12px; border: 1px solid rgba(255,255,255,.28); border-radius: 999px; padding: 13px 22px; background: rgba(8,15,27,.82); font-size: 20px; font-weight: 900; }
    .live-dot { width: 12px; height: 12px; border-radius: 50%; background: #ef4444; box-shadow: 0 0 0 7px rgba(239,68,68,.2); }
    .scoreboard { position: absolute; right: 50%; bottom: 50px; display: grid; grid-template-columns: minmax(0,1fr) 310px minmax(0,1fr); align-items: center; width: min(1580px,calc(100vw - 96px)); min-height: 164px; overflow: hidden; border: 1px solid rgba(255,255,255,.24); border-radius: 22px; background: rgba(8,15,27,.9); box-shadow: 0 18px 60px rgba(0,0,0,.42); transform: translateX(50%); }
    .team { display: flex; align-items: center; gap: 22px; min-width: 0; padding: 28px 40px; }
    .team.away { flex-direction: row-reverse; text-align: right; }
    .emblem { display: grid; flex: 0 0 84px; width: 84px; height: 84px; place-items: center; border: 1px solid rgba(255,255,255,.2); border-radius: 18px; background: rgba(255,255,255,.1); font-size: 48px; }
    .team-copy { min-width: 0; }
    .team-name { overflow: hidden; font-size: 34px; font-weight: 900; text-overflow: ellipsis; white-space: nowrap; }
    .team-tag { margin-top: 7px; color: rgba(255,255,255,.62); font-size: 18px; font-weight: 800; }
    .score { align-self: stretch; display: flex; flex-direction: column; align-items: center; justify-content: center; border-right: 1px solid rgba(255,255,255,.14); border-left: 1px solid rgba(255,255,255,.14); background: rgba(255,255,255,.06); }
    .score-values { display: flex; align-items: center; gap: 18px; font-size: 54px; line-height: 1; }
    .score-values .separator { color: rgba(255,255,255,.38); }
    .clock { margin-top: 12px; font-size: 25px; font-variant-numeric: tabular-nums; font-weight: 900; }
    .clock-state { margin-top: 4px; color: #6ee7b7; font-size: 13px; font-weight: 900; }
  </style>
</head>
<body>
  <main id="root">
    <div class="live-badge"><span class="live-dot"></span>ON AIR</div>
    <section class="scoreboard">
      <div class="team">
        <div class="emblem" id="home-emblem"></div>
        <div class="team-copy"><div class="team-name" id="home-name"></div><div class="team-tag" id="home-tag"></div></div>
      </div>
      <div class="score">
        <div class="score-values"><strong id="home-score">0</strong><span class="separator">:</span><strong id="away-score">0</strong></div>
        <div class="clock" id="clock">00:00</div>
        <div class="clock-state" id="clock-state">KICKOFF SOON</div>
      </div>
      <div class="team away">
        <div class="emblem" id="away-emblem"></div>
        <div class="team-copy"><div class="team-name" id="away-name"></div><div class="team-tag" id="away-tag"></div></div>
      </div>
    </section>
  </main>
  <script>
    (() => {
      const fixtureId = ${serializedFixtureId};
      const token = new URLSearchParams(location.hash.replace(/^#/, "")).get("token") || "";
      const root = document.getElementById("root");
      let payload = null;

      const setText = (id, value) => { document.getElementById(id).textContent = String(value ?? ""); };
      const elapsedSeconds = () => {
        if (!payload) return 0;
        const clock = payload.clock || {};
        const base = Math.max(0, Number(clock.accumulated_seconds || 0));
        if (clock.status !== "RUNNING" || !clock.started_at) return base;
        return Math.min(10800, base + Math.max(0, Math.floor((Date.now() - Date.parse(clock.started_at)) / 1000)));
      };
      const renderClock = () => {
        if (!payload) return;
        const elapsed = elapsedSeconds();
        setText("clock", String(Math.floor(elapsed / 60)).padStart(2, "0") + ":" + String(elapsed % 60).padStart(2, "0"));
      };
      const render = () => {
        setText("home-emblem", payload.home.emblem);
        setText("home-name", payload.home.name);
        setText("home-tag", payload.home.tag);
        setText("away-emblem", payload.away.emblem);
        setText("away-name", payload.away.name);
        setText("away-tag", payload.away.tag);
        setText("home-score", payload.homeScore);
        setText("away-score", payload.awayScore);
        const ended = payload.clock.status === "ENDED" || payload.fixtureStatus === "FINAL";
        setText("clock-state", ended ? "FULL TIME" : payload.clock.status === "RUNNING" ? "LIVE" : "KICKOFF SOON");
        renderClock();
        root.classList.add("ready");
      };
      const load = async () => {
        if (!token) return;
        try {
          const response = await fetch("/api/broadcast-overlay/" + fixtureId, { headers: { authorization: "Bearer " + token }, cache: "no-store" });
          if (!response.ok) return;
          payload = await response.json();
          render();
        } catch (_) {}
      };
      load();
      setInterval(load, 1000);
      setInterval(renderClock, 250);
    })();
  </script>
</body>
</html>`;
}

function isUuid(value: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
