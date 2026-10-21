"use client";

import { useCallback, useEffect, useState, type FormEvent } from "react";
import { LoadingSkeleton } from "@/components/loading-skeleton";
import type { AdminField } from "@/lib/admin-fields";
import type { AdminGameSchedule } from "@/lib/admin-game-schedules";
import { cityKickoffToUtc, cityToday, DEFAULT_SOLO_FORMATION, parseSoloFormation, parseSoloMinimumPlayers, type SoloFormation } from "@/lib/admin-solo-games";
import { SoloFormationFields } from "./solo-formation-fields";
import styles from "./schedules-panel.module.css";

const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const DRAFT_KEY = "fieldrush-schedule-field-return-draft";
type ScheduleDraft = SoloFormation & { scheduleId: string | null; knownFieldIds: string[]; name: string; fieldId: string; weekdays: number[]; kickoffTime: string; durationMinutes: string; startsOn: string; endsOn: string; bookingWindowDays: string; priceUsd: string; ageLabel: string; highestDivision: string; lowestDivision: string; minimumPlayers: number; isActive: boolean };
type Props = { accessToken: string; onAddField: () => void; refreshKey?: number; newlyAddedFieldId?: string | null };

function readReturnDraft(): ScheduleDraft | null {
  try {
    const value = JSON.parse(sessionStorage.getItem(DRAFT_KEY) || "null") as ScheduleDraft | null;
    if (value && value.highestDivision === undefined) value.highestDivision = "1";
    if (value && value.lowestDivision === undefined) value.lowestDivision = "5";
    if (value && value.minimumPlayers === undefined) value.minimumPlayers = 10;
    if (value && value.goalkeepersPerSide === undefined) Object.assign(value, value.scheduleId ? { goalkeepersPerSide: 1, defendersPerSide: 3, attackersPerSide: 3 } : DEFAULT_SOLO_FORMATION);
    if (!value || !["name", "fieldId", "kickoffTime", "durationMinutes", "startsOn", "endsOn", "bookingWindowDays", "priceUsd", "ageLabel", "highestDivision", "lowestDivision"].every((key) => typeof value[key as keyof ScheduleDraft] === "string") || typeof value.isActive !== "boolean" || !Array.isArray(value.weekdays) || !value.weekdays.every((day) => Number.isInteger(day) && day >= 1 && day <= 7) || !Array.isArray(value.knownFieldIds) || !value.knownFieldIds.every((id) => typeof id === "string") || !(value.scheduleId === null || typeof value.scheduleId === "string")) return null;
    parseSoloFormation(value);
    parseSoloMinimumPlayers(value.minimumPlayers);
    return value;
  } catch { return null; }
}

function clearReturnDraft() { try { sessionStorage.removeItem(DRAFT_KEY); } catch { /* Storage may be disabled. */ } }

async function request<T>(token: string, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`/api/referee/admin/game-schedules${path}`, {
    ...init, cache: "no-store",
    headers: { "Content-Type": "application/json", authorization: `Bearer ${token}` },
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "Could not update this schedule. Please try again.");
  return data as T;
}

function prettyDate(value: string) {
  return new Intl.DateTimeFormat("en-US", { weekday: "short", month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }).format(new Date(`${value}T12:00:00Z`));
}

function timeLabel(value: string) {
  const [hour, minute] = value.split(":").map(Number);
  return `${hour % 12 || 12}:${String(minute).padStart(2, "0")} ${hour >= 12 ? "PM" : "AM"}`;
}

function daysLabel(days: number[]) { return [...days].sort((a, b) => a - b).map((day) => DAYS[day - 1]).join(", "); }

function previewDates(weekdays: number[], startsOn: string, endsOn: string, windowDays: number, kickoffTime: string, excludedDates: string[], timezone: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(startsOn) || !/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(kickoffTime) || !Number.isInteger(windowDays) || windowDays < 7 || windowDays > 84) return [];
  if (!timezone) return [];
  const today = cityToday(timezone);
  const last = new Date(`${today}T12:00:00Z`);
  last.setUTCDate(last.getUTCDate() + windowDays - 1);
  const cursor = new Date(`${startsOn > today ? startsOn : today}T12:00:00Z`);
  const dates: string[] = [];
  while (cursor <= last && dates.length < 5) {
    const date = cursor.toISOString().slice(0, 10);
    if (endsOn && date > endsOn) break;
    try {
      const kickoff = new Date(cityKickoffToUtc(date, kickoffTime, timezone));
      if (weekdays.includes(cursor.getUTCDay() || 7) && kickoff.getTime() > Date.now() && !excludedDates.includes(date)) dates.push(date);
    } catch { /* Invalid daylight-saving wall times are not previewed. */ }
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
  return dates;
}

export function SchedulesPanel({ accessToken, onAddField, refreshKey = 0, newlyAddedFieldId }: Props) {
  const [schedules, setSchedules] = useState<AdminGameSchedule[]>([]);
  const [fields, setFields] = useState<AdminField[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [editing, setEditing] = useState<AdminGameSchedule | "new" | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [skipping, setSkipping] = useState<string | null>(null);
  const [returnDraft, setReturnDraft] = useState<ScheduleDraft | null>(null);

  function addFirstField() {
    const draft: ScheduleDraft = { scheduleId: null, knownFieldIds: fields.map((field) => field.id), name: "Saturday football", fieldId: "", weekdays: [6], kickoffTime: "20:30", durationMinutes: "60", startsOn: cityToday(fields.find((field) => field.marketActive)?.marketTimezone || "America/Phoenix"), endsOn: "", bookingWindowDays: "28", priceUsd: "13.00", ageLabel: "18+", highestDivision: "1", lowestDivision: "5", minimumPlayers: 10, isActive: true, ...DEFAULT_SOLO_FORMATION };
    try { sessionStorage.setItem(DRAFT_KEY, JSON.stringify(draft)); }
    catch { setError("Your browser could not preserve the schedule draft. Please enable browser storage and try again."); return; }
    onAddField();
  }

  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const data = await request<{ schedules: AdminGameSchedule[]; fields: AdminField[] }>(accessToken, "");
      setSchedules(data.schedules); setFields(data.fields);
      const draft = readReturnDraft();
      if (draft) {
        const original = draft.scheduleId ? data.schedules.find((item) => item.id === draft.scheduleId) : null;
        if (!draft.scheduleId || original) { setReturnDraft(draft); setEditing(original ?? "new"); }
        else clearReturnDraft();
      }
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not load schedules."); }
    finally { setLoading(false); }
  }, [accessToken]);
  useEffect(() => { void load(); }, [load, refreshKey]);

  async function mutate(schedule: AdminGameSchedule, action: "toggle" | "generate") {
    setBusy(schedule.id); setError(null); setNotice(null);
    try {
      if (action === "toggle") {
        await request(accessToken, `/${schedule.id}`, { method: "PATCH", body: JSON.stringify({ isActive: !schedule.isActive }) });
        setNotice(schedule.isActive ? `${schedule.name} paused. Existing games and bookings are unchanged.` : `${schedule.name} resumed. Upcoming eligible games can open for booking.`);
      } else {
        const result = await request<{ created: number; conflicts: number; skipped: number }>(accessToken, `/${schedule.id}/generate`, { method: "POST", body: "{}" });
        setNotice(`${result.created} new ${result.created === 1 ? "game" : "games"} created. ${result.conflicts} ${result.conflicts === 1 ? "conflict" : "conflicts"}; ${result.skipped} skipped. Existing games were not duplicated or changed.`);
      }
      await load();
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not update the schedule."); }
    finally { setBusy(null); }
  }

  async function restoreDate(schedule: AdminGameSchedule, matchDate: string) {
    setBusy(schedule.id); setError(null); setNotice(null);
    try {
      await request(accessToken, `/${schedule.id}/skip`, { method: "POST", body: JSON.stringify({ matchDate, reason: "", skip: false }) });
      setNotice(`${prettyDate(matchDate)} restored to the schedule. Existing games are unchanged.`);
      await load();
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not restore this date."); }
    finally { setBusy(null); }
  }

  if (editing !== null) return <ScheduleEditor key={editing === "new" ? "new" : editing.id} accessToken={accessToken} fields={fields} schedule={editing === "new" ? null : editing} returnDraft={returnDraft} newlyAddedFieldId={newlyAddedFieldId} onAddField={onAddField} onCancel={() => { clearReturnDraft(); setReturnDraft(null); setEditing(null); }} onSaved={() => {
    setNotice(editing === "new" ? "Schedule saved. Eligible games in its booking window are now generated; check the dates below for any conflicts." : "Schedule updated. Games already created and their bookings have not changed.");
    clearReturnDraft(); setReturnDraft(null); setEditing(null); void load();
  }} />;

  return <div className={styles.stack}>
    <section className={styles.intro}><div><span className="admin-eyebrow">Games · Schedules</span><h2>Make game night a regular thing.</h2><p>Choose the days, pitch and price once. New games open automatically inside your booking window.</p></div><button className="admin-primary-button" type="button" disabled={loading || error !== null} onClick={() => setEditing("new")}>+ Add schedule</button></section>
    {error ? <div role="alert" className="admin-banner danger"><span>{error}</span><button type="button" onClick={() => void load()}>Try again</button></div> : null}
    {notice ? <div role="status" className="admin-banner success">{notice}</div> : null}
    <p className={styles.hint}>Times use each field’s competition-city timezone. Editing, pausing or skipping a schedule never moves or cancels a game that already exists.</p>
    {loading ? <LoadingSkeleton label="Loading schedules" /> : !schedules.length && !error ? <section className={styles.empty}><h3>Your week, on repeat.</h3><p>For example: every Saturday at 8:30 PM, with 60-minute games and bookings available four weeks ahead.</p><button className="admin-primary-button" type="button" onClick={() => fields.some((field) => field.isActive && field.marketActive) ? setEditing("new") : addFirstField()}>{fields.some((field) => field.isActive && field.marketActive) ? "Create your first schedule" : "Add a field first"}</button></section> : <div className={styles.cards}>{schedules.map((schedule) => <article key={schedule.id} className={styles.card} aria-label={schedule.name}>
      <header className={styles.cardHeader}><div><span className={schedule.isActive ? styles.active : styles.paused}>{schedule.isActive ? "Active" : "Paused"}</span><h3>{schedule.name}</h3><p>{schedule.fieldName}</p></div><button type="button" className="admin-secondary-button" disabled={busy !== null} onClick={() => setEditing(schedule)}>Edit schedule</button></header>
      <p className={styles.summary}>Every {daysLabel(schedule.weekdays)} · {timeLabel(schedule.kickoffTime)} · {schedule.timezone} · {schedule.durationMinutes} minutes</p>
      <div className={styles.facts}><span><strong>${Number(schedule.priceUsd).toFixed(2)}</strong> per player</span><span><strong>{schedule.goalkeepersPerSide} GK · {schedule.defendersPerSide} DEF · {schedule.attackersPerSide} ATT</strong> per team maximum</span><span><strong>{schedule.minimumPlayers} players</strong> minimum · 14 maximum</span><span><strong>Division {schedule.highestDivision}–{schedule.lowestDivision}</strong></span><span><strong>{schedule.bookingWindowDays} days</strong> booking window</span><span>From <strong>{prettyDate(schedule.startsOn)}</strong>{schedule.endsOn ? <> to <strong>{prettyDate(schedule.endsOn)}</strong></> : " · No end date"}</span></div>
      <div className={styles.actions}><button className="admin-secondary-button" type="button" disabled={busy !== null} onClick={() => void mutate(schedule, "toggle")}>{busy === schedule.id ? "Updating…" : schedule.isActive ? "Pause schedule" : "Resume schedule"}</button><button className={styles.quiet} type="button" disabled={busy !== null || !schedule.isActive} onClick={() => void mutate(schedule, "generate")}>Generate next games</button><button className={styles.quiet} type="button" disabled={busy !== null} onClick={() => setSkipping(skipping === schedule.id ? null : schedule.id)}>Skip a date</button></div>
      {!schedule.isActive ? <p className={styles.hint}>Paused: no new games will be generated. Already-created games stay open.</p> : null}
      {skipping === schedule.id ? <SkipDateForm accessToken={accessToken} schedule={schedule} onCancel={() => setSkipping(null)} onSaved={() => { setSkipping(null); setNotice("Date skipped. If a game already exists on that date, open it to cancel it separately."); void load(); }} /> : null}
      <details className={styles.details} open={schedule.occurrences.some((item) => item.status === "CONFLICT")}><summary>Dates &amp; exceptions <span>{schedule.occurrences.filter((item) => item.status === "CONFLICT").length > 0 ? `${schedule.occurrences.filter((item) => item.status === "CONFLICT").length} need attention` : "View generated games"}</span></summary>
        {schedule.skips.length ? <ul className={styles.dateList} aria-label="Skipped dates">{schedule.skips.map((skip) => <li key={skip.matchDate}><div><strong>{prettyDate(skip.matchDate)} · Skipped</strong><p>{skip.reason}</p></div><button type="button" className={styles.quiet} disabled={busy !== null} onClick={() => void restoreDate(schedule, skip.matchDate)}>Restore date</button></li>)}</ul> : null}
        {schedule.occurrences.length ? <ul className={styles.dateList} aria-label="Schedule game dates">{schedule.occurrences.map((item) => <li key={item.matchDate}><div><strong>{prettyDate(item.matchDate)}</strong><p className={item.status === "CONFLICT" ? styles.conflict : undefined}>{item.status === "CONFLICT" ? `Needs attention: ${item.errorMessage || "This time or field is unavailable."}` : item.status === "SKIPPED" ? "Skipped — no game created." : "Game created"}</p></div>{item.gameId ? <a href={`/admin/games/solo/${encodeURIComponent(item.gameId)}`} className={styles.gameLink}>Open game ↗</a> : null}</li>)}</ul> : <p className={styles.hint}>No games generated yet. Dates outside the booking window will be created when they enter it.</p>}
      </details>
    </article>)}</div>}
  </div>;
}

function ScheduleEditor({ accessToken, fields, schedule, returnDraft, newlyAddedFieldId, onAddField, onCancel, onSaved }: { accessToken: string; fields: AdminField[]; schedule: AdminGameSchedule | null; returnDraft: ScheduleDraft | null; newlyAddedFieldId?: string | null; onAddField: () => void; onCancel: () => void; onSaved: () => void }) {
  const addedFields = returnDraft ? fields.filter((field) => field.isActive && field.marketActive && !returnDraft.knownFieldIds.includes(field.id)) : [];
  const [name, setName] = useState(returnDraft?.name ?? schedule?.name ?? "Saturday football");
  const [fieldId, setFieldId] = useState((returnDraft ? newlyAddedFieldId : undefined) ?? (addedFields.length === 1 ? addedFields[0].id : returnDraft?.fieldId) ?? schedule?.fieldId ?? "");
  const [weekdays, setWeekdays] = useState(returnDraft?.weekdays ?? schedule?.weekdays ?? [6]);
  const [kickoffTime, setKickoffTime] = useState(returnDraft?.kickoffTime ?? schedule?.kickoffTime ?? "20:30");
  const [durationMinutes, setDuration] = useState(returnDraft?.durationMinutes ?? String(schedule?.durationMinutes ?? 60));
  const [startsOn, setStartsOn] = useState(returnDraft?.startsOn ?? schedule?.startsOn ?? cityToday(fields.find((field) => field.id === fieldId)?.marketTimezone || "America/Phoenix"));
  const [endsOn, setEndsOn] = useState(returnDraft?.endsOn ?? schedule?.endsOn ?? "");
  const [bookingWindowDays, setWindow] = useState(returnDraft?.bookingWindowDays ?? String(schedule?.bookingWindowDays ?? 28));
  const [priceUsd, setPrice] = useState(returnDraft?.priceUsd ?? schedule?.priceUsd ?? "13.00");
  const [ageLabel, setAge] = useState(returnDraft?.ageLabel ?? schedule?.ageLabel ?? "18+");
  const [highestDivision, setHighestDivision] = useState(returnDraft?.highestDivision ?? String(schedule?.highestDivision ?? 1));
  const [lowestDivision, setLowestDivision] = useState(returnDraft?.lowestDivision ?? String(schedule?.lowestDivision ?? 5));
  const [minimumPlayers, setMinimumPlayers] = useState(returnDraft?.minimumPlayers ?? schedule?.minimumPlayers ?? 10);
  const [formation, setFormation] = useState<SoloFormation>(returnDraft ? {
    goalkeepersPerSide: returnDraft.goalkeepersPerSide, defendersPerSide: returnDraft.defendersPerSide, attackersPerSide: returnDraft.attackersPerSide,
  } : schedule ? {
    goalkeepersPerSide: schedule.goalkeepersPerSide, defendersPerSide: schedule.defendersPerSide, attackersPerSide: schedule.attackersPerSide,
  } : DEFAULT_SOLO_FORMATION);
  const [isActive, setActive] = useState(returnDraft?.isActive ?? schedule?.isActive ?? true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const activeFields = fields.filter((field) => field.isActive && field.marketActive);
  const selectedField = activeFields.find((field) => field.id === fieldId);
  const canConfigureMinimum = !schedule || schedule.participationRulesVersion === "s0-configurable-v1";
  const dates = previewDates(weekdays, startsOn, endsOn, Number(bookingWindowDays), kickoffTime, [...(schedule?.skips.map((item) => item.matchDate) ?? []), ...(schedule?.occurrences.filter((item) => item.status === "CREATED").map((item) => item.matchDate) ?? [])], selectedField?.marketTimezone ?? "");

  function addField() {
    const draft: ScheduleDraft = { scheduleId: schedule?.id ?? null, knownFieldIds: fields.map((field) => field.id), name, fieldId, weekdays, kickoffTime, durationMinutes, startsOn, endsOn, bookingWindowDays, priceUsd, ageLabel, highestDivision, lowestDivision, minimumPlayers, isActive, ...formation };
    try { sessionStorage.setItem(DRAFT_KEY, JSON.stringify(draft)); }
    catch { setError("Your browser could not preserve this draft. Save or copy your details before leaving to add a field."); return; }
    onAddField();
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving) return;
    if (!selectedField) { setError("Choose an active saved field. Archived fields cannot receive new games."); return; }
    if (weekdays.length === 0) { setError("Choose at least one day of the week."); return; }
    if (endsOn && endsOn < startsOn) { setError("The end date must be on or after the start date."); return; }
    const priceFils = /^\d{1,3}(?:\.\d{1,2})?$/.test(priceUsd.trim()) ? Math.round(Number(priceUsd.trim()) * 1000) : null;
    if (priceFils === null || priceFils > 100_000 || (priceFils !== 0 && priceFils < 500)) { setError("Use $0 for a free game, or $0.50–$100 with up to 2 decimals."); return; }
    if (Number(highestDivision) > Number(lowestDivision)) { setError("Highest division must be less than or equal to lowest division."); return; }
    setSaving(true); setError(null);
    try {
      parseSoloFormation(formation);
      parseSoloMinimumPlayers(minimumPlayers);
      await request(accessToken, schedule ? `/${schedule.id}` : "", { method: schedule ? "PATCH" : "POST", body: JSON.stringify({ name, fieldId, weekdays: [...weekdays].sort((a, b) => a - b), kickoffTime, durationMinutes: Number(durationMinutes), startsOn, endsOn: endsOn || null, bookingWindowDays: Number(bookingWindowDays), priceUsd, ageLabel, highestDivision: Number(highestDivision), lowestDivision: Number(lowestDivision), minimumPlayers, isActive, ...formation }) });
      onSaved();
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not save the schedule."); }
    finally { setSaving(false); }
  }

  return <form className={styles.editor} onSubmit={(event) => void save(event)}>
    <button className={styles.back} type="button" disabled={saving} onClick={onCancel}>← All schedules</button>
    <header><span className="admin-eyebrow">A reliable weekly rhythm</span><h2>{schedule ? "Edit schedule" : "Add a schedule"}</h2><p>One saved schedule can run on one or several days every week. The field’s competition city sets the timezone.</p></header>
    {error ? <div role="alert" className="admin-banner danger">{error}</div> : null}
    <fieldset className={styles.formFields} disabled={saving}>
      <section><h3>1. Where &amp; when</h3><label><span>Schedule name</span><input required minLength={2} maxLength={80} value={name} onChange={(event) => setName(event.target.value)} /></label>
        {activeFields.length ? <><label><span>Field / pitch</span><select required aria-label="Field / pitch" aria-describedby="schedule-field-help" value={selectedField ? fieldId : ""} onChange={(event) => setFieldId(event.target.value)}><option value="">Choose a saved field</option>{activeFields.map((field) => <option key={field.id} value={field.id}>{field.name} · {field.marketCityName} · {field.address}</option>)}</select><small id="schedule-field-help">Games use this field’s saved address, map pin and competition city.</small></label><button className={styles.back} type="button" onClick={addField}>+ Add a new field</button></> : <div className={styles.help}><strong>Add a field before scheduling games.</strong><p>No active fields in an available city are saved yet. Create a pitch with its address and map pin first.</p><button className="admin-secondary-button" type="button" onClick={addField}>Add a field</button></div>}
        {schedule && !selectedField && activeFields.length ? <p className={styles.conflict}>This schedule’s saved field is no longer active. Choose an available field before saving.</p> : null}
        <fieldset className={styles.weekdays}><legend>Repeat every week on</legend>{DAYS.map((day, index) => <label key={day}><input type="checkbox" checked={weekdays.includes(index + 1)} onChange={(event) => setWeekdays((current) => event.target.checked ? [...current, index + 1] : current.filter((value) => value !== index + 1))} /><span>{day}</span></label>)}</fieldset>
        <div className={styles.row}><label><span>Kickoff time</span><input required type="time" aria-label="Kickoff time" aria-describedby="schedule-time-help" value={kickoffTime} onChange={(event) => setKickoffTime(event.target.value)} /><small id="schedule-time-help">{selectedField ? `${selectedField.marketCityName} · ${selectedField.marketTimezone}` : "Choose a field to set its local timezone."}</small></label><label><span>Game duration (minutes)</span><input required type="number" aria-label="Game duration (minutes)" aria-describedby="schedule-duration-help" min={30} max={180} step={1} value={durationMinutes} onChange={(event) => setDuration(event.target.value)} /><small id="schedule-duration-help">30–180 minutes</small></label></div>
        <div className={styles.row}><label><span>Start date</span><input required type="date" value={startsOn} onChange={(event) => setStartsOn(event.target.value)} /></label><label><span>End date (optional)</span><input type="date" aria-label="End date (optional)" aria-describedby="schedule-end-help" min={startsOn} value={endsOn} onChange={(event) => setEndsOn(event.target.value)} /><small id="schedule-end-help">Leave empty to keep repeating.</small></label></div>
      </section>
      <section><h3>2. Bookings</h3><div className={styles.row}><label><span>Price per player (USD)</span><input required type="number" aria-label="Price per player (USD)" aria-describedby="schedule-price-help" min={0} max={100} step="0.01" value={priceUsd} onChange={(event) => setPrice(event.target.value)} /><small id="schedule-price-help">Use $0 for free, or $0.50–$100 with up to 2 decimals. Applies to newly generated games only.</small></label><label><span>Booking window (days ahead)</span><input required type="number" aria-label="Booking window (days ahead)" aria-describedby="schedule-window-help" min={7} max={84} step={1} value={bookingWindowDays} onChange={(event) => setWindow(event.target.value)} /><small id="schedule-window-help">7–84 days. 28 days means four weeks ahead.</small></label></div>
        <div className={styles.row}><label><span>Highest division</span><select required aria-label="Highest division" value={highestDivision} onChange={(event) => setHighestDivision(event.target.value)}>{[1, 2, 3, 4, 5].map((division) => <option key={division} value={division}>Division {division}</option>)}</select></label><label><span>Lowest division</span><select required aria-label="Lowest division" value={lowestDivision} onChange={(event) => setLowestDivision(event.target.value)}>{[1, 2, 3, 4, 5].map((division) => <option key={division} value={division}>Division {division}</option>)}</select></label></div>
        <small>Division 1 is highest and Division 5 is lowest.</small>
        <small>The booked position determines the rating used. Placement players (fewer than 2 games in that track) can only book unrestricted Division 1–5 games.</small>
        <label><span>Age label</span><input required maxLength={40} value={ageLabel} onChange={(event) => setAge(event.target.value)} /></label>
        <SoloFormationFields value={formation} onChange={setFormation} disabled={saving} />
        <label><span>Minimum players (both teams)</span><input required disabled={!canConfigureMinimum} type="number" min={2} max={14} step={1} value={minimumPlayers || ""} onChange={(event) => setMinimumPlayers(Number(event.target.value))} /><small>{canConfigureMinimum ? "2–14 total, including one on each team. 2 allows 1v1. Bookings still allow up to 14. Play pauses below the saved total or when a team has no active players. Applies to newly generated games only." : "This existing schedule keeps the standard participation rules. Create a new schedule to choose a configurable minimum."}</small></label>
        <label className={styles.check}><input type="checkbox" checked={isActive} onChange={(event) => setActive(event.target.checked)} /><span>Active — automatically create upcoming games</span></label>
        <div className={styles.help}>{isActive ? "Saving an active schedule opens eligible upcoming games for booking immediately. The generator keeps filling the booking window over time." : "This schedule will be saved paused. It will not create games until you resume it."} Existing games, prices, bookings and refunds are never changed by editing a schedule.</div>
      </section>
    </fieldset>
    <section className={styles.preview} aria-label="Schedule preview"><span className="admin-eyebrow">At a glance</span><h3>{weekdays.length ? `Every ${daysLabel(weekdays)}` : "Choose your game days"}{kickoffTime ? ` · ${timeLabel(kickoffTime)}` : ""}</h3><p>{selectedField?.name ?? "Choose a saved field"} · {durationMinutes || "—"} minutes · ${priceUsd || "—"} per player</p>{dates.length ? <><p>Next dates inside the booking window:</p><ul>{dates.map((date) => <li key={date}>{prettyDate(date)}</li>)}</ul></> : <p>No matching dates in the current booking window. Future dates will become eligible as the window advances.</p>}<small>This is a preview. Skipped dates, existing games and field conflicts are checked when games are generated.</small></section>
    <footer className={styles.editorFooter}><p>{schedule ? "Only games not yet created use these changes." : "You can pause this schedule or skip individual dates at any time."}</p><button className="admin-primary-button" type="submit" disabled={saving || activeFields.length === 0}>{saving ? "Saving schedule…" : schedule ? "Save changes" : "Save schedule"}</button></footer>
  </form>;
}

function SkipDateForm({ accessToken, schedule, onCancel, onSaved }: { accessToken: string; schedule: AdminGameSchedule; onCancel: () => void; onSaved: () => void }) {
  const [date, setDate] = useState("");
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (saving) return;
    setSaving(true); setError(null);
    try { await request(accessToken, `/${schedule.id}/skip`, { method: "POST", body: JSON.stringify({ matchDate: date, reason, skip: true }) }); onSaved(); }
    catch (cause) { setError(cause instanceof Error ? cause.message : "Could not skip this date."); }
    finally { setSaving(false); }
  }
  return <form className={styles.skipForm} onSubmit={(event) => void submit(event)} aria-label="Skip a scheduled date"><h4>Skip a date</h4><p>This stops a new game being created for this date. If a game already exists, cancel it from its game page so its bookings and refunds are handled properly.</p>{error ? <div className="admin-banner danger" role="alert">{error}</div> : null}<fieldset className={styles.formFields} disabled={saving}><div className={styles.row}><label><span>Date to skip</span><input required type="date" min={schedule.startsOn} max={schedule.endsOn ?? undefined} value={date} onChange={(event) => setDate(event.target.value)} /></label><label><span>Reason</span><input required minLength={3} maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} placeholder="e.g. Field closed for a holiday" /></label></div><div className={styles.actions}><button className="admin-primary-button" type="submit">{saving ? "Saving…" : "Confirm skip"}</button><button className={styles.quiet} type="button" onClick={onCancel}>Keep this date</button></div></fieldset></form>;
}
