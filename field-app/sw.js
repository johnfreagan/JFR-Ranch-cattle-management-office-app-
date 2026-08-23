// =========================================================
// Beta Cattle Tracker — Service Worker
// Enables offline use in the pasture.
//
// Strategy:
//   - Pre-cache the app shell on install
//   - Stale-while-revalidate for app assets (fast load, updates silently)
//   - Network-only for the Google Apps Script cloud URL (never cache writes)
//
// Bump CACHE_VERSION whenever you deploy changes to index.html / app.js / styles.css.
// =========================================================

const CACHE_VERSION = 'v1';
const CACHE_NAME = `beta-cattle-${CACHE_VERSION}`;

const APP_SHELL = [
    './',
    './index.html',
    './app.js',
    './styles.css',
    './manifest.json'
];

// --- Install: pre-cache the app shell ---
self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME)
            .then(cache => cache.addAll(APP_SHELL))
            .then(() => self.skipWaiting())
    );
});

// --- Activate: clean up old caches ---
self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys()
            .then(keys => Promise.all(
                keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
            ))
            .then(() => self.clients.claim())
    );
});

// --- Fetch: app-shell from cache, everything else network-first ---
self.addEventListener('fetch', (event) => {
    const req = event.request;
    const url = new URL(req.url);

    // Only handle GETs
    if (req.method !== 'GET') return;

    // Never cache calls to Google Apps Script (our cloud writes/reads)
    if (url.hostname.includes('script.google.com')) {
        return; // let the browser handle it normally
    }

    // Only cache same-origin assets
    if (url.origin !== self.location.origin) return;

    event.respondWith(
        caches.open(CACHE_NAME).then(cache =>
            cache.match(req).then(cached => {
                const fresh = fetch(req).then(res => {
                    // Cache good responses in the background
                    if (res && res.ok) {
                        cache.put(req, res.clone());
                    }
                    return res;
                }).catch(() => cached);  // fall back to cache on network error

                // Serve cached immediately if we have it, else wait for network
                return cached || fresh;
            })
        )
    );
});
