"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import type { RefereeFixture } from "@/lib/types";
import { soloGameReadiness } from "@/lib/solo-game-readiness";
import styles from "./season-zero-operations.module.css";

export function AdminUnassignedPlayersPanel({ fixture, busy = false, accessToken, onSaved }: {
  fixture: RefereeFixture;
  busy?: boolean;
  accessToken: string;
  onSaved: () => void | Promise<void>;
}) {
  const [targets, setTargets] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const request = useRef<{ content: string; id: string } | null>(null);
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);

  const players = fixture.players ?? [];
  const assigned = players.filter(player => ["WHITE", "BLACK"].includes(player.clanId));
  const unassigned = players.filter(player => !["WHITE", "BLACK"].includes(player.clanId));
  const beforeKickoff = ["OPEN", "FULL"].includes(fixture.status) &&
    (!fixture.clock || (fixture.clock.status === "NOT_STARTED" && !fixture.clock.startedAt && fixture.clock.accumulatedSeconds === 0));
  if (!beforeKickoff || !assigned.length || !unassigned.length) return null;

  const canPlace = fixture.operationalState === "NORMAL" && soloGameReadiness(fixture, players.length).minimumReached;
  const locked = saving || busy || !canPlace;
  const complete = unassigned.every(player => ["WHITE", "BLACK"].includes(targets[player.id]));
  const count = (team: string, excluding?: string) => players.filter(player =>
    player.id !== excluding && (assigned.includes(player) ? player.clanId : targets[player.id]) === team).length;

  async function save(event: FormEvent) {
    event.preventDefault();
    if (locked || !complete) return;
    const assignments = unassigned.map(player => ({ profileId: player.id, team: targets[player.id] }));
    const content = JSON.stringify(assignments);
    if (request.current?.content !== content) request.current = { content, id: crypto.randomUUID() };
    const requestId = request.current.id;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 20_000);
    setSaving(true); setError(null);
    try {
      const response = await fetch(`/api/referee/admin/games/solo/${fixture.id}/assign-players`, {
        method: "POST", headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ requestId, assignments }), signal: controller.signal,
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.error ?? "Could not place the unassigned players.");
      if (payload.ok !== true || payload.assignment?.game_id !== fixture.id ||
        payload.assignment?.request_id !== requestId || payload.assignment?.action !== "ASSIGN_UNASSIGNED" ||
        payload.assignment?.assigned_count !== assignments.length) {
        throw new Error("Player assignment was not acknowledged. Retry the same selection before making another change.");
      }
      if (!mounted.current) return;
      await onSaved();
      if (!mounted.current) return;
      request.current = null;
      setTargets({});
    } catch (failure) {
      if (mounted.current) setError(failure instanceof Error && failure.name === "AbortError"
        ? "The assignment took too long to confirm. Retry the same selection to check it safely."
        : failure instanceof Error ? failure.message : "Could not place the unassigned players.");
    } finally {
      clearTimeout(timeout);
      if (mounted.current) setSaving(false);
    }
  }

  return <section className={styles.panel} aria-labelledby="admin-unassigned-players-title">
    <header><div><span>TEAM PLACEMENT</span><h2 id="admin-unassigned-players-title">Unassigned players</h2></div></header>
    <p className={styles.hint}>Choose a team for each new player. Everyone already assigned stays on their existing team.</p>
    <p className={styles.hint}>White {count("WHITE")} / 7 · Black {count("BLACK")} / 7. Keep booked positions and accepted parties together.</p>
    {!canPlace ? <p className={styles.hint}>Placement is unavailable while this game is under review or below its minimum player count.</p> : null}
    <form aria-label="Place unassigned players" onSubmit={event => void save(event)}>
      <div className={styles.playerList}>{unassigned.map(player => <div className={styles.playerRow} key={player.id}>
        <div><strong>{player.displayName}</strong><small>{player.role === "GK" ? "Keeper" : player.role === "DEF" ? "Defender" : player.role === "ATT" ? "Attacker" : player.role} · Unassigned</small></div>
        <label><span>Team for {player.displayName}</span><select disabled={locked} value={targets[player.id] ?? ""}
          onChange={event => { const value = event.target.value; setTargets(previous => ({ ...previous, [player.id]: value })); }}>
          <option value="">Choose team</option>
          <option value="WHITE" disabled={count("WHITE", player.id) >= 7}>White</option>
          <option value="BLACK" disabled={count("BLACK", player.id) >= 7}>Black</option>
        </select></label>
      </div>)}</div>
      {error ? <p className={styles.error} role="alert">{error}</p> : null}
      <footer><button className={styles.primary} type="submit" disabled={locked || !complete}>{saving ? "Placing players…" : "Save player assignments"}</button></footer>
    </form>
  </section>;
}
