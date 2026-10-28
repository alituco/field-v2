"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { RefereeFixture } from "@/lib/types";
import { assertMatchRecordState, assertMatchRecordResult, type MatchRecordResult, type MatchRecordState, type MatchRecordRequest } from "@/lib/solo-match-record";
import { automaticFinishRecordEventId, arrivalNeedsReason, buildMatchRecord, clockText, createRecordDraft, matchRecordEventLabels, recordOutcomeLabel, recordEventClockText, type ArrivalDraft, type RecordDraft } from "@/lib/solo-match-record-ui";
import styles from "./season-zero-operations.module.css";

export function SoloMatchRecordPanel({ fixture, accessToken, onSaved, mode = "arrivals" }: {
  fixture: RefereeFixture; accessToken: string; onSaved: () => void | Promise<void>; mode?: "arrivals" | "correction";
}) {
  const [state, setState] = useState<MatchRecordState | null>(null);
  const [draft, setDraft] = useState<RecordDraft | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [preview, setPreview] = useState<MatchRecordResult | null>(null);
  const [conflict, setConflict] = useState(false);
  const [uncertain, setUncertain] = useState(false);
  const request = useRef<{ content: string; id: string; revision: number } | null>(null);
  const pendingSave = useRef<MatchRecordRequest | null>(null);
  const activeCall = useRef(false);
  const loadSequence = useRef(0);
  const endpoint = `/api/referee/open-queue-games/${fixture.id}/record`;
  const load = useCallback(async () => {
    const sequence = ++loadSequence.current;
    setLoading(true); setError(null);
    try {
      const response = await fetch(endpoint, { headers: { Authorization: `Bearer ${accessToken}` }, cache: "no-store", signal: AbortSignal.timeout(15_000) });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error ?? "Could not load the match record.");
      const next = payload.state;
      assertMatchRecordState(next, fixture.id);
      if (sequence === loadSequence.current) { setState(next); setConflict(false); }
    } catch (failure) {
      if (sequence === loadSequence.current) setError(failure instanceof Error && failure.name !== "TimeoutError" ? failure.message : "Loading took too long. Your current screen is preserved; try again.");
    } finally { if (sequence === loadSequence.current) setLoading(false); }
  }, [endpoint, accessToken, fixture.id]);
  useEffect(() => { void load(); return () => { loadSequence.current++; }; }, [load]);

  const name = (profileId: string) => fixture.players.find(player => player.id === profileId)?.displayName ?? "Booked player";
  const timezone = fixture.timezone ?? "America/Phoenix";
  const formatTime = (value: string | null) => value ? new Intl.DateTimeFormat("en-US", { timeZone: timezone, hour: "numeric", minute: "2-digit" }).format(new Date(value)) : "Not arrived";
  const editable = state?.can_correct_record === true;
  const disabled = busy || conflict || uncertain;
  function edit(profileId: string | null) {
    if (!state || !editable) return;
    setDraft(createRecordDraft(state, profileId)); setError(null); setNotice(null); setPreview(null); setConflict(false); setUncertain(false);
    request.current = null; pendingSave.current = null;
  }
  function change(update: Partial<RecordDraft>) {
    setDraft(current => current ? { ...current, ...update } : current); setPreview(null); request.current = null;
  }
  function changeArrival(profileId: string, update: Partial<ArrivalDraft>) {
    if (draft) change({ arrivals: draft.arrivals.map(arrival => arrival.profileId === profileId ? { ...arrival, ...update } : arrival) });
  }
  async function submit(previewOnly: boolean, retry = false) {
    if (!state || !draft || activeCall.current || (conflict && !retry)) return;
    let body: MatchRecordRequest;
    try {
      if (retry && pendingSave.current) body = pendingSave.current;
      else if (!previewOnly && preview && request.current) {
        body = { expectedRevision: request.current.revision, requestId: request.current.id, record: preview.record_input,
          preview: false, previewToken: preview.preview_token };
      } else {
        const record = buildMatchRecord(state, draft);
        const content = JSON.stringify({ record, expectedRevision: state.revision });
        if (request.current?.content !== content) request.current = { content, id: crypto.randomUUID(), revision: state.revision };
        body = { record, expectedRevision: request.current.revision, requestId: request.current.id, preview: previewOnly };
      }
    } catch (failure) { setError(failure instanceof Error ? failure.message : "Check the correction."); return; }
    activeCall.current = true; setBusy(true); setError(null); setNotice(null);
    if (!previewOnly) pendingSave.current = body;
    let responseReceived = false;
    try {
      const response = await fetch(endpoint, { method: "POST", headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify(body), signal: AbortSignal.timeout(15_000) });
      const payload = await response.json();
      responseReceived = response.status < 500;
      if (response.status === 409) { setConflict(true); setPreview(null); }
      if (!response.ok) throw new Error(payload.error ?? "Could not save this match record.");
      responseReceived = false;
      assertMatchRecordResult(payload, fixture.id, previewOnly);
      responseReceived = true;
      if (previewOnly) setPreview(payload);
      else {
        setState(payload.state); setDraft(null); setPreview(null); setUncertain(false);
        pendingSave.current = null; request.current = null;
        setNotice("Saved. Attendance, playing time and affected ratings are updated together.");
        try { await onSaved(); } catch { setNotice("The change was saved. Refresh the match to update the other panels."); }
      }
    } catch (failure) {
      if (!previewOnly) setUncertain(!responseReceived);
      setError(failure instanceof Error && !["TimeoutError", "AbortError"].includes(failure.name) ? failure.message
        : previewOnly ? "The preview could not be confirmed. Your draft is preserved; try again."
          : "The server has not confirmed this save. Retry the same change to check its result.");
    } finally { activeCall.current = false; setBusy(false); }
  }
  const needsReason = state && draft ? arrivalNeedsReason(state, draft) : false;
  const previewNeeded = needsReason || state?.lifecycle === "FINAL";
  const changedPlayers = preview?.impact.players.filter(player => JSON.stringify(player.before) !== JSON.stringify(player.after)) ?? [];
  const changedAccess = preview?.impact.attendance.flatMap(attendance => attendance.changed && attendance.before && attendance.after &&
    (attendance.before.active_strikes !== attendance.after.active_strikes || attendance.before.can_book !== attendance.after.can_book)
    ? [{ profileId: attendance.profile_id, before: attendance.before, after: attendance.after }] : []) ?? [];

  return <section className={styles.panel} aria-label={mode === "arrivals" ? "Player arrivals" : "Correct match record"}>
    <header><div><span>{mode === "arrivals" ? "PLAYERS" : "MATCH RECORD"}</span><h2>{mode === "arrivals" ? "Player arrivals" : "Correct match record"}</h2></div>
      {!draft ? <button className={styles.secondary} disabled={loading || busy} type="button" onClick={() => void load()}>Refresh</button> : null}</header>
    <p className={styles.hint}>{mode === "arrivals" ? "Arrival also records entry into play. Late players can join until the game ends. Missing players become no-shows at full time."
      : "Correct a missed arrival, goal, card or timing mistake. A finished game stays finished; use Reopen match only when play is continuing."}</p>
    {loading ? <p role="status">Loading match record…</p> : null}
    {state && !editable ? <p className={styles.notice}>This match needs organizer review before its record can be changed.</p> : null}
    {state && !draft && mode === "arrivals" ? <div className={styles.playerList}>{state.observed_roster.map(player => {
      const arrival = state.arrivals.find(row => row.profile_id === player.id);
      const attendance = arrival?.attendance_outcome;
      const participation = state.audit?.players?.[player.id];
      return <div className={styles.playerRow} key={player.id}><div><strong>{name(player.id)}</strong>
        <small>{player.team === "A" ? "White" : "Black"} · {arrival?.arrived_at ? `Arrived ${formatTime(arrival.arrived_at)}` : state.lifecycle === "FINAL" ? "No-show" : "Not arrived"}
          {attendance === "LATE" ? " · late" : ""}{participation ? ` · ${clockText(participation.actual_seconds)} played` : ""}</small></div>
        <button className={styles.secondary} disabled={!editable || loading} type="button" onClick={() => edit(player.id)}>{arrival?.arrived_at || state.lifecycle === "FINAL" ? "Correct arrival" : "Record arrival"}</button></div>;
    })}</div> : null}
    {state && !draft && mode === "correction" ? <div className={styles.actions}><button className={styles.primary} disabled={!editable || loading} type="button" onClick={() => edit(null)}>Correct match record</button></div> : null}
    {state?.record_revisions?.some(revision => revision.reason) ? <details><summary>Correction history</summary><ol className={styles.audit}>{state.record_revisions.filter(revision => revision.reason).map(revision =>
      <li key={revision.revision}><strong>{revision.reason}</strong><br />Revision {revision.revision} · {new Intl.DateTimeFormat("en-US", { timeZone: timezone, dateStyle: "medium", timeStyle: "short" }).format(new Date(revision.recorded_at))} · staff {revision.actor_id.slice(0, 8)}</li>)}</ol></details> : null}
    {notice ? <p className={styles.notice} role="status">{notice}</p> : null}
    {error ? <p className={styles.error} role="alert">{error}</p> : null}
    {draft && state ? <form onSubmit={event => { event.preventDefault(); void submit(previewNeeded && !preview); }}>
      <h3>{draft.profileId ? name(draft.profileId) : "Correct the facts recorded for this game"}</h3>
      <fieldset disabled={disabled} className={styles.event}><legend>{draft.profileId ? "Arrival / joined play" : "Arrivals"}</legend>
        {draft.arrivals.filter(arrival => !draft.profileId || arrival.profileId === draft.profileId).map(arrival => <div className={styles.event} key={arrival.profileId}>
          {!draft.profileId ? <label className={styles.check}><input type="checkbox" checked={arrival.change} onChange={event => changeArrival(arrival.profileId, { change: event.target.checked })} />Correct {name(arrival.profileId)}’s arrival</label> : null}
          {arrival.change ? <>
            <label>When did they arrive?<select value={arrival.mode} onChange={event => changeArrival(arrival.profileId, { mode: event.target.value as ArrivalDraft["mode"] })}>
              {state.lifecycle === "LIVE" ? <option value="NOW">Arrived now</option> : null}<option value="AT">Record when they arrived</option><option value="ABSENT">Did not arrive</option></select></label>
            {arrival.mode === "AT" ? <label>Minutes after actual kickoff<input type="number" step="0.01" min={-1440} required value={arrival.minutes} onChange={event => changeArrival(arrival.profileId, { minutes: event.target.value })} />
              <small>Actual kickoff: {formatTime(state.started_at)}. Use 30 for 30 minutes after kickoff, or −15 for 15 minutes before. Pauses are handled automatically.</small></label> : null}
            {arrival.mode === "ABSENT" ? <p className={styles.hint}>This removes their recorded arrival and entry into play. Remove any incorrectly recorded departures or cards in the full match correction too.</p> : null}
          </> : null}
        </div>)}
      </fieldset>
      {!draft.profileId ? <>
        <label className={styles.check}><input disabled={disabled} type="checkbox" checked={draft.correctGoals} onChange={event => change({ correctGoals: event.target.checked })} />Correct goals and score</label>
        {draft.correctGoals ? <fieldset className={styles.event} disabled={disabled}><legend>Recorded goals</legend><p className={styles.hint}>The score comes from this list. Add a missed goal or remove an incorrect one.</p>
          {draft.goals.map((goal, index) => <div className={styles.event} key={goal.key}><div className={styles.fields}>
            <label>Goal {index + 1} team<select value={goal.team} onChange={event => change({ goals: draft.goals.map((row, i) => i === index ? { ...row, team: event.target.value as "WHITE" | "BLACK", playerId: "", assistId: "" } : row) })}><option value="WHITE">White</option><option value="BLACK">Black</option></select></label>
            <label>Scorer<select required value={goal.playerId} onChange={event => change({ goals: draft.goals.map((row, i) => i === index ? { ...row, playerId: event.target.value, assistId: row.assistId === event.target.value ? "" : row.assistId } : row) })}><option value="">Choose scorer</option>{state.observed_roster.filter(player => player.team === (goal.team === "WHITE" ? "A" : "B")).map(player => <option key={player.id} value={player.id}>{name(player.id)}</option>)}</select></label>
            <label>Assist<select value={goal.assistId} onChange={event => change({ goals: draft.goals.map((row, i) => i === index ? { ...row, assistId: event.target.value } : row) })}><option value="">No assist</option>{state.observed_roster.filter(player => player.team === (goal.team === "WHITE" ? "A" : "B") && player.id !== goal.playerId).map(player => <option key={player.id} value={player.id}>{name(player.id)}</option>)}</select></label>
            <label>Match time (minutes:seconds)<input required inputMode="numeric" placeholder="30:00" value={goal.clock} onChange={event => change({ goals: draft.goals.map((row, i) => i === index ? { ...row, clock: event.target.value } : row) })} /></label>
          </div><button className={styles.secondary} type="button" onClick={() => change({ goals: draft.goals.filter((_, i) => i !== index) })}>Remove goal {index + 1}</button></div>)}
          <button className={styles.secondary} type="button" onClick={() => change({ goals: [...draft.goals, { key: crypto.randomUUID(), team: "WHITE", playerId: "", assistId: "", clock: "0:00" }] })}>Add missed goal</button>
        </fieldset> : null}
        <label className={styles.check}><input disabled={disabled} type="checkbox" checked={draft.correctTimeline} onChange={event => change({ correctTimeline: event.target.checked })} />Correct playing time, departures or cards</label>
        {draft.correctTimeline ? <fieldset className={styles.event} disabled={disabled}><legend>Playing time</legend>
          {state.lifecycle === "FINAL" ? <label>Actual playing duration (minutes:seconds)<input required placeholder="60:00" value={draft.clock} onChange={event => change({ clock: event.target.value })} />
            <small>Exclude pauses. Correcting this duration also corrects the recorded finish time. The game stays finished.</small></label>
            : <label>Played clock at last refresh<output>{clockText(state.elapsed_seconds)}</output><small>Calculated from actual pause and resume times. The server updates the current total when you save.</small></label>}
          <p className={styles.hint}>Enter when each event actually happened, in minutes after kickoff. The match minute is calculated from the pause and resume history. Arrival entries are updated from the arrival controls above.</p>
          {draft.events.map((item, index) => <div className={styles.event} key={item.id}>
            {item.id === automaticFinishRecordEventId(state, draft.events) ? <p className={styles.hint}>The final whistle is calculated from the actual playing duration above.</p>
              : item.type === "JOIN" ? <p className={styles.hint}>{name(item.playerId)} · arrival / joined play at match time {recordEventClockText(state, draft.events, item)}. Correct this using their arrival above.</p> : <>
              <div className={styles.fields}><label>Event {index + 1}<select value={item.type} onChange={event => change({ events: draft.events.map((row, i) => i === index ? { ...row, type: event.target.value, playerId: ["PAUSE", "RESUME"].includes(event.target.value) ? "" : row.playerId } : row) })}>{Object.entries(matchRecordEventLabels).filter(([type]) => type !== "JOIN").map(([type, label]) => <option value={type} key={type}>{label}</option>)}</select></label>
              {!["PAUSE", "RESUME"].includes(item.type) ? <label>Player<select required value={item.playerId} onChange={event => change({ events: draft.events.map((row, i) => i === index ? { ...row, playerId: event.target.value } : row) })}><option value="">Choose player</option>{state.observed_roster.map(player => <option key={player.id} value={player.id}>{name(player.id)}</option>)}</select></label> : null}
              <label>Minutes after actual kickoff<input type="number" min={0} step="0.01" required value={item.wallMinutes} onChange={event => change({ events: draft.events.map((row, i) => i === index ? { ...row, wallMinutes: event.target.value } : row) })} /></label>
              <label>Calculated match time<output aria-label={`Event ${index + 1} calculated match time`}>{recordEventClockText(state, draft.events, item)}</output><small>Calculated automatically; pauses do not count.</small></label></div>
              <label>Event note<input maxLength={500} value={item.note} onChange={event => change({ events: draft.events.map((row, i) => i === index ? { ...row, note: event.target.value } : row) })} /></label>
              <div className={styles.actions}><button className={styles.secondary} type="button" disabled={index === 0} onClick={() => { const events = [...draft.events]; [events[index - 1], events[index]] = [events[index], events[index - 1]]; change({ events }); }}>Move earlier</button>
              <button className={styles.secondary} type="button" disabled={index === draft.events.length - 1} onClick={() => { const events = [...draft.events]; [events[index + 1], events[index]] = [events[index], events[index + 1]]; change({ events }); }}>Move later</button>
              <button className={styles.secondary} type="button" onClick={() => change({ events: draft.events.filter((_, i) => i !== index) })}>Remove event</button></div>
            </>}
          </div>)}
          <button className={styles.secondary} type="button" onClick={() => change({ events: [...draft.events, { id: crypto.randomUUID(), type: "EXCUSED_LEAVE", playerId: "", clock: draft.clock, wallMinutes: "", note: "" }] })}>Add missed departure, return or clock event</button>
        </fieldset> : null}
      </> : null}
      {needsReason ? <label>Reason for correction<textarea required minLength={10} maxLength={2000} disabled={disabled} value={draft.reason} onChange={event => change({ reason: event.target.value })} /><small>Explain what happened and what was recorded incorrectly.</small></label> : null}
      {preview ? <div className={styles.notice} role="status"><h3>Review this correction</h3>
        <p>Score: White {preview.state.white_score ?? 0}–{preview.state.black_score ?? 0} Black. {state.lifecycle === "FINAL" ? "The game will stay finished." : "The game will remain live."}</p>
        {changedPlayers.length ? <ul className={styles.audit}>{changedPlayers.map(player => <li key={`${player.profile_id}-${player.rating_track ?? ""}`}><strong>{player.display_name ?? name(player.profile_id)}</strong>{player.rating_track ? ` · ${recordOutcomeLabel(player.rating_track)}` : ""}<br />
          {player.before.sr !== player.after.sr ? <>SR {player.before.sr ?? "—"} → {player.after.sr ?? "—"}. </> : null}
          {player.before.game_sr_delta !== player.after.game_sr_delta ? <>This game’s SR change {player.before.game_sr_delta ?? "—"} → {player.after.game_sr_delta ?? "—"}. </> : null}
          {player.before.arrived_at !== player.after.arrived_at ? <>Arrival {formatTime(player.before.arrived_at ?? null)} → {formatTime(player.after.arrived_at ?? null)}. </> : null}
          {player.before.matches !== player.after.matches ? <>Counted games {player.before.matches ?? 0} → {player.after.matches ?? 0}. </> : null}
          {player.before.attendance_outcome !== player.after.attendance_outcome ? <>Attendance {recordOutcomeLabel(player.before.attendance_outcome)} → {recordOutcomeLabel(player.after.attendance_outcome)}. </> : null}
          {player.before.strikes !== player.after.strikes ? <>This game’s strikes {player.before.strikes ?? 0} → {player.after.strikes ?? 0}.</> : null}
        </li>)}</ul> : <p>No published SR or strike changes.</p>}
        {changedAccess.map(attendance => <p key={attendance.profileId}><strong>{name(attendance.profileId)}:</strong>{" "}
          {attendance.before.active_strikes !== attendance.after.active_strikes ? <>Total active strikes {attendance.before.active_strikes} → {attendance.after.active_strikes}. </> : null}
          {attendance.before.can_book !== attendance.after.can_book
            ? attendance.after.can_book ? "Can book games again." : "Booking will be restricted."
            : attendance.after.can_book ? "Can still book games." : "Booking remains restricted."}</p>)}
        {state.lifecycle === "FINAL" && state.ended_at !== preview.state.ended_at ? <p>Corrected finish time: {formatTime(preview.state.ended_at)}. The game stays finished.</p> : null}
        {(preview.impact.dependent_matches_changed ?? 0) > 0 ? <p>{preview.impact.dependent_matches_changed} later match ratings will also be updated.</p> : null}
        <p>Save once to apply the correction and keep an audit record.</p>
      </div> : null}
      {conflict ? <p className={styles.error}>Another action changed this match. Your draft is preserved. Refresh the latest record, review the draft again, then preview it before saving.</p> : null}
      {uncertain ? <p className={styles.error}>The save may have completed. Retry this same save before editing anything else.</p> : null}
      <footer>
        <button className={styles.secondary} type="button" disabled={busy || uncertain} onClick={() => { setDraft(null); setPreview(null); setError(null); if (conflict) void load(); }}>Cancel</button>
        {conflict ? <button className={styles.secondary} type="button" disabled={busy} onClick={() => { setPreview(null); request.current = null; void load(); }}>Refresh and keep draft</button>
          : uncertain ? <button className={styles.primary} type="button" disabled={busy} onClick={() => void submit(false, true)}>{busy ? "Checking save…" : "Retry same save"}</button>
          : <button className={styles.primary} type="submit" disabled={busy || loading || !editable}>{busy ? "Checking…" : preview ? "Save correction" : previewNeeded ? "Review correction" : "Record arrival"}</button>}
      </footer>
    </form> : null}
  </section>;
}
