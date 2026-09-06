// =========================================================
// JFR Feed — Service Worker (network-first shell, same as the field app)
// Bump CACHE_VERSION and the ?v= strings in index.html together.
// =========================================================
const CACHE_VERSION = 'v3';
const CACHE_NAME = `jfr-feed-${CACHE_VERSION}`;
const APP_SHELL = [
    './',
    './index.html',
    './app.js?v=v3',
    './planner.js?v=v3',
    './supabase.min.js?v=2.46.1',
    './styles.css?v=v3',
    './manifest.json'
];
function isAppShell(url) {
    return /\/(index\.html|app\.js|planner\.js|supabase\.min\.js|styles\.css)$/.test(url.pathname)
        || url.pathname.endsWith('/feed-app/') || url.pathname.endsWith('/');
}
self.addEventListener('install', (event) => {
    event.waitUntil(caches.open(CACHE_NAME).then(c => c.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (event) => {
    event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (event) => {
    const req = event.request;
    const url = new URL(req.url);
    if (req.method !== 'GET') return;
    if (url.origin !== self.location.origin) return;
    if (req.mode === 'navigate' || isAppShell(url)) {
        event.respondWith(
            fetch(req).then(res => {
                if (res && res.ok) { const copy = res.clone(); caches.open(CACHE_NAME).then(c => c.put(req, copy)); }
                return res;
            }).catch(() => caches.open(CACHE_NAME).then(c => c.match(req)).then(hit => hit || caches.match('./index.html')))
        );
        return;
    }
    event.respondWith(
        caches.open(CACHE_NAME).then(cache => cache.match(req).then(cached => {
            const fresh = fetch(req).then(res => { if (res && res.ok) cache.put(req, res.clone()); return res; }).catch(() => cached);
            return cached || fresh;
        }))
    );
});
