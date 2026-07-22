"use client";

import { useEffect, useState } from "react";

type InstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
};

const DISMISS_KEY = "field-ops-install-dismissed-at";
const DISMISS_FOR_MS = 7 * 24 * 60 * 60 * 1000;

function isStandalone() {
  const navigatorWithStandalone = navigator as Navigator & {
    standalone?: boolean;
  };
  return (
    window.matchMedia("(display-mode: standalone)").matches ||
    navigatorWithStandalone.standalone === true
  );
}

function isIosSafari() {
  const userAgent = navigator.userAgent;
  const isIos = /iPad|iPhone|iPod/.test(userAgent);
  const isWebKit = /WebKit/.test(userAgent);
  const isOtherIosBrowser = /CriOS|FxiOS|EdgiOS/.test(userAgent);
  return isIos && isWebKit && !isOtherIosBrowser;
}

export function PwaInstallPrompt() {
  const [installPrompt, setInstallPrompt] = useState<InstallPromptEvent | null>(
    null,
  );
  const [showIosInstructions, setShowIosInstructions] = useState(false);
  const [visible, setVisible] = useState(false);
  const isStaging = process.env.NEXT_PUBLIC_APP_ENV === "staging";

  useEffect(() => {
    if ("serviceWorker" in navigator) {
      void navigator.serviceWorker
        .register("/sw.js", {
          scope: "/",
          updateViaCache: "none",
        })
        .catch(() => undefined);
    }

    if (isStandalone()) return;

    const dismissedAt = Number(window.localStorage.getItem(DISMISS_KEY) ?? 0);
    if (Number.isFinite(dismissedAt) && Date.now() - dismissedAt < DISMISS_FOR_MS) {
      return;
    }

    const ios = isIosSafari();
    setShowIosInstructions(ios);
    const iosTimer = ios
      ? window.setTimeout(() => setVisible(true), 900)
      : null;

    const handleInstallPrompt = (event: Event) => {
      event.preventDefault();
      setInstallPrompt(event as InstallPromptEvent);
      setVisible(true);
    };
    window.addEventListener("beforeinstallprompt", handleInstallPrompt);

    return () => {
      if (iosTimer !== null) window.clearTimeout(iosTimer);
      window.removeEventListener("beforeinstallprompt", handleInstallPrompt);
    };
  }, []);

  function dismiss() {
    window.localStorage.setItem(DISMISS_KEY, String(Date.now()));
    setVisible(false);
  }

  async function install() {
    if (!installPrompt) return;
    await installPrompt.prompt();
    await installPrompt.userChoice;
    setInstallPrompt(null);
    setVisible(false);
  }

  if (!visible) return null;

  return (
    <aside className="pwa-install-prompt" aria-label="Install Field Ops">
      <img
        alt=""
        height="48"
        src={
          isStaging
            ? "/field-ops-staging-icon-192.png"
            : "/field-ops-icon-192.png"
        }
        width="48"
      />
      <div>
        <span>{isStaging ? "FIELD OPS STAGING" : "FIELD OPS"}</span>
        <strong>Keep match day one tap away</strong>
        <p>
          {showIosInstructions
            ? "In Safari, tap Share and then Add to Home Screen."
            : "Install the referee console on this device."}
        </p>
      </div>
      <div className="pwa-install-actions">
        {installPrompt ? (
          <button className="pwa-install-primary" onClick={() => void install()} type="button">
            Install
          </button>
        ) : null}
        <button className="pwa-install-dismiss" onClick={dismiss} type="button">
          {showIosInstructions ? "Got it" : "Not now"}
        </button>
      </div>
    </aside>
  );
}
