# Feed truck module — what was built, where it lives, what is open

Written 2026-09-11 as a handoff. The *why* behind every decision is in
`feed-truck-integration-scope.md` (D1–D26); this file is the map, the state,
and the known defects. Nothing here is a plan — it is what exists.

## What it replaces

Performance Beef's feed-truck side: ration management, bunk calling, the
Bluetooth scale link, and the pounds that become feed cost per lot. PB keeps
running in parallel until a cut-over date is set. **Nothing posts to the books
until `ranch_settings.feed_truck_post_from` is set, and it is still null.**

## Hard rules John set (they explain most of the design)

1. The scale is the only source of pounds — no hand capture.
2. Nothing advances without a tap; no auto-advance on the load screen.
3. No feed until the mix timer hits zero. No override.
4. No deleting a drop; no cancelling a load. Void with a reason, or edit
   until posted.
5. Parallel with PB first, cut over later.

Rules 1 and 3 have drifted — see Known defects.

## The shape

```
BUNK READ ──▶ PLAN ──▶ LOAD ──▶ MIX ──▶ DROP ──▶ CLOSE ──▶ POST
 score+lb/hd  balanced  scale    timer   scale    leftover   feed_usage
 (or a call   loads by  per      hard    per      carries    per (line, lot)
  per bulk    ration    ingredient gate  pasture  forward    on/after cut-over
  feeder)
```

```
bunk_reads ─▶ feed_loads ── feed_load_lines (item, bay, scale_lb, lb)
                  └──────── feed_drops ── feed_drop_lots (lot, head, lb)
                                 │  post_feed_load()
                                 ▼
                          feed_usage (source='truck')
                          feed_load_usage links them, so unpost reverses
```

Two delivery modes. **direct**: the truck drives to each pasture and every
drop is the fall in gross between Start and Done. **cart** (bulk feeders):
mixes go into a grain cart that has no scale, so the load's actual mixed
pounds are allocated across the feeders actually filled, pro-rata to what was
called, largest-remainder so the parts sum exactly. `feed_drops.method` says
which — `scale` or `allocated` — on every row.

## File map

| Path | What it is |
|---|---|
| `feed-app/index.html` | the PWA shell: login, five tabs, PB-shaped truck screens |
| `feed-app/app.js` | ~2,000 lines: refs pull, bunk calling, plan, load/mix/drop, offline queue, weather |
| `feed-app/planner.js` | pure module — `planLoads()`, `planCart()`, `lrSplit()`. No DOM, no Supabase |
| `feed-app/planner.test.js` | 14 tests, `node feed-app/planner.test.js`. **The only committed test.** |
| `feed-app/sw.js` | network-first shell. Bump `CACHE_VERSION` and `index.html`'s `?v=` together |
| `feed-app/README.md` | the scale bridge contract the Flutter shell must satisfy |
| `index.html` (root) | office side: Inventory → Truck ▾ — Loads, Tie-out, Rations, Pastures & route, Bunk sheet, Feed vs weather, Trucks, Settings |
| `docs/feed-truck-integration-scope.md` | the design record, D1–D26 |
| `docs/sql/2026-09-0*` | the migrations, below |

## Migrations, in order

Apply through the Supabase SQL editor (the MCP connector is read-only, and the
editor swallows `begin;`/`commit;`). Each is idempotent and ends in a verify
block that raises if the state is wrong.

| File | Adds | Applied? |
|---|---|---|
| `2026-09-04_feed_truck.sql` | the 10 tables, RLS, guards, `lr_split`, `split_drop_to_lots`, `post_feed_load`, `unpost`, `void`, `post_due_feed_loads`, 3 views | yes |
| `2026-09-05_feed_truck_read_order.sql` | `read_order` + the crew-update guard | yes |
| `2026-09-06_bunk_scoring.sql` | SDSU scores (numeric ½), `dry_matter_pct`, `expected_dmi_lb`, bump rules | yes |
| `2026-09-06_bunk_weather.sql` | `expected_dmi_pct_bw`, `daily_weather`, ranch lat/lon, read flags | yes |
| `2026-09-06_bunk_cut_pct.sql` | `bunk_cut2_pct` (10), `bunk_cut3_pct` (25) | **unconfirmed** |
| `2026-09-06_bulk_feeders.sql` | `feeder_capacity_lb`, `feed_drops.method`/`called_lb`, `feed_loads.delivery_mode` | **unconfirmed** |
| `2026-09-07_placed_feed.sql` | `for_lot_id`, `claim_placed_feed()`, `feed_placed_unclaimed`, rewrites `post_feed_load` + `split_drop_to_lots` + `feed_load_guard` + the Needs Attention view | **unconfirmed** |

**There is no record in the repo of what the database has actually received.**
The three marked unconfirmed were handed over in chat and never acknowledged.
Until the app and the database agree, writes fail into the offline queue and
retry — see defect 3.

**Drift warning:** `post_feed_load` and `split_drop_to_lots` are defined in
both `2026-09-04_feed_truck.sql` and `2026-09-07_placed_feed.sql`;
`inventory_needs_attention` is in both `2026-08-31_inventory_flow.sql` and
`2026-09-07_placed_feed.sql`. **The later file wins.** Reading the older one
gives you a function the database no longer runs.

## How money gets there

- A load posts **what left the bays, over the lots it dropped to**. Each
  ingredient line's pounds split across destinations pro-rata by dropped
  pounds, one `feed_usage` row per (line, destination), dated the load date.
- **Left in the box is charged to the load that mixed it**; the next load's
  ingredients are cut by that leftover, so it nets out across loads. A cart
  leftover works the same but in its own vessel — it never cuts the next
  mixer load.
- **A destination can be a pasture, not a lot** — feed placed in a trap before
  the cattle arrive. `claim_placed_feed()` moves it to the lot on that lot's
  first day with cattle, because cost of gain divides by head-days.
- **Posting is automatic**, prior-day only, on/after the cut-over:
  `post_due_feed_loads()` runs when the Inventory tab opens (office/owner,
  throttled 10 minutes). Editable until posted; `unpost` reverses exactly what
  post wrote; `void` needs a reason and refuses a posted load.

## Bunk calling

SDSU slick-bunk scores 0 / ½ / 1 / 2 / 3, clean = 0 or ½. **Bumps are pounds
of dry matter** (0.75 after 2 clean days below target intake, 0.5 after 3 at
or above); **cuts are percentages** (score 2 = −10%, score 3 = −25% of
yesterday's call). Expected intake is a **percent of body weight** on the
ration, applied to the pasture's head-weighted estimated weight, so the target
climbs as the cattle grow. All eight numbers are on Truck → Settings.

Bulk feeders are off the daily read; they are called from the feeders card on
Plan on the days they are filled.

## Reports

- **Load ticket** — Print ticket on a load: ingredients target vs scale, mix
  required vs taken, every drop with how it was measured, lots charged.
- **Bunk sheet** — pastures down, days across with the weather, score and call
  over what was actually delivered. Prints landscape.
- **Feed vs weather** — delivered pounds over the head the split carried, by
  day, with averages by temperature band. Days the truck did not go out are
  left out, never averaged as zero.
- **Tie-out vs PB** — lb per lot per commodity per PB week, plus split head
  against `lot_daily_head` on the same days. This is the gate on cut-over.

## Known defects (audit, 2026-09-11)

Ranked. Items 1–3 produce wrong numbers or lose data with no warning.

1. **`claim_placed_feed()` counts success it never verified** —
   `2026-09-07_placed_feed.sql:325` increments unconditionally after the
   UPDATE. If RLS blocks it the function still reports rows claimed. Needs
   `GET DIAGNOSTICS`.
2. **The 1,000-row PostgREST cap is ignored** on `bunk_reads` in both the
   office bunk sheet (`index.html:28043`) and the feed app's pull
   (`feed-app/app.js:286`). At ~60 pastures × 21 days it silently truncates,
   taking history the bump rule reads.
3. **An unapplied migration retries forever** — `PERMANENT_PG_CODES`
   (`feed-app/app.js:172`) has no `42703` / `42P01` / `PGRST204`. Needs those
   codes and a boot-time schema check.
4. **Two trucks can feed the same pasture.** The plan nets only what the
   device knows; the read freeze travels through the offline queue. Starting a
   load should claim the reads server-side.
5. **A load cannot be abandoned from the cab** — void is office-only, so a
   mis-tapped Start blocks the truck.
6. **A load left open never posts and never nags.** No stale-load row on
   Needs Attention.
7. **The mix gate is UI-only.** No database refuses a drop inside the mix
   window; the ticket reports "short" after the fact.
8. **Forecast weather rows are never corrected** if the app is unused for more
   than 7 days, and the report then reads them as actuals.
9. **Expected intake is biased low** — it is built on the deliberately
   conservative target ADG, so pens read "at target" early and downshift to
   slow bumps sooner than they should.
10. **Claimed trap feed lands entirely on one day** in `lot_feed_daily`, which
    distorts per-day intake reporting (lot totals are right).
11. **A bulk call defaults to full feeder capacity**, ignoring what is still
    in the feeder. Over-calls every partly-full feeder.
12. **Feed vs weather bands** will print percentages off three-day samples.

## Testing, and what is missing

- `node feed-app/planner.test.js` — 14 tests, committed.
- `node scripts/validate.js index.html` — script parse + div balance. Run
  after every edit to the office app.
- **The rest is gone.** The browser smoke harness (83 assertions), the SQL
  stub schema and its behavioural tests, and the office demo driver all lived
  in a scratch directory and were not committed. Four live bugs were caught by
  them and none of that is reproducible today. There is no CI.

## Not built

- **Phase 3, the Flutter shell** — the Scale-Tec template plus a WebView on
  this app and the JS bridge in `feed-app/README.md`. Needs a Mac with Xcode
  and John's Apple developer account. **Until it exists no real scale has ever
  been connected; everything has run on the simulated scale.**
- Feeders due / empty-date estimate and the refill notice.
- The two charts on the bunk page.
- Anomalies rows for over-tolerance, skipped mix, overrides.
