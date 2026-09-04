# Feed truck integration — scope (2026-09-04)

**Status:** SCOPED, NOT BUILT. John's call pending. Performance Beef stays in
use for ration, bunk calling and truck-scale capture until then.

## What John told us

- Scale heads: Digi-Star with a Scale-Tec Bluetooth dongle, or Scale-Tec Point
  heads with Bluetooth built in.
- Device in the truck: iPad most likely, iPhone at times.
- The day: call bunks, make a ration (mixed load), drop it in a couple of
  locations. Bunks could go in any pasture; in practice the same ones.

## What that settles (revised same day after https://build.scale-tec.com)

- **The scale side is BLE and the protocol is PUBLIC.** Scale-Tec publishes an
  MIT-licensed Flutter template (`Dan-Scale-Tec/BLE-Scale-App-Template`,
  `flutter_blue_plus`) with the protocol PDF checked in. Live weight comes off
  advertisement packets at 20 ms with no GATT connection; a GATT gross-weight
  stream, Zero / Tare / Gross commands and `tareStopWithRecord` (logs a load)
  are wired up. Both heads John named are covered: Point (`Point-` prefix) and
  the newer Core (`SJB-`). The reverse-engineering risk is gone.
- **The iPad still rules out the browser for Bluetooth** (WebKit, no Web
  Bluetooth), but the native app is now a THIN SHELL, not a second field app:
  Scale-Tec's Flutter app kept as-is for BLE, its example screens replaced by
  one WebView hosting the field PWA, with a JS bridge pushing weight readings
  into the page and passing Zero / Tare back. One shell covers iPad, iPhone
  and Android.
- **Every feeding screen lives in the PWA**, same JS, same offline queue, same
  sign-in, same Approvals path. Bridge present → weight box fills live; absent
  → the driver types it. The shell is rebuilt only when Scale-Tec's core
  changes, so the "rebuild on every field-app change" tax disappears.
- **Apple admin that remains:** developer account, the Mac the office app is
  validated on, and a distribution channel — TestFlight (builds expire every
  90 days) or an unlisted App Store link (one review, never expires; vote).
- **The one real risk:** iPadOS WKWebView runs the service worker and local
  storage only for domains listed in `WKAppBoundDomains` (one Info.plist
  line). Must be tested on a real iPad in a pasture with no signal before the
  truck depends on it.

## Sizes (build-days at this repo's pace)

| Step | What you get | Size | Ongoing |
|---|---|---|---|
| A. Truck screens in the PWA, typed weights | bunk call, load plan, per-drop pounds, daily actuals per lot | ~5 | none new |
| B. Scale shell: Scale-Tec template + WebView + JS bridge | weights off the scale, on iPad and Android | ~3, plus a day in the cab pairing to the real head, plus Apple admin | shell rebuild only when Scale-Tec's core changes |
| Full native Flutter rewrite | same, duplicating auth / offline / Supabase in Dart | 15+ | a second field app forever — rejected |

The earlier "Android tablet + Web Bluetooth" option is dropped: the shell covers
Android too, on the vendor's own supported path.

Everything except Bluetooth lands on existing rails. PB's inventory and costing
are NOT replicated — the app is already system of record for both.

## How the day maps onto what is built

```
bunk call per lot ─▶ load plan = recipe × head × lb/hd
                          │
                    make_feed_batch  ──▶ "Feed truck" location (tailings carry honestly)
                          │
                    drops: post_feed_usage per lot, off the truck, dated the day
                          │
                    pending_field_entries ─▶ Approvals (one click per day's sheet)
                          │
                    feed_usage_costs frozen at approval, spread by lot_feed_daily
```

- New tables: `feed_calls` (lot, date, bunk score, lb/hd). Rations reuse
  `feed_recipes` / `feed_recipe_lines` (pre-fill only, as today).
- A drop into a mixed pasture splits across the lots standing there pro-rata by
  head, largest-remainder — the existing mixed-pasture rule.
- Drops go through Approvals like every other field record; cost freezes there
  exactly as doctoring does. Nothing new in head math or costing.
- Daily drops carry ONE date, which retires the weekly-period overlap hazard
  (feed-design-decisions #21) for anything fed off the truck.

## Recommendation

A now, B right behind it. The earlier "never native" call is reversed because
Scale-Tec removed the part that made native expensive. Run typed weights in the
truck while the shell is built; the feeding screens do not change between the
two. Phase 3 PB import remains the fallback if the truck app never takes.
