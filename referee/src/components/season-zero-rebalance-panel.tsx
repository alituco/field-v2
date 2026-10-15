"use client";

import { useRef, useState, type FormEvent } from "react";
import type { RefereeFixture } from "@/lib/types";
import styles from "./season-zero-operations.module.css";

export function SeasonZeroRebalancePanel({ fixture, accessToken, submitting, onSaved }: {
  fixture: RefereeFixture; accessToken: string; submitting?: string | null; onSaved: () => void | Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [targets, setTargets] = useState<Record<string, string>>({});
  const [consents, setConsents] = useState<Record<string, boolean>>({});
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const request = useRef<{ content: string; id: string } | null>(null);
  const beforeKickoff = ["OPEN", "FULL"].includes(fixture.status) &&
    (!fixture.clock || (fixture.clock.status === "NOT_STARTED" && !fixture.clock.startedAt && fixture.clock.accumulatedSeconds === 0));
  if (!beforeKickoff) return null;
  const players = fixture.players;
  const hasPriorTeam = (team: string) => ["WHITE", "BLACK"].includes(team);
  const retainedTeams = players.some(player => hasPriorTeam(player.clanId));
  const validRosterSize = players.length >= 10 && players.length <= 14;
  const canEdit = retainedTeams && fixture.operationalState === "NORMAL" && validRosterSize;
  const moves = players.filter(player => targets[player.id] && targets[player.id] !== player.clanId);
  const presence = (id: string) => fixture.reliabilityContext?.players.find(player => player.profileId === id)?.isCheckedIn;
  const consentMissing = moves.some(player => hasPriorTeam(player.clanId) && presence(player.id) === true && !consents[player.id]);
  const unassignedRemaining = players.some(player => !hasPriorTeam(targets[player.id] ?? player.clanId));
  const locked = saving || Boolean(submitting);

  async function assign() {
    if (locked || fixture.teamsAssignedAt || fixture.operationalState !== "NORMAL" || !validRosterSize) return;
    const content = JSON.stringify({ action: "assign_teams" });
    if (request.current?.content !== content) request.current = { content, id: crypto.randomUUID() };
    setSaving(true); setError(null); setNotice(null);
    try {
      const response = await fetch(`/api/referee/open-queue-games/${fixture.id}/action`, {
        method: "POST", headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ action: "assign_teams", requestId: request.current.id }),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.error ?? "Could not assign the booked players.");
      if (payload.ok !== true || payload.assignment?.game_id !== fixture.id || payload.assignment?.action !== "ASSIGN") throw new Error("Assignment was not acknowledged. Retry this same request before starting the game.");
      request.current = null;
      setNotice("Booked players assigned. Review the refreshed teams and confirm at least five actual starters per side before kickoff.");
      await onSaved();
    } catch (failure) { setError(failure instanceof Error ? failure.message : "Could not assign the booked players."); }
    finally { setSaving(false); }
  }

  async function save(event: FormEvent) {
    event.preventDefault();
    if (locked || !canEdit || !moves.length || consentMissing || unassignedRemaining || reason.trim().length < 10) return;
    const content = JSON.stringify({ action: "rebalance", reason: reason.trim(), moves: moves.map(player => ({
      profile_id: player.id, to_team: targets[player.id], consented: consents[player.id] === true,
    })) });
    if (request.current?.content !== content) request.current = { content, id: crypto.randomUUID() };
    setSaving(true); setError(null); setNotice(null);
    try {
      const response = await fetch(`/api/referee/open-queue-games/${fixture.id}/action`, {
        method: "POST", headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ ...JSON.parse(content), requestId: request.current.id }),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.error ?? "Could not rebalance the teams.");
      if (payload.ok !== true || payload.rebalance?.game_id !== fixture.id || payload.rebalance?.action !== "REBALANCE") {
        throw new Error("The team change was not acknowledged. Retry this same request before changing the moves.");
      }
      setEditing(false); setTargets({}); setConsents({}); setReason(""); request.current = null;
      setNotice("Team changes saved and audited. Moved players will be notified. Check the refreshed teams before kickoff.");
      await onSaved();
    } catch (failure) { setError(failure instanceof Error ? failure.message : "Could not rebalance the teams."); }
    finally { setSaving(false); }
  }

  return <section className={styles.panel} aria-labelledby="season-zero-rebalance-title">
    <header><div><span>BEFORE KICKOFF</span><h2 id="season-zero-rebalance-title">Rebalance assigned teams</h2></div>
      {canEdit && !editing ? <button className={styles.secondary} disabled={locked} type="button" onClick={() => { setEditing(true); setError(null); setNotice(null); }}>Review team moves</button> : null}</header>
    <p className={styles.hint}>Only originally booked players can move. Keep each booked position and accepted party intact. No replacements or team changes after kickoff.</p>
    {!fixture.teamsAssignedAt ? <>
      <p className={styles.hint}>{fixture.players.length} booked players. At least 10 and at most 14 are needed. Assignment opens in the saved reveal / kickoff window; the server checks the cutoff, accepted parties and formation. Assignment does not start the clock.</p>
      {retainedTeams ? <p className={styles.hint}>The roster changed after teams were revealed. Existing teams are retained. Confirming fills new slots without moving anyone already assigned; use team moves if a consented repair is needed.</p> : null}
      <button className={styles.primary} type="button" disabled={locked || fixture.operationalState !== "NORMAL" || !validRosterSize} onClick={() => void assign()}>{saving ? "Confirming booked players…" : retainedTeams ? "Confirm roster without moving players" : "Assign booked players to teams"}</button>
    </> : null}
    {!canEdit ? <p className={styles.hint}>Team moves need 10–14 booked players, at least one retained team assignment and an available match.</p> : null}
    {notice ? <p className={styles.notice} role="status">{notice}</p> : null}
    {error ? <p role="alert" className={styles.error}>{error}</p> : null}
    {editing ? <form onSubmit={event => void save(event)} aria-label="Rebalance assigned teams">
      <p className={styles.hint}>Select a swap or multiple moves, and assign every new slot. Record each checked-in player’s agreement when changing their existing team. The server checks five to seven per side, the saved formation, parties and current check-ins before applying the whole change.</p>
      <div className={styles.playerList}>{players.map(player => {
        const moving = Boolean(targets[player.id] && targets[player.id] !== player.clanId);
        const present = presence(player.id);
        return <div className={styles.playerRow} key={player.id}>
          <div><strong>{player.displayName}</strong><small>{player.clanId === "WHITE" ? "White" : player.clanId === "BLACK" ? "Black" : "Unassigned"} · {player.role} · {present === true ? "Checked in" : present === false ? "Not checked in" : "Attendance unavailable"}</small></div>
          <label><span>Team for {player.displayName}</span><select disabled={locked} value={targets[player.id] ?? player.clanId} onChange={event => { setTargets({ ...targets, [player.id]: event.target.value }); setConsents({ ...consents, [player.id]: false }); }}>
            {!hasPriorTeam(player.clanId) ? <option value={player.clanId}>Choose team</option> : null}
            <option value="WHITE">White</option><option value="BLACK">Black</option></select></label>
          {moving && hasPriorTeam(player.clanId) ? <label className={styles.check}><input type="checkbox" disabled={locked} checked={consents[player.id] ?? false} onChange={event => setConsents({ ...consents, [player.id]: event.target.checked })} />{player.displayName} agreed to move{present === true ? " (required)" : present === false ? " (optional if absent)" : " (server checks attendance)"}</label> : null}
        </div>;
      })}</div>
      <p className={styles.hint}>{moves.length} {moves.length === 1 ? "move" : "moves"} selected. Present players must agree; absent slots can be exchanged without invented consent.</p>
      {unassignedRemaining ? <p className={styles.hint}>Choose a team for every unassigned player before saving.</p> : null}
      <label>Reason for team changes<textarea value={reason} maxLength={2000} minLength={10} required disabled={locked} onChange={event => setReason(event.target.value)} /><small>At least 10 characters. Saved with who moved, consent and your identity.</small></label>
      <footer><button className={styles.secondary} type="button" disabled={locked} onClick={() => setEditing(false)}>Cancel</button><button className={styles.primary} type="submit" disabled={locked || !moves.length || consentMissing || unassignedRemaining || reason.trim().length < 10}>{saving ? "Saving team changes…" : "Save team changes"}</button></footer>
    </form> : null}
  </section>;
}
