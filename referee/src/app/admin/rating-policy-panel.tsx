"use client";

import { useEffect, useState, type FormEvent } from "react";
import { LoadingSkeleton } from "@/components/loading-skeleton";
import styles from "./seasons-panel.module.css";

type Policy = { enabled: boolean; changed_at: string; changed_by: string | null };

export function RatingPolicyPanel({ accessToken }: { accessToken: string }) {
  const [policy, setPolicy] = useState<Policy | null>(null);
  const [editing, setEditing] = useState(false);
  const [reason, setReason] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  async function request(init?: RequestInit) {
    const response = await fetch("/api/referee/admin/rating-policy", { ...init, cache: "no-store",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` } });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error ?? "Could not load rating policy.");
    if (typeof payload.policy?.enabled !== "boolean") throw new Error("The rating-policy response was invalid.");
    return payload.policy as Policy;
  }
  useEffect(() => {
    let disposed = false;
    void request().then(value => { if (!disposed) setPolicy(value); })
      .catch(cause => { if (!disposed) setError(cause instanceof Error ? cause.message : "Could not load rating policy."); });
    return () => { disposed = true; };
    // The request depends only on the authenticated token.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [accessToken]);
  async function submit(event: FormEvent) {
    event.preventDefault(); if (!policy || saving || !confirmed) return;
    setSaving(true); setError(null); setNotice(null);
    try {
      const next = await request({ method: "POST", body: JSON.stringify({ enabled: !policy.enabled, confirmed, reason }) });
      setPolicy(next); setEditing(false); setReason(""); setConfirmed(false);
      setNotice("Saved for newly created games only. Existing games and earned ratings are unchanged.");
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not update rating policy."); }
    finally { setSaving(false); }
  }
  return <section className={styles.card} aria-label="Solo rating policy">
    <div className={styles.cardHeader}><div><span className="admin-eyebrow">Prospective rollout</span><h3>Solo rating policy</h3></div>
      {policy ? <span className={policy.enabled ? styles.draft : styles.locked}>{policy.enabled ? "Season 0 v2 enabled" : "Legacy for new games"}</span> : null}</div>
    <p>Season 0 v2 uses actual playing time, independent Outfield and Keeper pools, and audited match events. It needs the updated referee tools.</p>
    <p>Switching affects only games created afterwards, including future schedule generation. Existing games keep their saved policy. Ratings and history are never reset by this control.</p>
    <p>This switch does not control signup or public rating visibility. The deployed account update requires a one-time skill assessment for newly created accounts even while this switch is off. Release the compatible mobile signup flow alongside that database update; older clients cannot complete new signups.</p>
    {error ? <div className="admin-banner danger" role="alert">{error}</div> : null}
    {notice ? <div className="admin-banner success" role="status">{notice}</div> : null}
    {!policy && !error ? <LoadingSkeleton label="Loading rating policy" /> : null}
    {policy && !editing ? <button className="admin-secondary-button" type="button" onClick={() => { setEditing(true); setConfirmed(false); setNotice(null); }}>
      {policy.enabled ? "Use legacy policy for future games" : "Enable Season 0 v2 for future games"}</button> : null}
    {policy && editing ? <form onSubmit={submit}>
      <label className={styles.help}>Reason<textarea aria-label="Rating policy change reason" required minLength={10} maxLength={500} value={reason} onChange={event => setReason(event.target.value)} /></label>
      <label className={styles.help}><input type="checkbox" checked={confirmed} onChange={event => setConfirmed(event.target.checked)} required /> I have reviewed the new-game scope and referee workflow. Do not change existing games.</label>
      <div className={styles.cardHeader}><button className="admin-secondary-button" type="button" disabled={saving} onClick={() => setEditing(false)}>Cancel</button>
        <button className="admin-primary-button" type="submit" disabled={saving || !confirmed || reason.trim().length < 10}>{saving ? "Saving…" : "Confirm policy change"}</button></div>
    </form> : null}
  </section>;
}
