"use client";

import { useCallback, useEffect, useState, type FormEvent } from "react";
import { LoadingSkeleton } from "@/components/loading-skeleton";
import { RatingPolicyPanel } from "./rating-policy-panel";
import { formatPrize, parsePrizeUsd, type AdminSeason, type AdminSeasonCatalog, type AdminSeasonReward, type RatingTrack, type RewardAction, type SeasonAuditItem, type SeasonTransitionPreview, type SeasonEndPreview } from "@/lib/admin-seasons";
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

function nextSeason(seasons: AdminSeason[], base?: AdminSeason): AdminSeason {
  const latest = base ?? seasons.find((season) => season.lifecycle === "ACTIVE");
  const start = latest ? new Date(`${latest.endsOn}T12:00:00Z`) : new Date();
  if (latest) start.setUTCDate(start.getUTCDate() + 1);
  const length = latest ? Date.parse(latest.endsOn) - Date.parse(latest.startsOn) : 89 * 86400000;
  const end = new Date(start.getTime() + length);
  let number = Math.max(-1, ...seasons.map((season) => /^s\d+$/.test(season.id) ? Number(season.id.slice(1)) : -1)) + 1;
  while (seasons.some((season) => season.id === `s${number}`)) number += 1;
  const nextNumber = latest && /^s\d+$/.test(latest.id) ? Number(latest.id.slice(1)) + 1 : number;
  return { id: `s${number}`, label: `Season ${nextNumber}`, startsOn: start.toISOString().slice(0, 10), endsOn: end.toISOString().slice(0, 10), minimumRatedGames: 2, revision: 0, editable: true, publishedRewardsLocked: false,
    lifecycle: "DRAFT", visible: false, canHide: true, canChangeEnd: true, transitionState: "READY", blockedReason: null,
    gamesPlayed: 0, rankedPlayers: 0, placementPlayers: 0, unfinishedGames: 0, liveGames: 0, publishedPrizeCents: 0, readiness: [] };
}

function lifecycleLabel(season: AdminSeason) { return season.lifecycle === "ACTIVE" ? "Current" : season.lifecycle === "ENDED" ? "Ended" : season.lifecycle === "SCHEDULED" ? "Scheduled" : "Draft"; }
function tomorrow(today: string) { const value = new Date(`${today}T12:00:00Z`); value.setUTCDate(value.getUTCDate() + 1); return value.toISOString().slice(0, 10); }

export function SeasonsPanel({ accessToken, refreshKey }: { accessToken: string; refreshKey: number }) {
  const [catalog, setCatalog] = useState<AdminSeasonCatalog | null>(null);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [cityId, setCityId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [duplicating, setDuplicating] = useState<AdminSeason | null>(null);
  const [showPreview, setShowPreview] = useState(false);
  const [showTransition, setShowTransition] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const data = await request<AdminSeasonCatalog>(accessToken, "");
      setCatalog(data);
      setSeasonId((current) => current && data.seasons.some((season) => season.id === current) ? current : data.currentSeasonId ?? data.seasons.find((season) => season.lifecycle === "ACTIVE")?.id ?? data.seasons[0]?.id ?? null);
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
      <div><span className="admin-eyebrow">Seasons & rewards</span><h2>Run the season. Set the stakes.</h2><p>Plan the next season, manage what players see, and publish each city’s cash rewards.</p></div>
      <button className="admin-primary-button" type="button" disabled={loading || adding} onClick={() => { setDuplicating(null); setAdding(true); }}>+ Add season</button>
    </section>
    {error ? <div className="admin-banner danger" role="alert">{error}<button type="button" onClick={() => void load()}>Try again</button></div> : null}
    {notice ? <div className="admin-banner success" role="status">{notice}</div> : null}
    <RatingPolicyPanel accessToken={accessToken} />
    {loading ? <LoadingSkeleton label="Loading seasons and rewards" /> : catalog ? <>
      {adding ? <SeasonEditor key={`new-season:${duplicating?.id ?? "blank"}`} accessToken={accessToken} season={{ ...nextSeason(catalog.seasons, catalog.seasons.find((item) => item.id === catalog.currentSeasonId) ?? season), ...(duplicating ? { label: `${duplicating.label} copy`.slice(0, 40), minimumRatedGames: duplicating.minimumRatedGames } : {}) }} creating duplicateSource={duplicating ?? undefined} onCancel={() => { setAdding(false); setDuplicating(null); }} onSaved={async (id) => { setAdding(false); setDuplicating(null); setSeasonId(id); await saved("Season draft created. Check the dates and rewards, then schedule its start."); }} /> : null}
      <div className={styles.filters}>
        <label><span>Season</span><select value={seasonId ?? ""} onChange={(event) => { setSeasonId(event.target.value); setNotice(null); setShowPreview(false); setShowTransition(false); }}>{catalog.seasons.map((item) => <option key={item.id} value={item.id}>{item.label} · {lifecycleLabel(item)}{item.visible ? "" : " · Hidden"}</option>)}</select></label>
        <label><span>City</span><select value={cityId ?? ""} onChange={(event) => { setCityId(event.target.value); setNotice(null); }}>{catalog.cities.map((item) => <option key={item.id} value={item.id}>{item.displayName}{item.active ? "" : " · Not open yet"}</option>)}</select></label>
      </div>
      {season ? <>
        <SeasonIdentity key={`identity:${season.id}:${season.revision}`} accessToken={accessToken} season={season} onSaved={saved} onDuplicate={() => { setDuplicating(season); setAdding(true); }} onPreview={() => setShowPreview((value) => !value)} onTransition={() => setShowTransition((value) => !value)} />
        <div className={styles.metrics} aria-label="Season overview"><div><strong>{season.gamesPlayed}</strong><span>Games played</span></div><div><strong>{season.rankedPlayers}</strong><span>Ranked roles</span></div><div><strong>{season.placementPlayers}</strong><span>Roles in placement</span></div><div><strong>{formatPrize(season.publishedPrizeCents)}</strong><span>Published prizes</span></div></div>
        {season.blockedReason ? <div className="admin-banner danger" role="alert">{season.blockedReason}</div> : null}
        <SeasonReadinessPanel season={season} />
        {showPreview ? <PlayerPreview season={season} cityName={city?.displayName ?? "Choose a city"} rewards={rewards} /> : null}
        {showTransition && season.lifecycle === "ACTIVE" ? <TransitionPlanner key={`transition:${season.id}:${season.revision}`} accessToken={accessToken} current={season} catalog={catalog} onCancel={() => setShowTransition(false)} onSaved={async () => { setShowTransition(false); await saved("Season transition scheduled for midnight Phoenix time. Live games will be checked again at the cutoff."); }} /> : null}
        <SeasonEditor key={`${season.id}:${season.revision}:${season.editable}`} accessToken={accessToken} season={season} onSaved={async () => saved("Season competition settings saved.")} />
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

function SeasonEditor({ accessToken, season, creating = false, duplicateSource, onCancel, onSaved }: { accessToken: string; season: AdminSeason; creating?: boolean; duplicateSource?: AdminSeason; onCancel?: () => void; onSaved: (id: string) => Promise<void> }) {
  const [label, setLabel] = useState(season.label); const [startsOn, setStartsOn] = useState(season.startsOn); const [endsOn, setEndsOn] = useState(season.endsOn); const [minimum, setMinimum] = useState(String(season.minimumRatedGames));
  const [saving, setSaving] = useState(false); const [error, setError] = useState<string | null>(null);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (saving || !season.editable) return;
    setSaving(true); setError(null);
    try { await request(accessToken, duplicateSource ? `/${encodeURIComponent(duplicateSource.id)}/duplicate` : `/${encodeURIComponent(season.id)}`, { method: duplicateSource ? "POST" : "PUT", body: JSON.stringify(duplicateSource ? { id: season.id, label, startsOn, endsOn, minimumRatedGames: Number(minimum), expectedSourceRevision: duplicateSource.revision } : { label, startsOn, endsOn, minimumRatedGames: Number(minimum), expectedRevision: season.revision }) }); await onSaved(season.id); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "Could not save season."); }
    finally { setSaving(false); }
  }
  return <form className={styles.card} onSubmit={(event) => void submit(event)} aria-label={creating ? "New season" : "Season details"}>
    <div className={styles.cardHeader}><div><span className="admin-eyebrow">{creating ? duplicateSource ? `Copying ${duplicateSource.label}` : "New season" : "Competition settings"}</span><h3>{creating ? "Plan the next season" : `${prettyDate(season.startsOn)} — ${prettyDate(season.endsOn)}`}</h3></div>{!season.editable ? <span className={styles.locked}>Locked</span> : <span className={styles.draft}>Editable</span>}</div>
    {error ? <div className="admin-banner danger" role="alert">{error}</div> : null}
    <fieldset disabled={saving || !season.editable} className={styles.seasonFields}>
      {creating ? <label><span>Season name</span><input required minLength={1} maxLength={40} value={label} onChange={(event) => setLabel(event.target.value)} /></label> : null}
      <label><span>Starts on</span><input type="date" required value={startsOn} onChange={(event) => setStartsOn(event.target.value)} /></label>
      <label><span>Ends on</span><input type="date" required min={startsOn} value={endsOn} onChange={(event) => setEndsOn(event.target.value)} /></label>
      <label><span>Rated games for prizes</span><input type="number" required min={2} max={100} step={1} value={minimum} onChange={(event) => setMinimum(event.target.value)} /><small>Per role, this season. Ranking placement still takes 2 games.</small></label>
    </fieldset>
    {season.editable ? <footer className={styles.actions}><p>{creating ? duplicateSource ? "Copies rewards as private drafts. Player results and rankings are not copied." : "New seasons start as hidden drafts. Schedule the start when ready." : "Seasons cannot overlap. Placement takes two games; SR carries forward."}</p><div>{onCancel ? <button className="admin-secondary-button" type="button" disabled={saving} onClick={onCancel}>Cancel</button> : null}<button className="admin-primary-button" type="submit" disabled={saving}>{saving ? "Saving…" : creating ? duplicateSource ? "Create duplicate draft" : "Create season" : "Save season settings"}</button></div></footer> : <p className={styles.lockHint}>{season.publishedRewardsLocked ? "Start date and qualification are locked because rewards have been published." : "Start date and qualification are locked because this season has started."} Rename and end-date controls are available above.</p>}
  </form>;
}

function SeasonIdentity({ accessToken, season, onSaved, onDuplicate, onPreview, onTransition }: { accessToken: string; season: AdminSeason; onSaved: (message: string) => Promise<void>; onDuplicate: () => void; onPreview: () => void; onTransition: () => void }) {
  const [label, setLabel] = useState(season.label); const [busy, setBusy] = useState(false); const [error, setError] = useState<string | null>(null);
  const [changingEnd, setChangingEnd] = useState(false); const [endsOn, setEndsOn] = useState(season.endsOn); const [reason, setReason] = useState(""); const [confirmEnd, setConfirmEnd] = useState(false);
  const [endPreview, setEndPreview] = useState<SeasonEndPreview | null>(null);
  async function action(value: Record<string, unknown>, message: string, revision = season.revision) {
    if (busy) return; setBusy(true); setError(null);
    try { await request(accessToken, `/${encodeURIComponent(season.id)}/actions`, { method: "POST", body: JSON.stringify({ ...value, expectedRevision: revision }) }); await onSaved(message); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "Could not update this season."); }
    finally { setBusy(false); }
  }
  async function reviewEnd(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (busy) return;
    if (confirmEnd && endPreview?.canSave) { await action({ action: "END_DATE", endsOn, reason }, "Season end date updated. Your reason and the previous date were recorded.", endPreview.currentSeason.revision); return; }
    setBusy(true); setError(null);
    try { const result = await request<{ preview: SeasonEndPreview }>(accessToken, `/${encodeURIComponent(season.id)}/end-preview`, { method: "POST", body: JSON.stringify({ endsOn }) }); setEndPreview(result.preview); setConfirmEnd(true); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "Could not preview this end-date change."); }
    finally { setBusy(false); }
  }
  return <section className={styles.card} aria-label="Season management">
    <div className={styles.cardHeader}><div><span className="admin-eyebrow">{lifecycleLabel(season)} season</span><h3>{season.label}</h3></div><span className={season.visible ? styles.published : styles.draft}>{season.visible ? "Visible to players" : "Hidden from players"}</span></div>
    {error ? <div className="admin-banner danger" role="alert">{error}</div> : null}
    <form className={styles.rename} onSubmit={(event) => { event.preventDefault(); void action({ action: "RENAME", label }, "Season renamed. Its history keeps the same season identity."); }}>
      <label className={styles.inputLabel}><span>Season display name</span><input value={label} maxLength={40} minLength={1} required disabled={busy} onChange={(event) => setLabel(event.target.value)} /></label><button className="admin-secondary-button" disabled={busy || label.trim() === season.label} type="submit">Save name</button>
    </form>
    <div className={styles.managementActions}>
      <button className="admin-secondary-button" type="button" disabled={busy || !season.canHide} onClick={() => void action({ action: "VISIBILITY", visible: !season.visible }, season.visible ? "Season hidden from the player season picker. Match history remains available." : "Season restored to the player season picker.")}>{season.visible ? "Hide from players" : "Show to players"}</button>
      {season.lifecycle === "DRAFT" ? <button className="admin-primary-button" type="button" disabled={busy} onClick={() => void action({ action: "SCHEDULE" }, "Season start scheduled for midnight Phoenix time.")}>Schedule season</button> : null}
      {season.lifecycle === "SCHEDULED" ? <button className="admin-secondary-button" type="button" disabled={busy || season.publishedRewardsLocked} onClick={() => void action({ action: "MAKE_DRAFT" }, "Season returned to a hidden draft.")}>Return to draft</button> : null}
      {season.lifecycle === "ACTIVE" ? <button className="admin-primary-button" type="button" disabled={busy} onClick={onTransition}>End current / Start next</button> : null}
      {season.canChangeEnd ? <button className="admin-secondary-button" type="button" disabled={busy} onClick={() => { setChangingEnd((value) => !value); setConfirmEnd(false); }}>Change end date</button> : null}
      <button className="admin-secondary-button" type="button" disabled={busy} onClick={onDuplicate}>Duplicate season</button>
      <button className="admin-secondary-button" type="button" onClick={onPreview}>Player preview</button>
    </div>
    {season.lifecycle === "ACTIVE" ? <p className={styles.lockHint}>The current season stays visible. Season changes take effect at midnight in Phoenix.</p> : null}
    {changingEnd ? <form className={styles.confirmation} aria-label="Change season end date" onSubmit={(event) => void reviewEnd(event)}>
      <h4>Change the season end date</h4><div className={styles.endFields}><label className={styles.inputLabel}><span>New end date</span><input type="date" min={season.startsOn} required value={endsOn} disabled={busy || confirmEnd} onChange={(event) => setEndsOn(event.target.value)} /></label><label className={styles.reason}><span>Reason for end-date change</span><textarea required minLength={10} maxLength={1000} value={reason} disabled={busy || confirmEnd} onChange={(event) => setReason(event.target.value)} /></label></div>
      {confirmEnd && endPreview ? <div className={styles.impact}><p><strong>{prettyDate(endPreview.currentSeason.endsOn)} → {prettyDate(endPreview.endsOn)}</strong></p><div className={styles.impactCounts}><span><strong>{endPreview.liveGames.length}</strong> live games</span><span><strong>{endPreview.unfinishedGames.length}</strong> unfinished games</span><span><strong>{endPreview.affectedFutureGames.length}</strong> future games</span></div><p>Unfinished games stay attached to this season. Completed results keep their season. Published prize descriptions will use the new end date.</p>{endPreview.affectedFutureGames.length ? <details><summary>View games affected by the end date</summary><ul>{endPreview.affectedFutureGames.map((game) => <li key={game.id}>{game.venue} · {game.status}</li>)}</ul></details> : null}{endPreview.blockers.length ? <ul className={styles.blockers} role="alert">{endPreview.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul> : null}<p>Start date, prize qualification and carried SR remain the same.</p></div> : null}
      <div className={styles.buttonRow}><button className="admin-secondary-button" type="button" disabled={busy} onClick={() => confirmEnd ? setConfirmEnd(false) : setChangingEnd(false)}>{confirmEnd ? "Keep editing" : "Cancel"}</button><button className="admin-primary-button" type="submit" disabled={busy || endsOn === season.endsOn || (confirmEnd && endPreview?.canSave !== true)}>{busy ? "Checking…" : confirmEnd ? "Confirm end-date change" : "Review date change"}</button></div>
    </form> : null}
  </section>;
}

function SeasonReadinessPanel({ season }: { season: AdminSeason }) {
  const issues = [...season.readiness.map((item) => item.message)];
  if (season.unfinishedGames && !issues.some((item) => /unfinished|missing result/i.test(item))) issues.push(`${season.unfinishedGames} games still need results. They can be finalized in their original season.`);
  if (season.liveGames && !issues.some((item) => /live/i.test(item))) issues.push(`${season.liveGames} games are live. A season transition will wait until they finish.`);
  return <details className={styles.readiness} open={season.lifecycle === "DRAFT" || season.transitionState === "BLOCKED_LIVE"}><summary>Season readiness <span>{issues.length ? `${issues.length} to review` : "Ready"}</span></summary>{issues.length ? <ul>{issues.map((message, index) => <li key={index}>{message}</li>)}</ul> : <p>Dates and settings are ready. Rewards are managed separately for each city and role.</p>}</details>;
}

function PlayerPreview({ season, cityName, rewards }: { season: AdminSeason; cityName: string; rewards: AdminSeasonReward[] }) {
  return <section className={styles.preview} aria-label="Player preview">
    <div className={styles.sectionHeader}><div><span className="admin-eyebrow">Player preview · {cityName}</span><h3>{season.label}</h3></div><span className={styles.draft}>{season.lifecycle === "DRAFT" ? "Preview only" : season.lifecycle === "SCHEDULED" ? "Available after start" : season.visible ? "Player-visible season" : "Hidden season"}</span></div>
    <p className={styles.rewardHint}>Layout preview of saved amounts. Standings are not shown here. Draft rewards stay private until published.</p>
    <div className={styles.previewRoles}>{(["OUTFIELD", "GOALKEEPER"] as RatingTrack[]).map((track) => {
      const reward = rewards.find((item) => item.ratingTrack === track);
      return <div key={track}><h4>{track === "OUTFIELD" ? "Outfield" : "Keeper"} <span>{reward?.status === "PUBLISHED" ? "Published" : reward ? "Saved draft" : "Not configured"}</span></h4>
        {reward ? <><div className={styles.prizeHeading}><strong>PRIZE PLACES</strong><span>When {season.label} ends</span></div><ol>{[reward.firstPrizeCents, reward.secondPrizeCents, reward.thirdPrizeCents].map((amount, index) => <li key={index}><span>{index + 1}</span><span className={styles.emptyAvatar} aria-hidden="true" /><div><strong>Prize place</strong><small>Preview only</small></div><b>{formatPrize(amount)}</b></li>)}</ol><p>{season.minimumRatedGames} rated games to qualify · {prettyDate(season.endsOn)}</p></> : <p>Save this city’s {track === "OUTFIELD" ? "outfield" : "keeper"} rewards to preview the prize card.</p>}
      </div>;
    })}</div>
  </section>;
}

function TransitionPlanner({ accessToken, current, catalog, onCancel, onSaved }: { accessToken: string; current: AdminSeason; catalog: AdminSeasonCatalog; onCancel: () => void; onSaved: () => Promise<void> }) {
  const candidates = catalog.seasons.filter((item) => item.id !== current.id && ["DRAFT", "SCHEDULED"].includes(item.lifecycle)).sort((a, b) => a.startsOn.localeCompare(b.startsOn));
  const [nextId, setNextId] = useState(candidates[0]?.id ?? ""); const [startsOn, setStartsOn] = useState(tomorrow(catalog.today)); const [reason, setReason] = useState("");
  const [preview, setPreview] = useState<SeasonTransitionPreview | null>(null); const [busy, setBusy] = useState(false); const [error, setError] = useState<string | null>(null);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (busy) return; setBusy(true); setError(null);
    try {
      if (!preview) { const data = await request<{ preview: SeasonTransitionPreview }>(accessToken, "/transition/preview", { method: "POST", body: JSON.stringify({ currentSeasonId: current.id, nextSeasonId: nextId, startsOn }) }); setPreview(data.preview); }
      else { await request(accessToken, "/transition", { method: "POST", body: JSON.stringify({ currentSeasonId: current.id, nextSeasonId: nextId, startsOn, reason, expectedCurrentRevision: preview.currentSeason.revision, expectedNextRevision: preview.nextSeason.revision }) }); await onSaved(); }
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not schedule the season transition."); }
    finally { setBusy(false); }
  }
  return <form className={styles.card} aria-label="Season transition" onSubmit={(event) => void submit(event)}><div className={styles.cardHeader}><div><span className="admin-eyebrow">Midnight Phoenix time</span><h3>End {current.label}. Start the next season.</h3></div></div>
    <p className={styles.rewardHint}>SR carries forward for both roles. Placement, season statistics and earned-city counts begin again.</p>
    {error ? <div className="admin-banner danger" role="alert">{error}</div> : null}
    {!candidates.length ? <p className={styles.help}>Create a draft season first, then return here to schedule the transition.</p> : <div className={styles.endFields}><label className={styles.inputLabel}><span>Next season</span><select required value={nextId} disabled={busy || !!preview} onChange={(event) => setNextId(event.target.value)}>{candidates.map((item) => <option key={item.id} value={item.id}>{item.label} · {lifecycleLabel(item)}</option>)}</select></label><label className={styles.inputLabel}><span>Next season starts on</span><input type="date" min={tomorrow(catalog.today)} required value={startsOn} disabled={busy || !!preview} onChange={(event) => setStartsOn(event.target.value)} /></label></div>}
    {preview ? <section className={styles.confirmation} aria-label="Transition impact preview"><h4>Review the transition</h4><p>{preview.currentSeason.label} ends {prettyDate(preview.endsOn)}. {preview.nextSeason.label} starts at midnight Phoenix time on {prettyDate(preview.startsOn)}.</p><div className={styles.impactCounts}><span><strong>{preview.liveGames.length}</strong> live games</span><span><strong>{preview.unfinishedGames.length}</strong> unfinished games</span><span><strong>{preview.affectedFutureGames.length}</strong> future games</span></div><p>Late results remain in their original season. Future games are assigned to the season in effect when they start.</p>{preview.affectedFutureGames.length ? <details><summary>View affected future games</summary><ul>{preview.affectedFutureGames.map((game) => <li key={game.id}>{game.venue} · {game.kind} · {game.status}</li>)}</ul></details> : null}{preview.unfinishedGames.length ? <details><summary>View games awaiting results</summary><ul>{preview.unfinishedGames.map((game) => <li key={game.id}>{game.venue} · {game.status}</li>)}</ul></details> : null}
      {preview.blockers.length ? <ul className={styles.blockers} role="alert">{preview.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul> : null}<p>Live games are checked again at the cutoff. If a game is still live, the transition moves to the next midnight and the current season remains active.</p>
      {preview.canSchedule ? <label className={styles.reason}><span>Reason for season transition</span><textarea required minLength={10} maxLength={1000} disabled={busy} value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Explain why this season is ending on this date." /></label> : null}
    </section> : null}
    <div className={styles.buttonRow}><button className="admin-secondary-button" type="button" disabled={busy} onClick={() => preview ? setPreview(null) : onCancel()}>{preview ? "Change plan" : "Cancel"}</button><button className="admin-primary-button" type="submit" disabled={busy || !candidates.length || (preview !== null && !preview.canSchedule)}>{busy ? "Checking…" : preview ? "Confirm and schedule transition" : "Review transition"}</button></div>
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
      <h4>Publish {formatPrize(total)} for {cityName} {roleName.toLowerCase()}?</h4><p>Players will see these prizes when {season.label} is visible. This locks the season start date and {season.minimumRatedGames}-game prize qualification. End-date changes and cash corrections require a reason and are audited.</p><div className={styles.buttonRow}><button className="admin-secondary-button" type="button" disabled={saving} onClick={() => setConfirming(false)}>Keep editing</button><button className="admin-primary-button" type="button" disabled={saving} onClick={() => void save("PUBLISH")}>{saving ? "Publishing…" : "Confirm and publish"}</button></div>
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
    if ("current_season" in state) { const current = state.current_season as Record<string, unknown>; const next = state.next_season as Record<string, unknown> | undefined; return `${String(current.label)} ends ${String(current.ends_on)}${next ? ` · ${String(next.label)} starts ${String(next.starts_on)}` : ""}`; }
    return `${String(state.label)} · ${String(state.starts_on)} to ${String(state.ends_on)} · ${String(state.minimum_rated_games)} games for prizes${"visible_to_players" in state ? ` · ${state.visible_to_players ? "visible" : "hidden"}` : ""}`;
  }
  return <section className={styles.audit}><div className={styles.sectionHeader}><h3>Change history</h3><span>Latest 100 changes across seasons</span></div>{items.length ? <ol>{items.map((item) => <li key={item.id}><div className={styles.auditTop}><strong>{item.action.toLowerCase().replaceAll("_", " ")}{item.cityId ? ` · ${cities.get(item.cityId) ?? item.cityId} · ${item.ratingTrack === "GOALKEEPER" ? "Keeper" : "Outfield"}` : ""}</strong><time dateTime={item.createdAt}>{new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short", timeZone: "America/Phoenix" }).format(new Date(item.createdAt))}</time></div><p>{item.reason ?? "Routine configuration update"} <span>· {item.actorAdminId ? `Admin ${item.actorAdminId.slice(0, 8)}` : "System scheduler"}</span></p><details><summary>View before and after</summary><dl><dt>Before</dt><dd>{summary(item.beforeState)}</dd><dt>After</dt><dd>{summary(item.afterState)}</dd></dl></details></li>)}</ol> : <p className={styles.empty}>No admin changes recorded for this season yet.</p>}</section>;
}
