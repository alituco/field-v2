"use client";

import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { LoadingSkeleton } from "@/components/loading-skeleton";
import type { AdminReferralCatalog, AdminReferralEntry, AdminReferralTie } from "@/lib/admin-referrals";
import styles from "./referrals-panel.module.css";

async function request<T>(token: string, path = "", init?: RequestInit): Promise<T> {
  const response = await fetch(`/api/referee/admin/referrals${path}`, {
    ...init, cache: "no-store", signal: init?.signal ?? AbortSignal.timeout(20_000),
    headers: { "Content-Type": "application/json", authorization: `Bearer ${token}` },
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error ?? "Could not load referrals. Try again.");
  return data as T;
}

export function ReferralsPanel({ accessToken, refreshKey }: { accessToken: string; refreshKey: number }) {
  const [catalog, setCatalog] = useState<AdminReferralCatalog | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [reviewEpoch, setReviewEpoch] = useState(0);
  const generation = useRef(0);
  const currentToken = useRef(accessToken);
  currentToken.current = accessToken;
  const load = useCallback(async () => {
    const version = ++generation.current;
    const current = () => version === generation.current && currentToken.current === accessToken;
    setLoading(true); setError(null);
    try {
      const data = await request<AdminReferralCatalog>(accessToken);
      if (current()) { setCatalog(data); setReviewEpoch((value) => value + 1); }
    } catch (cause) {
      if (current()) setError(cause instanceof Error ? cause.message : "Could not load referrals.");
    } finally { if (current()) setLoading(false); }
  }, [accessToken]);
  useEffect(() => { setCatalog(null); void load(); return () => { generation.current += 1; }; }, [load, refreshKey]);

  function saved(result: { referrals?: AdminReferralCatalog; warning?: string }) {
    if (currentToken.current !== accessToken) return;
    generation.current += 1;
    setLoading(false);
    if (result.referrals) setCatalog(result.referrals);
    setNotice(result.warning ?? "Tie reviewed. The order and your reason were saved to the audit history.");
    if (!result.referrals) void load();
  }

  const pending = catalog?.tieGroups.filter((group) => !group.resolved) ?? [];
  return <div className={styles.stack}>
    <section className={styles.card}>
      <span className="admin-eyebrow">{catalog?.season.label ?? "Referrals"}</span>
      <h2>Referral standings & tie reviews</h2>
      <p>Players earn one referral when their friend attends a completed game. At least two referrals qualify for the leaderboard.</p>
      <p>Equal referral counts are ranked by the player’s games, then the combined games of their referred friends. Any remaining tie needs an admin decision.</p>
      <div className={styles.stats}><span><strong>{catalog?.qualifiedTotal ?? "—"}</strong> qualified players</span><span><strong>{catalog ? pending.length : "—"}</strong> ties to review</span><span><strong>$50</strong> Amazon gift card for each of the top five</span></div>
      {catalog ? <p className={styles.small}>{catalog.season.startsOn} – {catalog.season.endsOn} · {catalog.season.ended ? "Season ended" : "Season running"}. Gift-card delivery is handled manually.</p> : null}
    </section>
    {error ? <div className="admin-banner danger" role="alert">{error}<button type="button" onClick={() => void load()}>Refresh</button></div> : null}
    {notice ? <div className="admin-banner success" role="status">{notice}</div> : null}
    {loading ? <LoadingSkeleton label="Loading referral standings" /> : null}
    {catalog ? <>
      <section className={styles.stack} aria-label="Referral tie reviews">
        <div className={styles.heading}><h3>Ties needing review</h3><button className="admin-secondary-button" type="button" disabled={loading} onClick={() => void load()}>Refresh standings</button></div>
        {pending.length ? pending.map((group) => <TieReview key={`${group.evidenceToken}:${reviewEpoch}`} group={group} accessToken={accessToken} disabled={loading} onSaved={saved} onRefresh={load} />) : <div className={styles.empty}>No unresolved referral ties.</div>}
      </section>
      <section className={styles.card} aria-label="Referral leaderboard">
        <h3>Leaderboard</h3>
        <p className={styles.small}>Games count once per attended, completed game, across playing positions. Payment and skill rating do not affect referral credit.</p>
        <div className={styles.tableWrap}><table className={styles.table}>
          <thead><tr><th>Place</th><th>Player</th><th>Referrals</th><th>Player’s games</th><th>Friends’ games</th><th>Prize place</th></tr></thead>
          <tbody>{catalog.entries.map((entry) => <tr key={entry.id}><td>{entry.needsReview ? `T${entry.rank ?? "—"}` : entry.rank ?? "—"}</td><td><Player entry={entry} /></td><td>{entry.referralCount}</td><td>{entry.gamesPlayed}</td><td>{entry.referredGamesPlayed}</td><td>{entry.needsReview ? <span className={styles.review}>Review pending</span> : entry.prizeEligible ? <span className={styles.prize}>$50</span> : "—"}</td></tr>)}</tbody>
        </table></div>
        {!catalog.entries.length ? <p className={styles.empty}>No players have qualified yet.</p> : null}
        {catalog.entries.length < catalog.qualifiedTotal ? <p className={styles.small}>Showing the first {catalog.entries.length} of {catalog.qualifiedTotal} qualifying players. All unresolved ties are listed above.</p> : null}
      </section>
      {catalog.tieGroups.some((group) => group.resolved) ? <section className={styles.card} aria-label="Reviewed referral ties"><h3>Reviewed ties</h3>{catalog.tieGroups.filter((group) => group.resolved).map((group) => <details className={styles.reviewed} key={group.evidenceToken}><summary>Places {group.rank}–{group.rank + group.entries.length - 1} · {group.entries.length} players</summary><ol start={group.rank}>{group.orderedProfileIds.map((id) => { const player = group.entries.find((entry) => entry.id === id); return <li key={id}>{player?.name || "Player"}{player?.username ? ` · @${player.username}` : ""}</li>; })}</ol><p>{group.reviewNote}</p><small>Reopens for review if the tied players or qualifying counts change.</small></details>)}</section> : null}
    </> : null}
  </div>;
}

function Player({ entry }: { entry: AdminReferralEntry }) {
  return <span className={styles.player}><strong>{entry.name || "Player"}</strong>{entry.username ? <small>@{entry.username}</small> : null}</span>;
}

function TieReview({ group, accessToken, disabled, onSaved, onRefresh }: {
  group: AdminReferralTie; accessToken: string; disabled: boolean;
  onSaved: (result: { referrals?: AdminReferralCatalog; warning?: string }) => void;
  onRefresh: () => Promise<void>;
}) {
  // Deliberately blank: a UUID/source order must never become a prize decision.
  const [order, setOrder] = useState<string[]>(() => group.entries.map(() => ""));
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [needsRefresh, setNeedsRefresh] = useState(false);
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const complete = order.every(Boolean) && new Set(order).size === group.entries.length;
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (busy || disabled || needsRefresh || !complete) return;
    setBusy(true); setError(null);
    try {
      const data = await request<{ ok: true; referrals?: AdminReferralCatalog; warning?: string }>(accessToken, "/review", {
        method: "POST", body: JSON.stringify({ evidenceToken: group.evidenceToken, orderedProfileIds: order, note }),
      });
      if (mounted.current) onSaved(data);
    } catch (cause) {
      if (mounted.current) {
        setError(cause instanceof Error ? cause.message : "Could not confirm the review.");
        setNeedsRefresh(true);
      }
    } finally { if (mounted.current) setBusy(false); }
  }
  return <form className={styles.card} aria-label={`Review referral tie at place ${group.rank}`} onSubmit={(event) => void submit(event)}>
    <div className={styles.heading}><h3>Places {group.rank}–{group.rank + group.entries.length - 1}</h3><span className={styles.review}>Admin review needed</span></div>
    <p>All {group.entries.length} players have {group.referralCount} referrals, {group.gamesPlayed} games played, and {group.referredGamesPlayed} combined games by their referred friends.</p>
    <div className={styles.tableWrap}><table className={styles.table}><thead><tr><th>Tied player</th><th>Referrals</th><th>Player’s games</th><th>Friends’ games</th></tr></thead><tbody>{group.entries.map((entry) => <tr key={entry.id}><td><Player entry={entry} /></td><td>{entry.referralCount}</td><td>{entry.gamesPlayed}</td><td>{entry.referredGamesPlayed}</td></tr>)}</tbody></table></div>
    {error ? <div className="admin-banner danger" role="alert">{error}</div> : null}
    <fieldset disabled={busy || disabled || needsRefresh} className={styles.fields}>
      <legend>Choose the reviewed order</legend>
      <div className={styles.positions}>{order.map((id, index) => <label key={index}><span>Place {group.rank + index}</span><select required value={id} onChange={(event) => setOrder((current) => current.map((item, i) => i === index ? event.target.value : item))}><option value="">Choose a player</option>{group.entries.map((entry) => <option key={entry.id} value={entry.id} disabled={order.some((selected, i) => i !== index && selected === entry.id)}>{entry.name}{entry.username ? ` (@${entry.username})` : ""}</option>)}</select></label>)}</div>
      <label className={styles.note}><span>Review reason</span><textarea required minLength={10} maxLength={2000} rows={3} value={note} onChange={(event) => setNote(event.target.value)} placeholder="Explain the evidence behind this order." /></label>
    </fieldset>
    <footer className={styles.actions}><p>The full order and reason are recorded. If the standings changed, refresh and review again.</p>{needsRefresh ? <button className="admin-secondary-button" type="button" disabled={busy || disabled} onClick={() => void onRefresh()}>Refresh review status</button> : <button className="admin-primary-button" type="submit" disabled={busy || disabled || !complete || note.trim().length < 10}>{busy ? "Saving review…" : "Save reviewed order"}</button>}</footer>
  </form>;
}
