# JFR Feed — the feed truck app (phase 2)

A third PWA beside `field-app/` and `tally-book/`. Same sign-in, same
offline-first shape. Design record: `docs/feed-truck-integration-scope.md`.

**Screens:** Bunks (score + lb/head, save needs signal) → Plan (balanced
loads, `planner.js`) → Truck (load against a countdown, Done per ingredient,
mix timer hard block, drops Start/Done) → History (editable until posted) →
More (truck, simulated scale, pull, sync, sign out).

**Test in a browser:** More › Simulated scale on. The slider stands in for
the head; "Auto" cycles filling / emptying at 400 lb/s.

**Run the planner tests:** `node feed-app/planner.test.js`.

## Scale bridge contract (for the Flutter shell, phase 3)

The shell hosts this app in a WebView and is the only thing that talks
Bluetooth. Two directions, both JSON.

Shell → page (call these on the page's `window`):

```js
window.FeedScale.onWeight({ lb: 12340, stable: true, deviceId: 'Point-1A2B' })   // as often as the head advertises (20 ms is fine)
window.FeedScale.onStatus({ connected: true, deviceId: 'Point-1A2B', name: 'Main truck head' })
```

`lb` is GROSS pounds as the head shows them. The app takes every ingredient
and drop as a difference in gross and never needs Tare. A reading older
than 5 s counts as "no link" and the Done buttons disable.

Page → shell: the page posts to a JavaScript channel named `FeedShell`:

```js
window.FeedShell.postMessage(JSON.stringify({ cmd: 'zero' }))      // Zero the head
window.FeedShell.postMessage(JSON.stringify({ cmd: 'scan' }))      // open the shell's device picker
```

When `window.FeedShell` is absent (plain Safari) the app says so and the
simulated scale is the only source.

## Sync

Every truck row (`feed_loads`, `feed_load_lines`, `feed_drops`,
`feed_drop_lots`, frozen `bunk_reads`) carries a client-made uuid and is
upserted on `id`, in order, from a localStorage queue. A resend lands once;
an edit overwrites. Refusals from the database (RLS, guards) are dropped
from the queue and shown under More, never retried forever.

Bump `CACHE_VERSION` in `sw.js` and the `?v=` strings in `index.html`
together on every deploy.
