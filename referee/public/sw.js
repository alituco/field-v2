const STATIC_CACHE = "field-ops-static-v1";
const STATIC_PATHS = new Set([
  "/field-ops-icon-192.png",
  "/field-ops-icon-512.png",
  "/field-ops-staging-icon-192.png",
  "/field-ops-staging-icon-512.png",
  "/apple-touch-icon.png",
]);

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key !== STATIC_CACHE)
            .map((key) => caches.delete(key)),
        ),
      )
      .then(() => self.clients.claim()),
  );
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

  event.respondWith(
    caches.open(STATIC_CACHE).then(async (cache) => {
      const cached = await cache.match(request);
      if (cached) return cached;

      const response = await fetch(request);
      if (response.ok) await cache.put(request, response.clone());
      return response;
    }),
  );
});
