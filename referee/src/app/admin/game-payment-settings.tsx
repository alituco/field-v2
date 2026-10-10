"use client";

import { useEffect, useState } from "react";
import type { GamePaymentSettings } from "@/lib/game-payment-settings";
import styles from "./game-payment-settings.module.css";

export function GamePaymentSettingsPanel({ accessToken }: { accessToken: string }) {
  const [settings, setSettings] = useState<GamePaymentSettings | null>(null);
  const [price, setPrice] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [reload, setReload] = useState(0);
  useEffect(() => {
    let cancelled = false;
    void fetch("/api/referee/admin/game-payment-settings", {
      headers: { Authorization: `Bearer ${accessToken}` }, cache: "no-store",
    }).then(async (response) => {
      const payload = await response.json();
      if (!response.ok || !payload.settings) throw new Error(payload.error || "Could not load game pricing.");
      if (!cancelled) {
        setSettings(payload.settings);
        setPrice((Number(payload.settings.clan_price_fils) / 1000).toFixed(2));
        setError(null);
      }
    }).catch((error) => { if (!cancelled) setError(error.message); });
    return () => { cancelled = true; };
  }, [accessToken, reload]);

  async function save(event: React.FormEvent) {
    event.preventDefault();
    if (!settings) return;
    setSaving(true); setError(null); setNotice(null);
    try {
      const response = await fetch("/api/referee/admin/game-payment-settings", {
        method: "PATCH",
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ clanPriceUsd: price, reason, expectedUpdatedAt: settings.updated_at }),
      });
      const payload = await response.json();
      if (!response.ok || !payload.settings) throw new Error(payload.error || "Could not save the future clan price.");
      setSettings(payload.settings);
      setPrice((Number(payload.settings.clan_price_fils) / 1000).toFixed(2));
      setReason("");
      setNotice("Future clan price saved. Clan games remain paused; existing bookings are unchanged.");
    } catch (error) {
      setError(error instanceof Error ? error.message : "Could not save pricing.");
    } finally { setSaving(false); }
  }

  return <details className={styles.panel}>
    <summary><span>Booking prices · USD</span><span>Clan games paused</span></summary>
    <div className={styles.content}>
      <p>Solo games default to <strong>$13 per player</strong>. Set each game’s price when creating it.</p>
      <p><strong>Clan bookings are disabled.</strong> The future default is $80 per team. Saving a different price does not enable clan games, charge anyone, or change existing bookings.</p>
      {settings ? <form onSubmit={(event) => void save(event)}>
        <label className="admin-modal-field"><span>Future clan price per team (USD)</span><input type="number" min="0.50" max="1000" step="0.01" value={price} onChange={(event) => setPrice(event.target.value)} disabled={saving} required /></label>
        <label className="admin-modal-field"><span>Reason for changing the price</span><input value={reason} onChange={(event) => setReason(event.target.value)} minLength={10} maxLength={1000} disabled={saving} required /><small>Recorded in the admin audit trail. At least 10 characters.</small></label>
        <button className="admin-primary-button" disabled={saving || reason.trim().length < 10} type="submit">{saving ? "Saving…" : "Save future clan price"}</button>
      </form> : !error ? <p>Loading current pricing…</p> : null}
      {error ? <p role="alert">{error} <button type="button" className="admin-row-action" onClick={() => setReload((value) => value + 1)}>Reload price</button></p> : null}
      {notice ? <p role="status">{notice}</p> : null}
    </div>
  </details>;
}
