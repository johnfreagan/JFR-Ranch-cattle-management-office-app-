// =========================================================
// Tally Book — Service Worker
//
// Same strategy as field-app/sw.js, and for the same reason it ended up
// there. The handed-over draft was cache-first with a fixed cache name:
// every installed copy would serve the version it first saw and only pick
// up a deploy on the load AFTER the next one, which is how you get a fresh
// index.html paired with a stale app.js and a button that does nothing.
//
//   - App shell: NETWORK FIRST, cache as the offline fallback
//   - Everything else same-origin: stale-while-revalidate
//   - Cross-origin (Supabase, Google Fonts): never touched, always live
//
// Bump CACHE_VERSION on every deploy of index.html / app.js / styles.css,
// and keep the query strings in APP_SHELL identical to the ones index.html
// actually requests — otherwise the precache is stored under keys nothing
// ever asks for and offline loads fall through to whatever happens to be
// in the runtime cache.
// =========================================================

const CACHE_VERSION = 'v7';   // v7: paint-time defaults no longer read as local edits
const CACHE_NAME = `tally-book-${CACHE_VERSION}`;

const APP_SHELL = [
    './',
    './index.html',
    './app.js?v=v7',
    './styles.css?v=v7',
    './supabase.min.js?v=2.46.1',
    './manifest.json'
];

function isAppShell(url) {
    return /\/(index\.html|app\.js|styles\.css|supabase\.min\.js)$/.test(url.pathname)
        || url.pathname.endsWith('/tally-book/')
        || url.pathname.endsWith('/');
}

self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME)
            .then(cache => cache.addAll(APP_SHELL))
            .then(() => self.skipWaiting())
    );
});

self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys()
            .then(keys => Promise.all(
                keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
            ))
            .then(() => self.clients.claim())
    );
});

self.addEventListener('fetch', (event) => {
    const req = event.request;
    const url = new URL(req.url);

    if (req.method !== 'GET') return;
    if (url.origin !== self.location.origin) return;

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
