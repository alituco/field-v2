"use client";

import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import type { RefereeFixture } from "@/lib/types";
import { buildReviewResolution, resolutionExplanations, resolutionLabels, reviewEventLabels, toEventDraft, type EventDraft, type ReviewDraft, type ReviewState } from "@/lib/season-zero-review-ui";
import styles from "./season-zero-operations.module.css";

export function SeasonZeroRatingReviewPanel({ fixture, accessToken, onSaved }: {
  fixture: RefereeFixture; accessToken: string; onSaved: () => void | Promise<void>;
}) {
  const [state, setState] = useState<ReviewState | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [draft, setDraft] = useState<ReviewDraft | null>(null);
  const [confirmed, setConfirmed] = useState(false);
  const [conflict, setConflict] = useState(false);
  const request = useRef<{ content: string; id: string } | null>(null);
  const endpoint = `/api/referee/admin/solo-games/${fixture.id}/rating-review`;
  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const response = await fetch(endpoint, { headers: { Authorization: `Bearer ${accessToken}` }, cache: "no-store" });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error ?? "Could not load rating review.");
      setState(payload.state); setConflict(false);
    } catch (failure) { setError(failure instanceof Error ? failure.message : "Could not load rating review."); }
    finally { setLoading(false); }
  }, [endpoint, accessToken]);
  useEffect(() => { void load(); }, [load]);

  function edit() {
    if (!state) return;
    setDraft({ status: Object.hasOwn(resolutionLabels, state.rating_status) ? state.rating_status : "pending_review",
      winner: state.winner ?? "", whiteScore: fixture.homeScore === null ? "" : String(fixture.homeScore),
      blackScore: fixture.awayScore === null ? "" : String(fixture.awayScore), reason: "", correctTimeline: false,
      playedSeconds: String(state.elapsed_seconds), events: state.events.map(toEventDraft) });
    setError(null); setNotice(null); setConfirmed(false); request.current = null;
  }
  function change(update: Partial<ReviewDraft>) {
    setDraft(current => current ? { ...current, ...update } : current); setConfirmed(false);
  }
  function changeEvent(index: number, update: Partial<EventDraft>) {
    if (!draft) return;
    change({ events: draft.events.map((event, i) => i === index ? { ...event, ...update } : event) });
  }
  function moveEvent(index: number, direction: number) {
    if (!draft || index + direction < 0 || index + direction >= draft.events.length) return;
    const events = [...draft.events];
    [events[index], events[index + direction]] = [events[index + direction], events[index]];
    change({ events });
  }
  async function save(event: FormEvent) {
    event.preventDefault();
    if (!state || !draft || saving || conflict || !confirmed) return;
    setError(null); setNotice(null);
    try {
      const resolution = buildReviewResolution(state, draft);
      const content = JSON.stringify({ expectedRevision: state.revision, resolution });
      if (request.current?.content !== content) request.current = { content, id: crypto.randomUUID() };
      setSaving(true);
      const response = await fetch(endpoint, { method: "POST", headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ ...JSON.parse(content), requestId: request.current.id }) });
      const payload = await response.json().catch(() => ({}));
      if (response.status === 409) setConflict(true);
      if (!response.ok) throw new Error(payload.error ?? "Could not save this rating review.");
      if (!payload.state || !Number.isInteger(payload.state.revision)) throw new Error("The review was not acknowledged. Retry this same request before making another change.");
      setState(payload.state); setDraft(null); setConfirmed(false); request.current = null;
      setNotice(`Review saved. The server replayed rating settlement and retained the previous evidence in the audit history. ${resolutionExplanations[draft.status]}`);
      await onSaved();
    } catch (failure) { setError(failure instanceof Error ? failure.message : "Could not save this rating review."); }
    finally { setSaving(false); }
  }
  const playerName = (id: string) => fixture.players.find(player => player.id === id)?.displayName ?? `Booked player ${id.slice(0, 8)}`;
  const settlement = state?.settlement_status ?? "UNSETTLED";
  const settlementLabel = settlement === "RATED" ? "Rated" : settlement === "NOT_RATED" ? "Not rated" : settlement === "HELD" ? "Held for review" : "Not settled";

  return <section className={styles.panel} aria-labelledby="season-zero-review-title">
    <header><div><span>SEASON 0 · AUDITED EVIDENCE</span><h2 id="season-zero-review-title">Rating review</h2></div>
      {!draft ? <button className={styles.secondary} disabled={loading || saving} type="button" onClick={() => void load()}>Refresh rating evidence</button> : null}</header>
    <p className={styles.hint}>Review the actual result and participation. This form creates a new evidence revision and server-side replay; it never sets a player’s SR or adds replacement players.</p>
    {loading ? <p role="status">Loading rating evidence…</p> : null}
    {!loading && !state && !error ? <p className={styles.hint}>No kickoff evidence exists yet. Before kickoff, use the ordinary cancellation and refund controls if needed.</p> : null}
    {state ? <>
      <dl className={styles.facts}><div><dt>Settlement</dt><dd>{settlementLabel}</dd></div><div><dt>Evidence revision</dt><dd>{state.revision}</dd></div><div><dt>Played clock</dt><dd>{state.elapsed_seconds} seconds</dd></div><div><dt>Outcome</dt><dd>{resolutionLabels[state.rating_status] ?? state.rating_status}</dd></div></dl>
      {state.adjudication_reason ? <p className={styles.hint}>Latest review reason: {state.adjudication_reason}</p> : null}
      <details><summary>Recorded participation · {state.observed_roster.length} booked players</summary><ul className={styles.audit}>{state.observed_roster.map(player => {
        const audit = state.audit?.players?.[player.id];
        return <li key={player.id}><strong>{playerName(player.id)}</strong> · {player.team === "A" ? "White" : "Black"} · {player.booked_role}<br />
          {audit ? `${audit.actual_seconds} seconds played · ${audit.final_state.replaceAll("_", " ").toLowerCase()}` : "Participation audit unavailable"}</li>;
      })}</ul></details>
      <details><summary>Recorded timeline · {state.events.length} events</summary><ol className={styles.audit}>{state.events.map(event => <li key={event.id}><strong>{reviewEventLabels[event.type] ?? event.type}</strong> · {event.second}s{event.player_id ? ` · ${playerName(event.player_id)}` : ""}<br /><time>{event.recorded_at}</time>{event.note ? <p>{event.note}</p> : null}</li>)}</ol></details>
      {!draft ? <div className={styles.actions}><button className={styles.primary} disabled={loading} type="button" onClick={edit}>Review outcome or correct evidence</button></div> : null}
    </> : null}
    {notice ? <p role="status" className={styles.notice}>{notice}</p> : null}
    {error ? <p role="alert" className={styles.error}>{error}</p> : null}
    {draft && state ? <form aria-label="Review Season 0 rating evidence" onSubmit={event => void save(event)}>
      {state.lifecycle === "LIVE" ? <p className={styles.notice}>Saving this review ends the current match clock. Choose “Keep under review” if the outcome is not yet verified.</p> : null}
      <label>Rating outcome<select aria-describedby="rating-outcome-explanation" disabled={saving || conflict} value={draft.status} onChange={event => change({ status: event.target.value })}>{Object.entries(resolutionLabels).map(([value, label]) => <option value={value} key={value} disabled={value === "cancelled" && state.lifecycle === "FINAL"}>{label}</option>)}</select></label>
      <p id="rating-outcome-explanation" className={styles.hint}>{resolutionExplanations[draft.status]}</p>
      {state.lifecycle === "FINAL" ? <p className={styles.notice}>A finalized game cannot be cancelled here. Use the existing manual refund review for payment decisions; rating-only changes do not automatically refund payments or change attendance.</p> : null}
      {draft.status === "completed" ? <div className={styles.fields}><label>White final score<input type="number" min={0} max={999} step={1} required disabled={saving || conflict} value={draft.whiteScore} onChange={event => change({ whiteScore: event.target.value })} /></label><label>Black final score<input type="number" min={0} max={999} step={1} required disabled={saving || conflict} value={draft.blackScore} onChange={event => change({ blackScore: event.target.value })} /></label></div> : null}
      {draft.status === "forfeit_confirmed" ? <label>Confirmed forfeit winner<select value={draft.winner} required disabled={saving || conflict} onChange={event => change({ winner: event.target.value })}><option value="">Choose the actual winner</option><option value="A">White team</option><option value="B">Black team</option></select><small>No fabricated forfeit score is added.</small></label> : null}
      <label className={styles.check}><input type="checkbox" checked={draft.correctTimeline} disabled={saving || conflict} onChange={event => change({ correctTimeline: event.target.checked })} />Correct participation timeline</label>
      {draft.correctTimeline ? <>
        <p className={styles.hint}>Correct actual clock seconds and UTC wall times. Keep chronological order, including equal-clock events. Pauses and blue-card time are validated by the server. Kickoff roster and booked roles stay immutable.</p>
        <label>Played clock seconds<input type="number" min={0} max={10800} step={1} required value={draft.playedSeconds} disabled={saving || conflict} onChange={event => change({ playedSeconds: event.target.value })} /></label>
        <div className={styles.eventList}>{draft.events.map((event, index) => <fieldset className={styles.event} key={event.id} disabled={saving || conflict}>
          <legend>Event {index + 1}</legend><div className={styles.fields}>
            <label>Event {index + 1} action<select value={event.type} onChange={changeTo => changeEvent(index, { type: changeTo.target.value, ...(["PAUSE", "RESUME"].includes(changeTo.target.value) ? { playerId: "" } : {}) })}>{Object.entries(reviewEventLabels).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></label>
            {!["PAUSE", "RESUME"].includes(event.type) ? <label>Event {index + 1} player<select required value={event.playerId} onChange={changeTo => changeEvent(index, { playerId: changeTo.target.value })}><option value="">Choose booked player</option>{state.observed_roster.map(player => <option value={player.id} key={player.id}>{playerName(player.id)} · {player.team === "A" ? "White" : "Black"}</option>)}</select></label> : null}
            <label>Event {index + 1} clock second<input type="number" min={0} max={10800} step={1} required value={event.second} onChange={changeTo => changeEvent(index, { second: changeTo.target.value })} /></label>
            <label>Event {index + 1} wall timestamp (UTC)<input type="datetime-local" step={1} required value={event.wallTime} onChange={changeTo => changeEvent(index, { wallTime: changeTo.target.value })} /></label>
          </div><label>Event {index + 1} note<input maxLength={500} value={event.note} onChange={changeTo => changeEvent(index, { note: changeTo.target.value })} /></label>
          <div className={styles.actions}><button className={styles.secondary} type="button" disabled={index === 0} onClick={() => moveEvent(index, -1)} aria-label={`Move event ${index + 1} earlier`}>↑ Earlier</button><button className={styles.secondary} type="button" disabled={index === draft.events.length - 1} onClick={() => moveEvent(index, 1)} aria-label={`Move event ${index + 1} later`}>↓ Later</button><button className={styles.secondary} type="button" onClick={() => change({ events: draft.events.filter((_, i) => i !== index) })}>Remove event {index + 1}</button></div>
        </fieldset>)}</div>
        <button className={styles.secondary} type="button" disabled={saving || conflict} onClick={() => change({ events: [...draft.events, { id: crypto.randomUUID(), type: "JOIN", playerId: "", second: draft.playedSeconds, wallTime: "", note: "" }] })}>Add participation or clock event</button>
      </> : null}
      <label>Evidence and reason for review<textarea required minLength={10} maxLength={2000} value={draft.reason} disabled={saving || conflict} onChange={event => change({ reason: event.target.value })} /><small>At least 10 characters. Explain what was verified and why the correction is warranted.</small></label>
      <label className={styles.check}><input type="checkbox" checked={confirmed} disabled={saving || conflict} onChange={event => setConfirmed(event.target.checked)} />I verified this evidence and understand this replays affected ratings.</label>
      {conflict ? <p className={styles.error}>Your draft is preserved, but another update changed the evidence. Cancel this edit and refresh before reviewing the latest revision.</p> : null}
      <footer><button className={styles.secondary} type="button" disabled={saving} onClick={() => { setDraft(null); setError(null); if (conflict) void load(); }}>Cancel review</button><button className={styles.primary} type="submit" disabled={saving || conflict || !confirmed || draft.reason.trim().length < 10 || (draft.status === "cancelled" && state.lifecycle === "FINAL")}>{saving ? "Saving review…" : "Save review and replay"}</button></footer>
    </form> : null}
  </section>;
}
