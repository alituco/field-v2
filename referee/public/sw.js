const STATIC_CACHE_PREFIX = "field-ops-static-";
const STATIC_CACHE = `${STATIC_CACHE_PREFIX}v3`;
const STATIC_PATHS = new Set([
  "/favicon.ico",
  "/favicon.svg",
  "/favicon-16x16.png",
  "/favicon-32x32.png",
  "/icon-192.png",
  "/icon-512.png",
  "/icon-maskable-512.png",
  "/apple-touch-icon.png",
]);

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    try {
      const keys = await caches.keys();
      await Promise.all(keys
        .filter((key) => key.startsWith(STATIC_CACHE_PREFIX) && key !== STATIC_CACHE)
        .map((key) => caches.delete(key)));
    } catch {
      // Storage can be unavailable or full. It must not prevent activation.
    }
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // Operational data must always come from the network. In particular, never
  // cache authentication, check-ins, match clocks, scores, or admin APIs.
  if (
    request.mode === "navigate" ||
    url.pathname.startsWith("/api/") ||
    url.pathname.startsWith("/admin") ||
    url.pathname.startsWith("/broadcast")
  ) {
    return;
  }

  const isVersionedNextAsset = url.pathname.startsWith("/_next/static/");
  if (!isVersionedNextAsset && !STATIC_PATHS.has(url.pathname)) return;

  event.respondWith((async () => {
    let cache;
    try {
      cache = await caches.open(STATIC_CACHE);
      const cached = await cache.match(request);
      if (cached) return cached;
    } catch {
      // A failed cache lookup still gets a fresh response from the network.
    }

    const response = await fetch(request);
    if (response.ok && cache) {
      // Persist in the background: a quota/write failure must never discard a
      // working script or stylesheet response, or delay delivery to the page.
      event.waitUntil((async () => {
        try { await cache.put(request, response.clone()); } catch { /* Optional cache. */ }
      })());
    }
    return response;
  })());
});
