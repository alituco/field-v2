"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import type { AdminGameFormation } from "@/lib/admin-game-formation";
import type { SoloFormation } from "@/lib/admin-solo-games";
import { SoloFormationFields } from "./solo-formation-fields";
import styles from "./game-formation-panel.module.css";

export function GameFormationPanel({ formation, accessToken, gameId, onSaved }: {
  formation: AdminGameFormation;
  accessToken: string;
  gameId: string;
  onSaved: () => Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<SoloFormation>(formation);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => { if (editing) form.current?.querySelector<HTMLSelectElement>("select:not(:disabled)")?.focus(); }, [editing]);
  const unchanged = draft.defendersPerSide === formation.defendersPerSide && draft.attackersPerSide === formation.attackersPerSide;

  function close() {
    setEditing(false); setError(null);
    requestAnimationFrame(() => trigger.current?.focus());
  }
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving || !formation.canEdit || unchanged || reason.trim().length < 8) return;
    setSaving(true); setError(null);
    try {
      const response = await fetch(`/api/referee/admin/games/solo/${gameId}/formation`, {
        method: "PATCH", headers: { authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ goalkeepersPerSide: draft.goalkeepersPerSide, defendersPerSide: draft.defendersPerSide, attackersPerSide: draft.attackersPerSide, reason: reason.trim() }),
      });
      const payload = await response.json().catch(() => ({})) as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Could not save the formation.");
      close();
      await onSaved();
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not save the formation."); }
    finally { setSaving(false); }
  }

  return (
    <section className={styles.panel} aria-labelledby="game-formation-title">
      <header><div><span>SEVEN-A-SIDE</span><h2 id="game-formation-title">Team formation</h2></div>{formation.canEdit && !editing ? <button ref={trigger} className={styles.primary} type="button" onClick={() => { setDraft(formation); setReason(""); setError(null); setEditing(true); }}>Edit formation</button> : null}</header>
      <p className={styles.summary}>{formation.goalkeepersPerSide} keeper · {formation.defendersPerSide} defenders · {formation.attackersPerSide} attackers <small>per team</small></p>
      {!formation.canEdit ? <p className={styles.hint}>{formation.lockedReason}</p> : <p className={styles.hint}>Available positions, parties and team assignment use this formation. It locks after the first booking or payment attempt.</p>}
      {editing ? <form ref={form} onSubmit={(event) => void save(event)} aria-label="Edit game formation">
        <SoloFormationFields value={draft} onChange={setDraft} disabled={saving || !formation.canEdit} />
        <label className={styles.reason}><span>Reason for the formation change</span><textarea required minLength={8} maxLength={1000} value={reason} disabled={saving} onChange={(event) => setReason(event.target.value)} placeholder="For example, more attacking places for this game." /><small>At least 8 characters. Saved in the game’s admin history.</small></label>
        {error ? <p role="alert" className={styles.error}>{error}</p> : null}
        <footer><button className={styles.secondary} type="button" disabled={saving} onClick={close}>Cancel</button><button className={styles.primary} type="submit" disabled={saving || unchanged || !formation.canEdit || reason.trim().length < 8}>{saving ? "Saving…" : "Save formation"}</button></footer>
      </form> : null}
    </section>
  );
}
