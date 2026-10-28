import { NextResponse } from "next/server";

type RouteContext = { params: Promise<{ fixtureId: string }> };

export async function GET(request: Request, context: RouteContext) {
  const { fixtureId } = await context.params;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(fixtureId)) {
    return new NextResponse("Invalid fixture.", { status: 404 });
  }
  const solo = new URL(request.url).searchParams.get("kind") === "solo";
  const apiBase = solo ? "/api/broadcast-overlay/open-queue/" : "/api/broadcast-overlay/";
  return new NextResponse(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <title>Fieldrush Scoreboard</title>
  <link rel="stylesheet" href="/broadcast-scoreboard.css">
</head>
<body>
  <main id="broadcast-scoreboard-root" class="broadcast-scoreboard-root" data-match-id="${fixtureId}" data-api-base="${apiBase}" aria-label="Match scoreboard">
    <section class="broadcast-scoreboard">
      <div class="broadcast-scoreboard-score">
        <div class="broadcast-scoreboard-team broadcast-scoreboard-home">
          <span class="broadcast-scoreboard-label" data-scoreboard="homeLabel"></span>
          <strong class="broadcast-scoreboard-value" data-scoreboard="homeScore">0</strong>
        </div>
        <div class="broadcast-scoreboard-team broadcast-scoreboard-away">
          <strong class="broadcast-scoreboard-value" data-scoreboard="awayScore">0</strong>
          <span class="broadcast-scoreboard-label" data-scoreboard="awayLabel"></span>
        </div>
      </div>
      <div class="broadcast-scoreboard-tab">
        <span class="broadcast-scoreboard-dot" aria-hidden="true"></span>
        <strong class="broadcast-scoreboard-clock" data-scoreboard="clockText"></strong>
        <span class="broadcast-scoreboard-state" data-scoreboard="statusText"></span>
      </div>
    </section>
  </main>
  <script type="module" src="/broadcast-scoreboard.mjs"></script>
</body>
</html>`, {
    headers: { "Cache-Control": "no-store", "Content-Type": "text/html; charset=utf-8" },
  });
}
