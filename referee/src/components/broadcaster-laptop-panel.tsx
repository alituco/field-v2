"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import type { RefereeFixture } from "@/lib/types";
import styles from "./broadcaster-laptop-panel.module.css";

type PairedLaptop = {
  deviceKey: string;
  displayName: string;
  status: "OFFLINE" | "READY" | "STREAMING" | "ERROR";
  lastSeenAt: string | null;
  expiresAt: string;
  obsConnected: boolean;
  obsStreaming: boolean;
  revokedAt?: string | null;
  reservationActive?: boolean;
  testCleanupPending?: boolean;
};

type PairingCode = { code: string; expiresAt: string };

export function BroadcasterLaptopPanel({
  fixture,
  accessToken,
  streamActive,
  canAdminister = false,
  onDeviceChanged,
}: {
  fixture: Pick<RefereeFixture, "id" | "matchKind" | "status">;
  accessToken: string;
  streamActive: boolean;
  canAdminister?: boolean;
  onDeviceChanged: () => void;
}) {
  const [device, setDevice] = useState<PairedLaptop | null>(null);
  const [pairing, setPairing] = useState<PairingCode | null>(null);
  const [loading, setLoading] = useState(true);
  const [action, setAction] = useState<"pair" | "disconnect" | null>(null);
  const [confirmDisconnect, setConfirmDisconnect] = useState(false);
  const [confirmForce, setConfirmForce] = useState(false);
  const [forceConfirmation, setForceConfirmation] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [statusError, setStatusError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [now, setNow] = useState(Date.now);
  const mounted = useRef(true);
  const previousDevice = useRef<string | null | undefined>(undefined);
  const requestVersion = useRef(0);
  const mutationInFlight = useRef(false);
  const unfinishedCleanup = useRef<PairedLaptop | null>(null);
  const headers = { authorization: `Bearer ${accessToken}` };

  const load = useCallback(async (signal: AbortSignal) => {
    if (mutationInFlight.current) return;
    const version = ++requestVersion.current;
    try {
      const query = new URLSearchParams({ matchKind: fixture.matchKind, matchId: fixture.id });
      const response = await fetch(`/api/referee/broadcast-pairing?${query}`, {
        headers: { authorization: `Bearer ${accessToken}` }, cache: "no-store", signal,
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error ?? "Could not check the paired Mac.");
      if (!("device" in payload) || (payload.device !== null && !isPairedLaptop(payload.device))) {
        throw new Error("Could not check the paired Mac. Try again.");
      }
      if (signal.aborted || !mounted.current || version !== requestVersion.current) return;
      const nextDevice = (payload.device as PairedLaptop | null) ?? unfinishedCleanup.current;
      setDevice(nextDevice);
      setStatusError(null);
      if (nextDevice) {
        setPairing(null);
        setCopied(false);
      }
      if (previousDevice.current !== undefined && previousDevice.current !== (nextDevice?.deviceKey ?? null)) {
        onDeviceChanged();
      }
      previousDevice.current = nextDevice?.deviceKey ?? null;
    } catch (loadError) {
      if (!signal.aborted && mounted.current && version === requestVersion.current) {
        setStatusError(loadError instanceof Error ? loadError.message : "Could not check the paired Mac.");
      }
    } finally {
      if (!signal.aborted && mounted.current && version === requestVersion.current) setLoading(false);
    }
  }, [accessToken, fixture.id, fixture.matchKind, onDeviceChanged]);

  useEffect(() => {
    mounted.current = true;
    const controller = new AbortController();
    void load(controller.signal);
    const timer = window.setInterval(() => void load(controller.signal), 5_000);
    return () => {
      mounted.current = false;
      controller.abort();
      window.clearInterval(timer);
    };
  }, [load]);

  useEffect(() => {
    if (!pairing) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, [pairing]);

  async function generateCode() {
    mutationInFlight.current = true;
    requestVersion.current++;
    setAction("pair");
    setError(null);
    setCopied(false);
    try {
      const response = await fetch("/api/referee/broadcast-pairing", {
        method: "POST",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({ matchKind: fixture.matchKind, matchId: fixture.id }),
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error ?? "Could not create a pairing code.");
      if (typeof payload.code !== "string" || !/^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(payload.code)
        || typeof payload.expiresAt !== "string" || !Number.isFinite(Date.parse(payload.expiresAt))) {
        throw new Error("Could not create a pairing code. Try again.");
      }
      if (mounted.current) setPairing({ code: payload.code, expiresAt: payload.expiresAt });
    } catch (pairingError) {
      if (mounted.current) setError(pairingError instanceof Error ? pairingError.message : "Could not create a pairing code.");
    } finally {
      mutationInFlight.current = false;
      if (mounted.current) setAction(null);
    }
  }

  async function disconnect(force = false) {
    if (!device || (force ? !canAdminister || forceConfirmation !== "DISCONNECT" : streamActive || device.obsStreaming || device.revokedAt || device.testCleanupPending)) return;
    mutationInFlight.current = true;
    requestVersion.current++;
    setAction("disconnect");
    setError(null);
    try {
      const response = await fetch("/api/referee/broadcast-pairing", {
        method: "DELETE",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({ deviceKey: device.deviceKey, ...(force ? { force: true } : {}) }),
      });
      const payload = await response.json();
      if (!response.ok || payload.ok !== true) throw new Error(payload.error ?? "Could not disconnect this Mac.");
      if (!mounted.current) return;
      setDevice(null);
      previousDevice.current = null;
      unfinishedCleanup.current = null;
      setConfirmDisconnect(false);
      setConfirmForce(false);
      setForceConfirmation("");
      setPairing(null);
      onDeviceChanged();
    } catch (disconnectError) {
      if (force) unfinishedCleanup.current = device;
      if (mounted.current) setError(disconnectError instanceof Error ? disconnectError.message : "Could not disconnect this Mac.");
    } finally {
      mutationInFlight.current = false;
      if (mounted.current) setAction(null);
    }
  }

  async function copyCode() {
    if (!pairing) return;
    try {
      await navigator.clipboard.writeText(pairing.code);
      if (mounted.current) setCopied(true);
    } catch {
      if (mounted.current) setError("Copy is unavailable here. Enter the code shown above on your Mac.");
    }
  }

  const secondsLeft = pairing ? Math.max(0, Math.ceil((Date.parse(pairing.expiresAt) - now) / 1_000)) : 0;
  const closedMatch = fixture.status === "FINAL" || fixture.status === "CANCELLED";
  const canDisconnect = !streamActive && !device?.obsStreaming && !device?.revokedAt && !device?.testCleanupPending;
  const isOnline = device && device.status !== "OFFLINE" && device.status !== "ERROR";
  const forceNeeded = Boolean(device && canAdminister && (!canDisconnect || device.status === "OFFLINE" || device.status === "ERROR" || Date.parse(device.expiresAt) <= Date.now() || unfinishedCleanup.current));

  return (
    <section className={styles.panel} aria-label="Broadcast laptop">
      <div className={styles.heading}>
        <span className={styles.laptopIcon} aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M5 16V5h14v11M2 19h20M4 16h16l2 3H2z" /></svg></span>
        <div><h3>{device ? device.displayName : "Connect your Mac"}</h3>
          <p>{loading ? "Checking your laptop…" : device ? (device.revokedAt || unfinishedCleanup.current ? "Disconnect cleanup needs attention" : statusError ? "Connection status unavailable" : device.obsStreaming ? "Streaming this match" : isOnline ? (device.obsConnected ? "Laptop connected · OBS ready" : "Open OBS on this Mac") : "Laptop offline") : "Osmo camera · USB-C · Fieldrush Broadcaster"}</p>
        </div>
        {device ? <span className={`${styles.statusDot} ${isOnline && !statusError ? styles.online : ""}`} aria-hidden="true" /> : null}
      </div>

      {statusError ? <div className={styles.error} role="alert">{statusError}<button className="ghost-button compact-button" onClick={() => void load(new AbortController().signal)} type="button">Check again</button></div> : null}

      {!loading && !statusError && !device ? (
        closedMatch ? <p className={styles.hint}>Laptop pairing is closed for this match. Choose an upcoming match to set up your camera.</p> : <>
          <p className={styles.hint}>Open Fieldrush Broadcaster on the Mac beside your pitch, then enter a pairing code for this match.</p>
          {pairing ? <div className={styles.codePanel}>
            <span className={styles.eyebrow}>Enter this on your Mac</span>
            <strong className={`${styles.code} ${secondsLeft === 0 ? styles.expired : ""}`}>{pairing.code}</strong>
            <span className={styles.codeExpiry}>{secondsLeft > 0 ? `Expires in ${Math.floor(secondsLeft / 60)}:${String(secondsLeft % 60).padStart(2, "0")} · one use only` : "This code has expired. Get a new code to connect."}</span>
            {secondsLeft > 0 ? <button className="ghost-button compact-button" onClick={() => void copyCode()} type="button">{copied ? "Code copied" : "Copy code"}</button> : <button className="primary-button" disabled={action !== null} onClick={() => void generateCode()} type="button">{action === "pair" ? "Creating code…" : "Get new code"}</button>}
          </div> : <button className="primary-button" disabled={action !== null} onClick={() => void generateCode()} type="button">{action === "pair" ? "Creating code…" : "Create pairing code"}</button>}
          <p className={styles.hint}>Pairing is for this match and lasts up to 24 hours. Use a fresh code for the next match or when handing over a shared Mac.</p>
        </>
      ) : null}

      {device ? <>
        <p className={styles.hint}>Check the camera preview and field sound on the Mac before starting. Keep it plugged into power with the lid open.</p>
        {!canDisconnect ? <p className={styles.hint}>{device.revokedAt ? "This Mac has lost access. An administrator must finish disabling its stream before another laptop can use the pitch." : device.testCleanupPending ? "A private stream test is still active or needs cleanup. Finish it on the Mac before disconnecting, or ask an administrator to release it." : "Stop the stream before disconnecting or switching laptops."}</p> : null}
        {confirmDisconnect ? <div className={styles.confirm} role="group" aria-label="Confirm laptop disconnection">
          <strong>Disconnect this Mac?</strong>
          <p>You will need a new pairing code to control this match from the laptop again. Your saved camera settings and local recordings stay on the Mac.</p>
          <div className={styles.actions}><button className="ghost-button" disabled={action !== null} onClick={() => setConfirmDisconnect(false)} type="button">Keep connected</button>
            <button className="danger-button" disabled={action !== null || !canDisconnect || Boolean(statusError)} onClick={() => void disconnect()} type="button">{action === "disconnect" ? "Disconnecting…" : "Disconnect Mac"}</button></div>
        </div> : <button className="ghost-button compact-button" disabled={!canDisconnect || action !== null || Boolean(statusError)} onClick={() => setConfirmDisconnect(true)} type="button">Disconnect Mac</button>}
        {forceNeeded && !confirmForce ? <button className={`ghost-button compact-button ${styles.forceButton}`} disabled={action !== null} onClick={() => { setConfirmDisconnect(false); setConfirmForce(true); setForceConfirmation(""); }} type="button">{device.revokedAt || unfinishedCleanup.current ? "Retry disconnect cleanup" : "Force disconnect Mac"}</button> : null}
        {confirmForce && canAdminister ? <div className={styles.confirm} role="group" aria-label="Confirm forced laptop disconnection">
          <span className={styles.eyebrow}>Admin action</span><h4>Force disconnect this Mac?</h4>
          <p>The Mac loses access immediately and its live stream is disabled. The pitch stays reserved until cleanup succeeds. Check any recording on the Mac afterward. The match clock and scoring are unchanged.</p>
          <label className={styles.forceLabel}>Type DISCONNECT to confirm<input className="input" autoComplete="off" value={forceConfirmation} disabled={action !== null} onChange={event => setForceConfirmation(event.target.value)} /></label>
          <div className={styles.actions}><button className="ghost-button" disabled={action !== null} onClick={() => { setConfirmForce(false); setForceConfirmation(""); }} type="button">Cancel</button><button className="danger-button" disabled={action !== null || forceConfirmation !== "DISCONNECT"} onClick={() => void disconnect(true)} type="button">{action === "disconnect" ? "Disconnecting…" : "Force disconnect"}</button></div>
        </div> : null}
      </> : null}
      {error ? <p className={styles.error} role="alert">{error}</p> : null}
      <a className={styles.guideLink} href="/broadcast/setup" target="_blank" rel="noopener noreferrer">Mac and USB-C setup guide <span aria-hidden="true">↗</span></a>
    </section>
  );
}

function isPairedLaptop(value: unknown): value is PairedLaptop {
  if (!value || typeof value !== "object") return false;
  const device = value as Record<string, unknown>;
  return typeof device.deviceKey === "string" && device.deviceKey.length > 0
    && typeof device.displayName === "string" && device.displayName.length > 0
    && ["OFFLINE", "READY", "STREAMING", "ERROR"].includes(String(device.status))
    && typeof device.obsConnected === "boolean" && typeof device.obsStreaming === "boolean"
    && typeof device.expiresAt === "string" && Number.isFinite(Date.parse(device.expiresAt));
}
