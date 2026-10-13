"use client";

import { useCallback, useEffect, useState, type FormEvent } from "react";
import { LoadingSkeleton } from "@/components/loading-skeleton";
import { formatPrize, parsePrizeUsd, type AdminSeason, type AdminSeasonCatalog, type AdminSeasonReward, type RatingTrack, type RewardAction, type SeasonAuditItem } from "@/lib/admin-seasons";
import styles from "./seasons-panel.module.css";

async function request<T>(token: string, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`/api/referee/admin/seasons${path}`, { ...init, cache: "no-store",
    headers: { "Content-Type": "application/json", authorization: `Bearer ${token}` } });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || "Could not update season settings.");
  return payload as T;
}

function prettyDate(value: string) {
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }).format(new Date(`${value}T12:00:00Z`));
}

function nextSeason(seasons: AdminSeason[]): AdminSeason {
  const latest = [...seasons].sort((a, b) => b.endsOn.localeCompare(a.endsOn))[0];
  const start = latest ? new Date(`${latest.endsOn}T12:00:00Z`) : new Date();
  if (latest) start.setUTCDate(start.getUTCDate() + 1);
  const end = new Date(Date.UTC(start.getUTCFullYear(), Math.floor(start.getUTCMonth() / 3) * 3 + 3, 0, 12));
  let number = Math.max(-1, ...seasons.map((season) => /^s\d+$/.test(season.id) ? Number(season.id.slice(1)) : -1)) + 1;
  while (seasons.some((season) => season.id === `s${number}`)) number += 1;
  return { id: `s${number}`, label: `Season ${number}`, startsOn: start.toISOString().slice(0, 10), endsOn: end.toISOString().slice(0, 10), minimumRatedGames: 2, revision: 0, editable: true, publishedRewardsLocked: false };
}

export function SeasonsPanel({ accessToken, refreshKey }: { accessToken: string; refreshKey: number }) {
  const [catalog, setCatalog] = useState<AdminSeasonCatalog | null>(null);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [cityId, setCityId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const data = await request<AdminSeasonCatalog>(accessToken, "");
      setCatalog(data);
      setSeasonId((current) => current && data.seasons.some((season) => season.id === current) ? current : data.seasons.find((season) => season.startsOn <= data.today && season.endsOn >= data.today)?.id ?? data.seasons[0]?.id ?? null);
      setCityId((current) => current && data.cities.some((city) => city.id === current) ? current : data.cities.find((city) => city.active)?.id ?? data.cities[0]?.id ?? null);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not load seasons."); }
    finally { setLoading(false); }
  }, [accessToken]);
  useEffect(() => { void load(); }, [load, refreshKey]);

  const season = catalog?.seasons.find((item) => item.id === seasonId);
  const city = catalog?.cities.find((item) => item.id === cityId);
  const rewards = catalog?.rewards.filter((reward) => reward.seasonId === seasonId && reward.cityId === cityId) ?? [];
  const publishedTotal = rewards.filter((reward) => reward.status === "PUBLISHED").reduce((sum, reward) => sum + reward.firstPrizeCents + reward.secondPrizeCents + reward.thirdPrizeCents, 0);
  async function saved(message: string) { setNotice(message); await load(); }

  return <div className={styles.stack}>
    <section className={styles.intro}>
      <div><span className="admin-eyebrow">Season settings</span><h2>Give every ladder something to play for.</h2><p>Set the season dates, prize qualification and cash rewards. Every city has its own Outfield and Keeper prize pool.</p></div>
      <button className="admin-secondary-button" type="button" disabled={loading || adding} onClick={() => setAdding(true)}>+ Add season</button>
    </section>
    {error ? <div className="admin-banner danger" role="alert">{error}<button type="button" onClick={() => void load()}>Try again</button></div> : null}
    {notice ? <div className="admin-banner success" role="status">{notice}</div> : null}
    {loading ? <LoadingSkeleton label="Loading seasons and rewards" /> : catalog ? <>
      {adding ? <SeasonEditor key="new-season" accessToken={accessToken} season={nextSeason(catalog.seasons)} creating onCancel={() => setAdding(false)} onSaved={async (id) => { setAdding(false); setSeasonId(id); await saved("Season created. Configure its city rewards, then publish when ready."); }} /> : null}
      <div className={styles.filters}>
        <label><span>Season</span><select value={seasonId ?? ""} onChange={(event) => { setSeasonId(event.target.value); setNotice(null); }}>{catalog.seasons.map((item) => <option key={item.id} value={item.id}>{item.label} · {item.startsOn <= catalog.today && item.endsOn >= catalog.today ? "Current" : item.endsOn < catalog.today ? "Past" : "Upcoming"}</option>)}</select></label>
        <label><span>City</span><select value={cityId ?? ""} onChange={(event) => { setCityId(event.target.value); setNotice(null); }}>{catalog.cities.map((item) => <option key={item.id} value={item.id}>{item.displayName}{item.active ? "" : " · Not open yet"}</option>)}</select></label>
      </div>
      {season ? <>
        <SeasonEditor key={`${season.id}:${season.revision}:${season.editable}`} accessToken={accessToken} season={season} onSaved={async () => saved("Season settings saved. Other seasons and the two-game placement rule are unchanged.")} />
        {city ? <>
          <div className={styles.sectionHeader}><div><span className="admin-eyebrow">{city.displayName} · USD cash rewards</span><h3>Two roles. Two prize pools.</h3></div><div className={styles.total}><span>Published total</span><strong>{formatPrize(publishedTotal)}</strong></div></div>
          <div className={styles.help}>Players need {season.minimumRatedGames} rated {season.minimumRatedGames === 1 ? "game" : "games"} in a role this season to qualify for its prizes. The same player can qualify for both. Only qualifying places are filled; unused prizes are not redistributed. Global rankings have no cash prize pool.</div>
          <div className={styles.rewardGrid}>{(["OUTFIELD", "GOALKEEPER"] as RatingTrack[]).map((track) => {
            const reward = rewards.find((item) => item.ratingTrack === track);
            return <RewardEditor key={`${season.id}:${city.id}:${track}:${reward?.revision ?? 0}`} accessToken={accessToken} season={season} ended={season.endsOn < catalog.today} cityId={city.id} cityName={city.displayName} track={track} reward={reward} onSaved={(action) => saved(action === "PUBLISH" ? "Cash rewards published to the app. Amounts and season qualification are now locked; corrections require a reason." : action === "CORRECT" ? "Published rewards corrected. The reason and before/after values were saved to the audit history." : "Reward draft saved. It is not visible to players until published.")} />;
          })}</div>
        </> : <div className={styles.help}>Add a competition city before setting up city rewards. <a href="/admin/cities">Manage cities →</a></div>}
        <section className={styles.rules}><h3>How prize places work</h3><p>Equal skill ratings are ordered by more goals scored, then fewer goals conceded, then player name. A player’s competition city is earned from their total games across both roles; tied city counts use their most recently played game.</p><p>This release only displays prize information. It does not pick final winners, send money or run a season-end review.</p></section>
        <AuditHistory items={catalog.audit.filter((item) => item.seasonId === season.id)} cities={new Map(catalog.cities.map((item) => [item.id, item.displayName]))} />
      </> : <div className={styles.help}>No seasons yet. Add the first season to configure rewards.</div>}
    </> : null}
  </div>;
}

function SeasonEditor({ accessToken, season, creating = false, onCancel, onSaved }: { accessToken: string; season: AdminSeason; creating?: boolean; onCancel?: () => void; onSaved: (id: string) => Promise<void> }) {
  const [label, setLabel] = useState(season.label); const [startsOn, setStartsOn] = useState(season.startsOn); const [endsOn, setEndsOn] = useState(season.endsOn); const [minimum, setMinimum] = useState(String(season.minimumRatedGames));
  const [saving, setSaving] = useState(false); const [error, setError] = useState<string | null>(null);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (saving || !season.editable) return;
    setSaving(true); setError(null);
    try { await request(accessToken, `/${encodeURIComponent(season.id)}`, { method: "PUT", body: JSON.stringify({ label, startsOn, endsOn, minimumRatedGames: Number(minimum), expectedRevision: season.revision }) }); await onSaved(season.id); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "Could not save season."); }
    finally { setSaving(false); }
  }
  return <form className={styles.card} onSubmit={(event) => void submit(event)} aria-label={creating ? "New season" : "Season details"}>
    <div className={styles.cardHeader}><div><span className="admin-eyebrow">{creating ? "New season" : "Season details"}</span><h3>{creating ? "Plan the next season" : `${prettyDate(season.startsOn)} — ${prettyDate(season.endsOn)}`}</h3></div>{!season.editable ? <span className={styles.locked}>Locked</span> : <span className={styles.draft}>Editable</span>}</div>
    {error ? <div className="admin-banner danger" role="alert">{error}</div> : null}
    <fieldset disabled={saving || !season.editable} className={styles.seasonFields}>
      <label><span>Season name</span><input required minLength={1} maxLength={40} value={label} onChange={(event) => setLabel(event.target.value)} /></label>
      <label><span>Starts on</span><input type="date" required value={startsOn} onChange={(event) => setStartsOn(event.target.value)} /></label>
      <label><span>Ends on</span><input type="date" required min={startsOn} value={endsOn} onChange={(event) => setEndsOn(event.target.value)} /></label>
      <label><span>Rated games for prizes</span><input type="number" required min={2} max={100} step={1} value={minimum} onChange={(event) => setMinimum(event.target.value)} /><small>Per role, this season. Ranking placement still takes 2 games.</small></label>
    </fieldset>
    {season.editable ? <footer className={styles.actions}><p>Configure dates and eligibility before publishing any rewards. Seasons cannot overlap.</p><div>{onCancel ? <button className="admin-secondary-button" type="button" disabled={saving} onClick={onCancel}>Cancel</button> : null}<button className="admin-primary-button" type="submit" disabled={saving}>{saving ? "Saving…" : creating ? "Create season" : "Save season settings"}</button></div></footer> : <p className={styles.lockHint}>{season.publishedRewardsLocked ? "Dates and qualification are locked because this season has published rewards." : "This season has already started. Dates and qualification can only be changed for future seasons."}</p>}
  </form>;
}

function RewardEditor({ accessToken, season, ended, cityId, cityName, track, reward, onSaved }: { accessToken: string; season: AdminSeason; ended: boolean; cityId: string; cityName: string; track: RatingTrack; reward?: AdminSeasonReward; onSaved: (action: RewardAction) => Promise<void> }) {
  const defaults = [reward?.firstPrizeCents ?? 15000, reward?.secondPrizeCents ?? 10000, reward?.thirdPrizeCents ?? 5000];
  const [amounts, setAmounts] = useState(defaults.map((value) => (value / 100).toFixed(2)));
  const [correcting, setCorrecting] = useState(false); const [confirming, setConfirming] = useState(false); const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false); const [error, setError] = useState<string | null>(null);
  const published = reward?.status === "PUBLISHED"; const readOnly = ended || (published && !correcting); const roleName = track === "OUTFIELD" ? "Outfield" : "Keeper";
  let total = 0; let valid = true;
  try { total = amounts.reduce((sum, amount) => sum + parsePrizeUsd(amount), 0); } catch { valid = false; }
  async function save(action: RewardAction) {
    if (saving || ended) return;
    setSaving(true); setError(null);
    try {
      amounts.forEach(parsePrizeUsd);
      await request(accessToken, `/${encodeURIComponent(season.id)}/rewards/${encodeURIComponent(cityId)}/${track}`, { method: "PUT", body: JSON.stringify({ firstPrizeUsd: amounts[0], secondPrizeUsd: amounts[1], thirdPrizeUsd: amounts[2], action, reason: action === "CORRECT" ? reason : null, expectedRevision: reward?.revision ?? 0 }) });
      await onSaved(action);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not save rewards."); }
    finally { setSaving(false); }
  }
  function submit(event: FormEvent<HTMLFormElement>) { event.preventDefault(); if (!readOnly && !confirming) void save(correcting ? "CORRECT" : "SAVE"); }
  return <form className={styles.card} onSubmit={submit} aria-label={`${roleName} rewards`}>
    <div className={styles.cardHeader}><div><span className="admin-eyebrow">{cityName}</span><h3>{roleName}</h3></div><span className={published ? styles.published : styles.draft}>{published ? "Published" : "Draft"}</span></div>
    {error ? <div className="admin-banner danger" role="alert">{error}</div> : null}
    <fieldset disabled={saving || readOnly || confirming} className={styles.prizes}>
      {amounts.map((amount, index) => <label key={index}><span className={styles.place}>{index + 1}</span><span className={styles.amountLabel}>{["First", "Second", "Third"][index]} place <small>USD cash</small></span><span className={styles.amountInput}><span aria-hidden="true">$</span><input aria-label={`${roleName} ${["first", "second", "third"][index]} place USD`} inputMode="decimal" required pattern="[0-9]+(\.[0-9]{1,2})?" maxLength={10} value={amount} onChange={(event) => { setAmounts((current) => current.map((value, i) => i === index ? event.target.value : value)); setError(null); }} /></span></label>)}
    </fieldset>
    <div className={styles.pool}><span>Total {roleName.toLowerCase()} pool</span><strong>{valid ? formatPrize(total) : "—"}</strong></div>
    <p className={styles.rewardHint}>{ended ? "This season has ended. Its reward settings are read-only." : published ? `Visible to players · revision ${reward.revision}. Published amounts are locked.` : "Only saved drafts live here. Players see these prizes after you publish."}</p>
    {correcting ? <label className={styles.reason}><span>Reason for published correction</span><textarea required minLength={10} maxLength={1000} value={reason} disabled={saving} onChange={(event) => setReason(event.target.value)} placeholder="Explain the error and why these published amounts must change." /><small>Saved with the old and new amounts and your admin identity.</small></label> : null}
    {confirming ? <section className={styles.confirmation} aria-label={`Confirm ${roleName} publication`}>
      <h4>Publish {formatPrize(total)} for {cityName} {roleName.toLowerCase()}?</h4><p>Players will see these prizes for {season.label}. This locks the season dates and {season.minimumRatedGames}-game prize qualification. Later cash corrections require a reason and are audited.</p><div className={styles.buttonRow}><button className="admin-secondary-button" type="button" disabled={saving} onClick={() => setConfirming(false)}>Keep editing</button><button className="admin-primary-button" type="button" disabled={saving} onClick={() => void save("PUBLISH")}>{saving ? "Publishing…" : "Confirm and publish"}</button></div>
    </section> : ended ? null : <div className={styles.buttonRow}>
      {readOnly ? <button className="admin-secondary-button" type="button" onClick={() => { setCorrecting(true); setError(null); }}>Correct published rewards</button> : <>
        {correcting ? <button className="admin-secondary-button" type="button" disabled={saving} onClick={() => { setCorrecting(false); setAmounts(defaults.map((value) => (value / 100).toFixed(2))); setReason(""); setError(null); }}>Cancel correction</button> : null}
        <button className={correcting ? "admin-primary-button" : "admin-secondary-button"} type="submit" disabled={saving || !valid}>{saving ? "Saving…" : correcting ? "Save audited correction" : "Save draft"}</button>
        {!published ? <button className="admin-primary-button" type="button" disabled={saving || !valid} onClick={(event) => { if (event.currentTarget.form?.reportValidity()) { setConfirming(true); setError(null); } }}>Publish rewards</button> : null}
      </>}
    </div>}
  </form>;
}

function AuditHistory({ items, cities }: { items: SeasonAuditItem[]; cities: Map<string, string> }) {
  function summary(state: Record<string, unknown> | null) {
    if (!state) return "Not configured";
    if ("first_prize_cents" in state) return `${formatPrize(Number(state.first_prize_cents))} / ${formatPrize(Number(state.second_prize_cents))} / ${formatPrize(Number(state.third_prize_cents))} · ${String(state.status).toLowerCase()}`;
    return `${String(state.label)} · ${String(state.starts_on)} to ${String(state.ends_on)} · ${String(state.minimum_rated_games)} games for prizes`;
  }
  return <section className={styles.audit}><div className={styles.sectionHeader}><h3>Change history</h3><span>Latest 100 changes across seasons</span></div>{items.length ? <ol>{items.map((item) => <li key={item.id}><div className={styles.auditTop}><strong>{item.action.toLowerCase().replaceAll("_", " ")}{item.cityId ? ` · ${cities.get(item.cityId) ?? item.cityId} · ${item.ratingTrack === "GOALKEEPER" ? "Keeper" : "Outfield"}` : ""}</strong><time dateTime={item.createdAt}>{new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short" }).format(new Date(item.createdAt))}</time></div><p>{item.reason ?? "Routine configuration update"} <span>· Admin {item.actorAdminId.slice(0, 8)}</span></p><details><summary>View before and after</summary><dl><dt>Before</dt><dd>{summary(item.beforeState)}</dd><dt>After</dt><dd>{summary(item.afterState)}</dd></dl></details></li>)}</ol> : <p className={styles.empty}>No admin changes recorded for this season yet.</p>}</section>;
}
