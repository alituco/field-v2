"use client";

import { useEffect } from "react";

// Existing OBS bookmarks use this address. Forward in the browser so its
// fragment-only capability never becomes part of a server redirect or query.
export default function OverlayClient({ fixtureId }: { fixtureId: string }) {
  useEffect(() => {
    const htmlBackground = document.documentElement.style.background;
    const bodyBackground = document.body.style.background;
    document.documentElement.style.background = "transparent";
    document.body.style.background = "transparent";

    const destination = new URL(
      `/broadcast/obs/${encodeURIComponent(fixtureId)}`,
      window.location.origin,
    );
    if (new URLSearchParams(window.location.search).get("kind") === "solo") {
      destination.searchParams.set("kind", "solo");
    }
    destination.hash = window.location.hash;
    window.location.replace(destination.toString());

    return () => {
      document.documentElement.style.background = htmlBackground;
      document.body.style.background = bodyBackground;
    };
  }, [fixtureId]);

  return <div className="broadcast-overlay-root" aria-label="Loading scoreboard" />;
}
