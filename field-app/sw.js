// =========================================================
// Beta Cattle Tracker — Service Worker
// Enables offline use in the pasture.
//
// Strategy:
//   - Pre-cache the app shell on install
//   - Stale-while-revalidate for app assets (fast load, updates silently)
//   - Cross-origin (Supabase API) is never touched - always live network
//
// Bump CACHE_VERSION whenever you deploy changes to index.html / app.js / styles.css.
// =========================================================

const CACHE_VERSION = 'v11';   // v11: schema-versioned data freshness
const CACHE_NAME = `beta-cattle-${CACHE_VERSION}`;

// Must match the query strings index.html actually requests, or these get
// cached under keys nothing ever asks for. Previously the shell was
// precached as './app.js' while the page asked for './app.js?v=beta4',
// so the precache was dead weight and offline loads depended on whatever
// the runtime cache happened to hold.
const APP_SHELL = [
    './',
    './index.html',
    './app.js?v=v11',
    './supabase.min.js?v=2.46.1',
    './styles.css?v=beta3',
    './manifest.json'
];

// The files that make up the running app. These go network-first: a stale
// app.js paired with a fresh index.html is how you get a login button that
// does nothing, which is worse than a slightly slower load.
function isAppShell(url) {
    return /\/(index\.html|app\.js|supabase\.min\.js|styles\.css)$/.test(url.pathname)
        || url.pathname.endsWith('/field-app/')
        || url.pathname.endsWith('/');
}

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

    // Only cache same-origin assets
    if (url.origin !== self.location.origin) return;

    // --- App shell: NETWORK FIRST, cache as the offline fallback ---
    // The old strategy served the cached copy and only refreshed it for the
    // NEXT load, which left every device permanently one deploy behind and
    // could pair a new index.html with an old app.js.
    if (req.mode === 'navigate' || isAppShell(url)) {
        event.respondWith(
            fetch(req)
                .then(res => {
                    if (res && res.ok) {
                        const copy = res.clone();
                        caches.open(CACHE_NAME).then(c => c.put(req, copy));
                    }
                    return res;
                })
                .catch(() =>
                    caches.open(CACHE_NAME)
                        .then(c => c.match(req))
                        // A navigation with no exact match still needs a page.
                        .then(hit => hit || caches.match('./index.html'))
                )
        );
        return;
    }

    // --- Everything else (icons, manifest): stale-while-revalidate ---
    event.respondWith(
        caches.open(CACHE_NAME).then(cache =>
            cache.match(req).then(cached => {
                const fresh = fetch(req).then(res => {
                    if (res && res.ok) cache.put(req, res.clone());
                    return res;
                }).catch(() => cached);
                return cached || fresh;
            })
        )
    );
});
