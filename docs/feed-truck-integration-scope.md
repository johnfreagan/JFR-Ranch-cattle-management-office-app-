# Feed truck integration — scope (2026-09-04)

**Status:** SCOPED, NOT BUILT. John's call pending. Performance Beef stays in
use for ration, bunk calling and truck-scale capture until then.

## What John told us

- Scale heads: Digi-Star with a Scale-Tec Bluetooth dongle, or Scale-Tec Point
  heads with Bluetooth built in.
- Device in the truck: iPad most likely, iPhone at times.
- The day: call bunks, make a ration (mixed load), drop it in a couple of
  locations. Bunks could go in any pasture; in practice the same ones.

## What that settles

- **The scale side is BLE.** Scale-Tec's own app runs on iOS, and Apple gives
  third-party apps no path to Bluetooth Classic serial, so both heads must be
  Bluetooth Low Energy. That is the flavor software can reach.
- **The iPad rules out the browser for Bluetooth.** Every iPadOS browser is
  WebKit and none exposes Web Bluetooth. Bluetooth on iPad = native wrapper
  (Capacitor + BLE plugin + Apple developer account + TestFlight/App Store +
  a rebuild per field-app change). A second deployment model; the largest
  single item in the project.
- **Open question that gates all Bluetooth work:** does Scale-Tec publish or
  license its BLE protocol? Yes → reading a weight is days on any platform.
  No → sniffer reverse engineering, unbounded, fragile across firmware.
  **Action: email Scale-Tec.** Costs nothing, decides B vs science project.

## Sizes (build-days at this repo's pace)

| Option | What you get | Size | Ongoing |
|---|---|---|---|
| A. Truck app, typed weights, iPad/iPhone PWA | bunk call, load plan, per-drop pounds, daily actuals per lot | ~5 | none new |
| B. A + Bluetooth on an Android tablet in the cab (Chrome Web Bluetooth) | weights off the scale | +1–2 with the spec; open-ended without | one cheap tablet |
| C. A + Bluetooth on iPad (native wrapper) | same, on the device already carried | +8–10 first cut | Apple account, builds, review delays on every change |

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

A now, B later, never C. The truck is one device; the crew's phones are many.
One Android tablet in the cab buys Bluetooth without dragging the field app
onto the App Store. Email Scale-Tec for the BLE spec this week regardless. Run
typed weights for a month before deciding whether Bluetooth is worth B.
Phase 3 PB import remains the fallback if the truck app never takes.
