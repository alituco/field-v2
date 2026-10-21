"use client";

import { useEffect, useState } from "react";
import type { RefereeFixture } from "@/lib/types";
import type { SeasonZeroMatchState } from "@/lib/season-zero-actions";
import { soloMinimumHint } from "@/lib/solo-game-readiness";

const labels: Record<string, string> = {
  JOIN: "Join play", EXCUSED_LEAVE: "Injury / excused leave", RETURN: "Return from injury",
  QUIT: "Intentional abandonment", RED_CARD: "Permanent send-off", BLUE_CARD: "Blue card · 2 minutes",
  BLUE_RETURN: "Confirm actual return",
};

export function SeasonZeroParticipationPanel({ fixture, accessToken, submitting, onAction }: {
  fixture: RefereeFixture; accessToken: string; submitting: string | null;
  onAction: (body: Record<string, string | number>) => Promise<boolean>;
}) {
  const [state, setState] = useState<SeasonZeroMatchState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [choice, setChoice] = useState<{ playerId: string; action: string } | null>(null);
  const [note, setNote] = useState("");
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    let disposed = false;
    async function load() {
      try {
        const response = await fetch(`/api/referee/open-queue-games/${fixture.id}/participation`, {
          headers: { Authorization: `Bearer ${accessToken}` },
        });
        const payload = await response.json();
        if (!response.ok) throw new Error(payload.error ?? "Could not load playing time.");
        if (!disposed) { setState(payload.state); setError(null); }
      } catch (failure) {
        if (!disposed) setError(failure instanceof Error ? failure.message : "Could not load playing time.");
      }
    }
    void load();
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => { disposed = true; window.clearInterval(timer); };
  }, [fixture, accessToken, submitting]);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!choice || !state) return;
    const ok = await onAction({ action: "participation", participationAction: choice.action,
      profileId: choice.playerId, note, expectedRevision: state.revision, requestId: crypto.randomUUID() });
    if (ok) { setChoice(null); setNote(""); }
  }

  return <section className="panel season-zero-participation">
    <div className="panel-heading"><div><span className="match-action-kicker">Season 0 rating policy</span>
      <h2 className="panel-title">Playing time</h2></div></div>
    <p className="timer-start-note">Record actual entries and departures. Pauses do not count as playing time. No replacements or rotations.</p>
    <p className="timer-start-note">{soloMinimumHint(fixture)}</p>
    {error ? <p role="alert" className="error-message">{error}</p> : null}
    {!state && !error ? <p>{fixture.status === "LIVE" ? "Loading playing time…" : "Confirm the checked-in starting players at kickoff."}</p> : null}
    {state ? <>
      <p className="timer-start-note">{state.lifecycle === "LIVE" ? "Live participation" : state.rating_status === "pending_review"
        ? "Ratings held for organizer review" : `Rating outcome: ${state.rating_status.replaceAll("_", " ")}`}</p>
      <div className="season-zero-player-list">{state.observed_roster.map(player => {
        const data = state.audit.players[player.id];
        const display = fixture.players.find(p => p.id === player.id);
        const playerState = data?.final_state ?? "NOT_ENTERED";
        const blue = [...state.events].reverse().find(e => e.player_id === player.id && e.type === "BLUE_CARD");
        const remaining = blue ? Math.max(0, Math.ceil((Date.parse(blue.recorded_at) + 120_000 - now) / 1000)) : 0;
        const actions = playerState === "ACTIVE" ? ["EXCUSED_LEAVE", "BLUE_CARD", "RED_CARD", "QUIT"]
          : playerState === "EXCUSED" ? ["RETURN"] : playerState === "BLUE_CARD" ? ["BLUE_RETURN"]
          : playerState === "NOT_ENTERED" ? ["JOIN"] : [];
        return <div key={player.id} className="season-zero-player-row">
          <div><strong>{display?.displayName ?? "Booked player"}</strong>
            <small>{player.team === "A" ? "White" : "Black"} · {player.booked_role} · {Math.floor((data?.actual_seconds ?? 0) / 60)} min recorded
              {playerState !== "ACTIVE" ? ` · ${playerState.replaceAll("_", " ").toLowerCase()}` : ""}</small></div>
          {state.lifecycle === "LIVE" && fixture.operationalState === "NORMAL" ? <div className="season-zero-player-actions">
            {actions.map(action => <button className="ghost-button compact-button" type="button" key={action}
              disabled={submitting !== null || (action === "BLUE_RETURN" && remaining > 0)}
              onClick={() => { setChoice({ playerId: player.id, action }); setNote(""); }}>
              {action === "BLUE_RETURN" && remaining > 0 ? `Return eligible in ${remaining}s` : labels[action]}</button>)}
          </div> : null}
        </div>;
      })}</div>
      {choice ? <form className="season-zero-confirm" onSubmit={submit}>
        <h3>{labels[choice.action]} — {fixture.players.find(p => p.id === choice.playerId)?.displayName}</h3>
        <p>Confirm this is what happened on the pitch. The server records the match time and your identity.</p>
        {choice.action === "BLUE_RETURN" ? <p>The timer ending only permits return; confirm the player has actually rejoined.</p> : null}
        <label>Reason / note<textarea value={note} onChange={event => setNote(event.target.value)} maxLength={500}
          required={["EXCUSED_LEAVE", "QUIT", "RED_CARD"].includes(choice.action)} minLength={3} /></label>
        <div className="season-zero-player-actions"><button type="button" className="ghost-button" onClick={() => setChoice(null)}>Cancel</button>
          <button type="submit" className="primary-button" disabled={submitting !== null}>Confirm {labels[choice.action].toLowerCase()}</button></div>
      </form> : null}
    </> : null}
  </section>;
}
