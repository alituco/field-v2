"use client";

import { useCallback, useEffect, useState, type FormEvent } from "react";
import { LoadingSkeleton } from "@/components/loading-skeleton";
import type { AdminField } from "@/lib/admin-fields";
import type { AdminCity } from "@/lib/admin-cities";
import { parseFieldCoordinateInput } from "@/lib/field-coordinate-input";
import styles from "./fields-panel.module.css";

type Props = {
  accessToken: string;
  startAdding: boolean;
  returnToSolo: boolean;
  returnToSchedules?: boolean;
  refreshKey: number;
  onNavigate: (adding: boolean) => void;
  onReturnToGame: (field?: AdminField) => void;
};

async function fieldRequest<T>(token: string, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`/api/referee/admin/fields${path}`, {
    ...init,
    cache: "no-store",
    headers: { "Content-Type": "application/json", authorization: `Bearer ${token}` },
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "Could not save this field. Please try again.");
  return data as T;
}

export function FieldsPanel({ accessToken, startAdding, returnToSolo, returnToSchedules = false, refreshKey, onNavigate, onReturnToGame }: Props) {
  const [fields, setFields] = useState<AdminField[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [editing, setEditing] = useState<AdminField | null>(null);
  const [savingId, setSavingId] = useState<string | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const [search, setSearch] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await fieldRequest<{ fields: AdminField[] }>(accessToken, "");
      setFields(data.fields);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not load fields.");
    } finally {
      setLoading(false);
    }
  }, [accessToken]);

  useEffect(() => { void load(); }, [load, refreshKey]);

  async function setActive(field: AdminField) {
    setSavingId(field.id);
    setError(null);
    try {
      const { field: saved } = await fieldRequest<{ field: AdminField }>(accessToken, `/${field.id}`, {
        method: "PATCH", body: JSON.stringify({ isActive: !field.isActive }),
      });
      setFields((current) => current.map((item) => item.id === saved.id ? saved : item));
      setNotice(saved.isActive ? `${saved.name} is available for new games.` : `${saved.name} archived. Existing games keep their saved location.`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not update field.");
    } finally {
      setSavingId(null);
    }
  }

  async function setFeatured(field: AdminField) {
    setSavingId(field.id);
    setError(null);
    setNotice(null);
    try {
      const data = await fieldRequest<{ fields: AdminField[] }>(accessToken, `/${field.id}/feature`, {
        method: "PATCH", body: JSON.stringify({ cityId: field.marketCityId, featured: !field.isFeatured }),
      });
      setFields(data.fields);
      setNotice(field.isFeatured
        ? `Featured field removed for ${field.marketCityName}.`
        : `${field.name} is now the featured field for ${field.marketCityName}.`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not update the featured field.");
    } finally {
      setSavingId(null);
    }
  }

  if (startAdding || editing) {
    return <FieldEditor
      key={editing?.id ?? "new"}
      accessToken={accessToken}
      field={editing}
      returnToSolo={returnToSolo && !editing}
      returnToSchedules={returnToSchedules}
      onCancel={() => {
        setEditing(null);
        if (returnToSolo) onReturnToGame();
        else onNavigate(false);
      }}
      onSaved={(saved) => {
        setEditing(null);
        setFields((current) => [saved, ...current.filter((item) => item.id !== saved.id)]);
        if (returnToSolo) onReturnToGame(saved);
        else {
          onNavigate(false);
          setNotice(saved.isActive ? `${saved.name} saved. You can now assign it to a game.` : `${saved.name} updated. Restore it before assigning it to a new game.`);
        }
      }}
    />;
  }

  const active = fields.filter((field) => field.isActive);
  const visible = fields.filter((field) => (showArchived || field.isActive) &&
    `${field.name} ${field.address} ${field.city}`.toLowerCase().includes(search.toLowerCase().trim()));

  return <div className={styles.stack}>
    <section className={styles.intro}>
      <div><span className="admin-eyebrow">The places we play</span><h2>A home for every game.</h2><p>Save each pitch’s name, address and map pin. Choose one featured field per competition city for the green card players see when browsing games.</p></div>
      <button className="admin-primary-button" type="button" onClick={() => onNavigate(true)}>+ Add a field</button>
    </section>
    {error ? <div role="alert" className="admin-banner danger"><span>{error}</span><button type="button" onClick={() => void load()}>Try again</button></div> : null}
    {notice ? <div role="status" className="admin-banner success">{notice}</div> : null}
    <div className={styles.toolbar}>
      <label className={styles.search}><span className="sr-only">Search fields</span><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search fields or addresses" /></label>
      <label className={styles.toggle}><input type="checkbox" checked={showArchived} onChange={(event) => setShowArchived(event.target.checked)} /> Show archived</label>
      <span>{active.length} active {active.length === 1 ? "field" : "fields"}</span>
    </div>
    {loading ? <LoadingSkeleton label="Loading fields" />
      : !fields.length && !error ? <section className={styles.empty}><span className={styles.pitch} aria-hidden="true">＋</span><h3>Your first field goes here.</h3><p>Add a location before creating your first solo game. No placeholder venues or missing directions.</p><button type="button" className="admin-primary-button" onClick={() => onNavigate(true)}>Add your first field</button></section>
      : <div className={styles.grid}>{visible.map((field) => <article className={styles.card} key={field.id} aria-label={field.name}>
        <div className={styles.cardTop}><span className={styles.pitch} aria-hidden="true">⌖</span><div className={styles.badges}>{field.isFeatured ? <span className={styles.featured}>Featured</span> : null}<span className={field.isActive ? styles.active : styles.archived}>{field.isActive ? "Available" : "Archived"}</span></div></div>
        <h3>{field.name}</h3><p>{field.address}<br />{field.city}, {field.state} · {field.countryCode}</p><p><strong>{field.marketCityName || "No competition city"}</strong> · {field.marketTimezone}{!field.marketActive ? " · City not open" : ""}</p>
        <a className={styles.mapLink} href={mapsUrl(field.latitude, field.longitude)} target="_blank" rel="noreferrer">View map pin ↗</a>
        <div className={styles.featureActions}><button className="admin-secondary-button" type="button" disabled={savingId !== null || (!field.isFeatured && (!field.isActive || !field.marketActive))} onClick={() => void setFeatured(field)}>{field.isFeatured ? "Remove feature" : "Feature in player app"}</button></div>
        <div className={styles.actions}><button className="admin-secondary-button" type="button" onClick={() => setEditing(field)}>Edit field</button><button className={styles.quiet} type="button" disabled={savingId !== null} onClick={() => void setActive(field)}>{savingId === field.id ? "Saving…" : field.isActive ? "Archive" : "Restore"}</button></div>
      </article>)}</div>}
    {!loading && fields.length > 0 && visible.length === 0 ? <p className={styles.empty}>No fields match this view. Try another search or show archived fields.</p> : null}
  </div>;
}

function mapsUrl(latitude: number, longitude: number) {
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${latitude},${longitude}`)}`;
}

function FieldEditor({ accessToken, field, returnToSolo, returnToSchedules, onCancel, onSaved }: {
  accessToken: string; field: AdminField | null; returnToSolo: boolean;
  returnToSchedules: boolean;
  onCancel: () => void; onSaved: (field: AdminField) => void;
}) {
  const [name, setName] = useState(field?.name ?? "");
  const [address, setAddress] = useState(field?.address ?? "");
  const [city, setCity] = useState(field?.city ?? "Phoenix");
  const [state, setState] = useState(field?.state ?? "AZ");
  const [countryCode, setCountryCode] = useState(field?.countryCode ?? "US");
  const [marketCityId, setMarketCityId] = useState(field?.marketCityId ?? "");
  const [cities, setCities] = useState<AdminCity[]>([]);
  const [citiesLoading, setCitiesLoading] = useState(true);
  const [latitude, setLatitude] = useState(field ? String(field.latitude) : "");
  const [longitude, setLongitude] = useState(field ? String(field.longitude) : "");
  const [saving, setSaving] = useState(false);
  const [checkedCoordinates, setCheckedCoordinates] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const lat = parseFieldCoordinateInput(latitude, "latitude");
  const lng = parseFieldCoordinateInput(longitude, "longitude");
  const validPin = lat !== null && lng !== null;

  useEffect(() => {
    let active = true;
    void fetch("/api/referee/admin/cities", { cache: "no-store", headers: { authorization: `Bearer ${accessToken}` } })
      .then(async (response) => { const payload = await response.json(); if (!response.ok) throw new Error(payload.error || "Could not load cities."); return payload.cities as AdminCity[]; })
      .then((items) => { if (!active) return; setCities(items); if (!field && items.filter((item) => item.active).length === 1) setMarketCityId(items.find((item) => item.active)!.id); })
      .catch((cause) => { if (active) setError(cause instanceof Error ? cause.message : "Could not load cities."); })
      .finally(() => { if (active) setCitiesLoading(false); });
    return () => { active = false; };
  }, [accessToken, field]);
  const selectedMarket = cities.find((item) => item.id === marketCityId);

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving) return;
    setCheckedCoordinates(true);
    if (!validPin) {
      setError("Check the map coordinates below. No field has been saved.");
      event.currentTarget.querySelector<HTMLInputElement>(lat === null ? "#field-latitude" : "#field-longitude")?.focus();
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const { field: saved } = await fieldRequest<{ field: AdminField }>(accessToken, field ? `/${field.id}` : "", {
        method: field ? "PATCH" : "POST",
        body: JSON.stringify({ name, address, city, state, countryCode, marketCityId, latitude: lat, longitude: lng, ...(field ? { isActive: field.isActive } : {}) }),
      });
      onSaved(saved);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not save field.");
    } finally {
      setSaving(false);
    }
  }

  return <form className={styles.editor} onSubmit={(event) => void save(event)}>
    <button type="button" className={styles.back} disabled={saving} onClick={onCancel}>← {returnToSchedules ? "Back to schedules" : returnToSolo ? "Back to games" : "All fields"}</button>
    <header><span className="admin-eyebrow">{field ? "Field details" : "Set the scene"}</span><h2>{field ? "Edit field" : "Add a field"}</h2><p>{returnToSchedules ? "Save the pitch, then return to your recurring schedule." : returnToSolo ? "First, save the pitch. Then you’ll return to your solo game with this field selected." : "Use the exact pitch name and entrance location so players know where to meet."}</p></header>
    {error ? <div role="alert" className="admin-banner danger">{error}</div> : null}
    <fieldset disabled={saving} className={styles.formFields}>
      <section><div className={styles.step}><span>01</span><div><h3>The field</h3><p>Name the pitch—not just the sports complex.</p></div></div>
        <label><span>Competition city <em>Required</em></span><select required disabled={citiesLoading} value={marketCityId} onChange={(event) => setMarketCityId(event.target.value)}><option value="">{citiesLoading ? "Loading cities…" : "Choose a city"}</option>{cities.filter((item) => item.active || item.id === field?.marketCityId).map((item) => <option key={item.id} value={item.id}>{item.displayName}, {item.state}{!item.active ? " (not open)" : ""}</option>)}</select><small>{selectedMarket ? `${selectedMarket.timezone} · This city controls game discovery, rankings and scheduling. The postal city below can be different.` : "Set up cities in the Cities section before adding fields."}</small></label>
        <label><span>Field / pitch name <em>Required</em></span><input required minLength={2} maxLength={80} value={name} onChange={(event) => setName(event.target.value)} placeholder="e.g. Encanto Park · Pitch 1" /></label>
        <label><span>Street address <em>Required</em></span><input required minLength={5} maxLength={240} value={address} onChange={(event) => setAddress(event.target.value)} placeholder="Street address, entrance or pitch access" autoComplete="street-address" /></label>
        <div className={styles.row}><label><span>City</span><input required maxLength={80} value={city} onChange={(event) => setCity(event.target.value)} autoComplete="address-level2" /></label><label><span>State / region</span><input required maxLength={80} value={state} onChange={(event) => setState(event.target.value)} autoComplete="address-level1" /></label><label><span>Country code</span><input required minLength={2} maxLength={2} pattern="[A-Za-z]{2}" value={countryCode} onChange={(event) => setCountryCode(event.target.value.toUpperCase())} autoComplete="country" /><small>Two letters, e.g. US</small></label></div>
      </section>
      <section><div className={styles.step}><span>02</span><div><h3>A precise meeting point</h3><p>The app’s Directions button will use this pin.</p></div></div>
        <div className={styles.help}>Open your map, right-click the pitch or entrance, and copy its coordinates. The first number is latitude; the second is longitude. We won’t guess a location from the name.</div>
        <div className={styles.row}>
          <label>
            <span>Latitude <em>Required</em></span>
            <input id="field-latitude" name="latitude" required type="text" inputMode="text" autoComplete="off" spellCheck={false}
              aria-invalid={checkedCoordinates && lat === null}
              aria-describedby="field-latitude-hint"
              value={latitude} onChange={(event) => setLatitude(event.target.value)} placeholder="e.g. 33.47" />
            <small id="field-latitude-hint" className={checkedCoordinates && lat === null ? styles.coordinateError : undefined}>
              {checkedCoordinates && lat === null ? "Enter a latitude from −90 to 90, e.g. 33.47." : "Between −90 and 90."}
            </small>
          </label>
          <label>
            <span>Longitude <em>Required</em></span>
            <input id="field-longitude" name="longitude" required type="text" inputMode="text" autoComplete="off" spellCheck={false}
              aria-invalid={checkedCoordinates && lng === null}
              aria-describedby="field-longitude-hint"
              value={longitude} onChange={(event) => setLongitude(event.target.value)} placeholder="e.g. -112.09" />
            <small id="field-longitude-hint" className={checkedCoordinates && lng === null ? styles.coordinateError : undefined}>
              {checkedCoordinates && lng === null ? "Enter a longitude from −180 to 180, e.g. -111.975201." : "Between −180 and 180. Keep the minus sign for western longitudes."}
            </small>
          </label>
        </div>
        {validPin ? <a className={styles.pinPreview} href={mapsUrl(lat, lng)} target="_blank" rel="noreferrer"><span>⌖</span><div><strong>Check this map pin</strong><small>{lat}, {lng} · Opens in Google Maps</small></div><span>↗</span></a> : <p className={styles.pinHint}>Add both coordinates to preview the map pin.</p>}
      </section>
    </fieldset>
    <footer className={styles.editorFooter}><p>{field ? "Changes apply to future game creation. Existing games retain their booked location and competition city." : "Saving a field does not create a game or open bookings."}</p><button className="admin-primary-button" type="submit" disabled={saving || citiesLoading || !selectedMarket}>{saving ? "Saving field…" : returnToSolo ? "Save field & continue" : "Save field"}</button></footer>
  </form>;
}
