"use client";

import { useCallback, useEffect, useState, type FormEvent } from "react";
import { LoadingSkeleton } from "@/components/loading-skeleton";
import type { AdminCity } from "@/lib/admin-cities";
import styles from "./fields-panel.module.css";

async function cityRequest<T>(token: string, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`/api/referee/admin/cities${path}`, { ...init, cache: "no-store",
    headers: { "Content-Type": "application/json", authorization: `Bearer ${token}` } });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || "Could not save city details.");
  return payload as T;
}

export function CitiesPanel({ accessToken, refreshKey }: { accessToken: string; refreshKey: number }) {
  const [cities, setCities] = useState<AdminCity[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState<AdminCity | "new" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try { setCities((await cityRequest<{ cities: AdminCity[] }>(accessToken, "")).cities); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "Could not load cities."); }
    finally { setLoading(false); }
  }, [accessToken]);
  useEffect(() => { void load(); }, [load, refreshKey]);

  if (editing) return <CityEditor key={editing === "new" ? "new" : editing.id} accessToken={accessToken}
    city={editing === "new" ? null : editing} existingIds={cities.map((city) => city.id)} onCancel={() => setEditing(null)}
    onSaved={(city) => { setEditing(null); setNotice(`${city.displayName} saved. Existing games and earned rankings are unchanged.`); void load(); }} />;

  return <div className={styles.stack}>
    <section className={styles.intro}><div><span className="admin-eyebrow">Where Fieldrush plays</span><h2>One city. One community.</h2><p>Manage the cities players can choose. Fields belong to a competition city even when their street address is in a nearby town.</p></div><button className="admin-primary-button" type="button" onClick={() => setEditing("new")}>+ Add a city</button></section>
    <div className={styles.help}>A player’s preferred city controls game discovery. Their season ranking city is earned from the most games played across both positions; a tie uses their latest played game. Changing a city here never transfers SR.</div>
    {error ? <div className="admin-banner danger" role="alert">{error}<button type="button" onClick={() => void load()}>Try again</button></div> : null}
    {notice ? <div className="admin-banner success" role="status">{notice}</div> : null}
    {loading ? <LoadingSkeleton label="Loading cities" /> : <div className={styles.grid}>{cities.map((city) => <article key={city.id} className={styles.card}>
      <div className={styles.cardTop}><span className={styles.pitch} aria-hidden="true">⌖</span><span className={city.active ? styles.active : styles.archived}>{city.active ? "Available to players" : "Not open yet"}</span></div>
      <h3>{city.displayName}, {city.state}</h3><p>{city.countryCode} · {city.timezone}</p><div className={styles.actions}><button className="admin-secondary-button" type="button" onClick={() => setEditing(city)}>Edit city</button></div>
    </article>)}</div>}
  </div>;
}

function CityEditor({ accessToken, city, existingIds, onCancel, onSaved }: { accessToken: string; city: AdminCity | null; existingIds: string[]; onCancel: () => void; onSaved: (city: AdminCity) => void }) {
  const [id, setId] = useState(city?.id ?? "");
  const [displayName, setName] = useState(city?.displayName ?? "");
  const [state, setState] = useState(city?.state ?? "");
  const [countryCode, setCountry] = useState(city?.countryCode ?? "US");
  const [timezone, setTimezone] = useState(city?.timezone ?? "");
  const [active, setActive] = useState(city?.active ?? false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (saving) return;
    if (!city && existingIds.includes(id)) { setError("That city ID already exists. Edit the saved city instead."); return; }
    setSaving(true); setError(null);
    try { const result = await cityRequest<{ city: AdminCity }>(accessToken, `/${encodeURIComponent(id)}`, { method: "PUT", body: JSON.stringify({ displayName, state, countryCode, timezone, active }) }); onSaved(result.city); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "Could not save city."); }
    finally { setSaving(false); }
  }
  return <form className={styles.editor} onSubmit={(event) => void save(event)}>
    <button className={styles.back} type="button" disabled={saving} onClick={onCancel}>← All cities</button>
    <header><span className="admin-eyebrow">Competition city</span><h2>{city ? "Edit city" : "Add a city"}</h2><p>Use the metro area players recognize. For example, pitches in Tempe can belong to Phoenix.</p></header>
    {error ? <div className="admin-banner danger" role="alert">{error}</div> : null}
    <fieldset disabled={saving} className={styles.formFields}><section>
      <label><span>City name</span><input required minLength={2} maxLength={80} value={displayName} onChange={(event) => { setName(event.target.value); if (!city) setId(event.target.value.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")); }} placeholder="Phoenix" /></label>
      <label><span>Permanent city ID</span><input required readOnly={Boolean(city)} pattern="[a-z][a-z0-9]*(-[a-z0-9]+)*" maxLength={60} value={id} onChange={(event) => setId(event.target.value)} placeholder="phoenix" /><small>Stable ID used by fields, bookings and rankings. It cannot be renamed after creation.</small></label>
      <div className={styles.row}><label><span>State / region</span><input required maxLength={80} value={state} onChange={(event) => setState(event.target.value)} placeholder="AZ" /></label><label><span>Country code</span><input required minLength={2} maxLength={2} pattern="[A-Za-z]{2}" value={countryCode} onChange={(event) => setCountry(event.target.value.toUpperCase())} /></label></div>
      <label><span>IANA timezone</span><input required value={timezone} maxLength={80} onChange={(event) => setTimezone(event.target.value)} placeholder="America/Phoenix" /><small>Used for new games and recurring schedules, including daylight-saving changes where applicable. Existing game times stay unchanged.</small></label>
      <label className={styles.toggle}><input type="checkbox" checked={active} onChange={(event) => setActive(event.target.checked)} /> Available to players and new game creation</label>
      <p>Turning this off prevents new selections and games here. Existing bookings, history and earned rankings remain intact.</p>
    </section></fieldset>
    <footer className={styles.editorFooter}><p>New cities start closed until you choose to make them available.</p><button className="admin-primary-button" type="submit" disabled={saving}>{saving ? "Saving city…" : "Save city"}</button></footer>
  </form>;
}
