"use client";

import { useRef, useState } from "react";
import type { RefereeFixture } from "@/lib/types";
import { assertSeasonZeroAcknowledgement, type SeasonZeroMatchState } from "@/lib/season-zero-actions";

type LifecycleRequest = { action: "finish" | "reopen"; expectedRevision: number; requestId: string };

/** Read the revision the referee confirms; retain the same request after an uncertain save. */
export function SeasonZeroLifecycleControls({ fixture, accessToken, submitting, onAction, onRefresh }: {
  fixture: RefereeFixture;
  accessToken: string;
  submitting: string | null;
  onAction: (body: LifecycleRequest) => Promise<boolean>;
  onRefresh: () => void;
}) {
  const [state, setState] = useState<SeasonZeroMatchState | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const request = useRef<LifecycleRequest | null>(null);
  const loadingRef = useRef(false);
  const savingRef = useRef(false);
  const reopening = fixture.status === "FINAL";
  const changed = state !== null && state.lifecycle !== (reopening ? "FINAL" : "LIVE");
  const canSave = state !== null && !changed && (!reopening || state.referee_can_reopen === true);
  const busy = submitting !== null || loading;

  async function load() {
    if (loadingRef.current || savingRef.current || submitting !== null) return;
    loadingRef.current = true;
    setLoading(true); setError(null); setState(null);
    try {
      const response = await fetch(`/api/referee/open-queue-games/${fixture.id}/participation`, {
        headers: { Authorization: `Bearer ${accessToken}` }, cache: "no-store",
        signal: AbortSignal.timeout(15_000),
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error ?? "Could not check the current match.");
      assertSeasonZeroAcknowledgement(payload.state, fixture.id);
      setState(payload.state);
      // A successful fresh read reconciles an earlier request with the saved
      // state. Until then, a retry keeps its original revision and request ID.
      request.current = null;
    } catch (failure) {
      setError(failure instanceof Error && failure.name !== "TimeoutError"
        ? failure.message : "Checking the match took too long. Refresh and try again.");
    } finally { loadingRef.current = false; setLoading(false); }
  }

  async function save() {
    if (!state || !canSave || busy || savingRef.current) return;
    const action = reopening ? "reopen" : "finish";
    if (!request.current) request.current = { action, expectedRevision: state.revision, requestId: crypto.randomUUID() };
    savingRef.current = true;
    try {
      if (await onAction(request.current)) request.current = null;
    } finally { savingRef.current = false; }
  }

  return <details className="timer-end-disclosure" onToggle={event => {
    if (event.currentTarget.open && !state && !error) void load();
  }}>
    <summary>{reopening ? "Reopen match" : "End match"}</summary>
    <div>
      <span>{reopening
        ? "Reopen with the saved score, players and playing time. The clock stays paused until you press Resume. Ratings are recalculated when you finish again."
        : "Save the current score and end the game now. If you finish before the agreed duration, the result will not award SR. You can reopen the match if play needs to continue."}</span>
      <span>{reopening ? "Reopening resumes the match only. An ended broadcast stays ended." : "If a broadcast is active, it will stop shortly after the match ends."}</span>
      {loading ? <span role="status">Checking the current match…</span> : null}
      {error ? <span role="alert">{error}</span> : null}
      {changed ? <>
        <span role="alert">This match changed. Refresh the match before continuing.</span>
        <button className="ghost-button" type="button" disabled={busy} onClick={onRefresh}>Refresh match</button>
      </> : reopening && state && !canSave ? <span>This result needs an organizer review before it can be reopened.</span> : null}
      <button className="danger-button" disabled={busy || !canSave} type="button" onClick={() => void save()}>
        {submitting === (reopening ? "reopen" : "finish") ? reopening ? "Reopening…" : "Finishing…" : reopening ? "Confirm reopen match" : "Finish match"}
      </button>
      <button className="ghost-button" disabled={busy} type="button" onClick={() => void load()}>Refresh match state</button>
    </div>
  </details>;
}
