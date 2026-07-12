"use client";

import { useEffect, useMemo, useState } from "react";

type OverlayPayload = {
  fixtureId: string;
  fixtureStatus: string;
  home: OverlayClan;
  away: OverlayClan;
  homeScore: number;
  awayScore: number;
  clock: {
    status: string;
    started_at: string | null;
    accumulated_seconds: number;
    duration_seconds: number;
  };
};

type OverlayClan = {
  name: string;
  tag: string;
  emblem: string;
};

export default function OverlayClient({
  fixtureId,
}: {
  fixtureId: string;
}) {
  const [payload, setPayload] = useState<OverlayPayload | null>(null);
  const [now, setNow] = useState(Date.now());
  const [token, setToken] = useState("");

  useEffect(() => {
    const htmlBackground = document.documentElement.style.background;
    const bodyBackground = document.body.style.background;
    document.documentElement.style.background = "transparent";
    document.body.style.background = "transparent";
    return () => {
      document.documentElement.style.background = htmlBackground;
      document.body.style.background = bodyBackground;
    };
  }, []);

  useEffect(() => {
    const params = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    setToken(params.get("token") ?? "");
  }, []);

  useEffect(() => {
    if (!token) return;
    let active = true;

    async function load() {
      try {
        const response = await fetch(
          `/api/broadcast-overlay/${fixtureId}`,
          {
            headers: { authorization: `Bearer ${token}` },
            cache: "no-store",
          },
        );
        if (!response.ok) return;
        const next = (await response.json()) as OverlayPayload;
        if (active) setPayload(next);
      } catch {
        // Keep the most recent scoreboard visible through brief network drops.
      }
    }

    void load();
    const dataTimer = window.setInterval(load, 1_000);
    const clockTimer = window.setInterval(() => setNow(Date.now()), 250);
    return () => {
      active = false;
      window.clearInterval(dataTimer);
      window.clearInterval(clockTimer);
    };
  }, [fixtureId, token]);

  const elapsed = useMemo(() => elapsedSeconds(payload?.clock ?? null, now), [
    now,
    payload?.clock,
  ]);

  if (!payload) {
    return <div className="broadcast-overlay-root" aria-label="Loading overlay" />;
  }

  const matchRunning = payload.clock.status === "RUNNING";
  const matchEnded = payload.clock.status === "ENDED" ||
    payload.fixtureStatus === "FINAL";

  return (
    <div className="broadcast-overlay-root">
      <div className="overlay-live-badge">
        <span /> ON AIR
      </div>
      <div className="overlay-scoreboard">
        <OverlayTeam clan={payload.home} />
        <div className="overlay-score">
          <div className="overlay-score-values">
            <strong>{payload.homeScore}</strong>
            <span>:</span>
            <strong>{payload.awayScore}</strong>
          </div>
          <div className="overlay-clock">{formatClock(elapsed)}</div>
          <div className="overlay-clock-state">
            {matchEnded ? "FULL TIME" : matchRunning ? "LIVE" : "KICKOFF SOON"}
          </div>
        </div>
        <OverlayTeam clan={payload.away} alignEnd />
      </div>
    </div>
  );
}

function OverlayTeam({ clan, alignEnd = false }: { clan: OverlayClan; alignEnd?: boolean }) {
  return (
    <div className={`overlay-team ${alignEnd ? "end" : ""}`}>
      <div className="overlay-emblem">{clan.emblem}</div>
      <div className="overlay-team-copy">
        <div className="overlay-team-name">{clan.name}</div>
        <div className="overlay-team-tag">{clan.tag}</div>
      </div>
    </div>
  );
}

function elapsedSeconds(clock: OverlayPayload["clock"] | null, now: number) {
  if (!clock) return 0;
  const base = Math.max(0, Number(clock.accumulated_seconds ?? 0));
  if (clock.status !== "RUNNING" || !clock.started_at) return base;
  const delta = Math.max(0, Math.floor((now - new Date(clock.started_at).getTime()) / 1000));
  return Math.min(3 * 60 * 60, base + delta);
}

function formatClock(totalSeconds: number) {
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes.toString().padStart(2, "0")}:${seconds
    .toString()
    .padStart(2, "0")}`;
}
