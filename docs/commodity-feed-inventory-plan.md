# Commodity feed & mineral inventory — build plan

Bulk commodities in bays, bagged feed and bagged mineral on pallets. FIFO
costed. Usage comes out of **Performance Beef**; purchases and postings tie to
**Redwing**. Feed cost lands on the lot, per day, and turns the Closeout
*Actual* column's cost of gain from an assumption into a number.

**Status:** plan only, nothing built. Drafted 2026-08-27.
**Decisions taken by John, 2026-08-27:** PB export file import · Redwing
*export* report (app hands you postings, Redwing stays the books) · cost lands
**per lot, daily** · mineral is **the same module** with a different
destination.
**Added by John the same day:** feed is expected to be **entered weekly and
charged to lots by commodity**; pasture-level tracking is open for debate. My
answers are in "Tracking by pasture" below — short version: carry a period on
every usage row so a weekly ticket spreads across the head-days it belongs to,
and capture pasture wherever it comes free while requiring it nowhere.
**Bulk feeders are out of scope** (John, 2026-08-27): they are not locations
and the module does not model them. Bulk feed is charged to the lot like any
other commodity.
**Two more, 2026-08-27:** the feed share of cost of gain is **not known yet**
and John will work on it — so Phase 4 no longer waits on it, see "Until the
split exists" below. Bays are **added and edited in the app**, not seeded from
a list.
**A real PB invoice arrived 2026-08-27** (36-27, Aug 17–26). It is **commodity
level**, so ration recipes are cut from the plan; its group is our lot and it
carries **no per-pen breakdown**, so commodity feed is lot-level; and its head
count and head-days **tie to our books exactly**. PB supplies pounds only —
our app owns cost. Details in "Performance Beef" below.

---

## The shape

```
purchases  →  feed_receipts  ────────── FIFO layers (qty_remaining, unit cost)
                    │
weekly entry ───────▶ feed_usage ──▶ feed_usage_costs   (frozen $ per layer slice)
PB import (later)        │  carries a PERIOD, not just a date
                         ├─▶ destination = LOT      → lot feed cost, $/hd/day
                         └─▶ destination = PASTURE  → split to lots by head-days
                                                       (this is how mineral rides)
physical counts →  feed_counts → variance → adjustment usage rows
                                                       │
                                              feed accounting report → Redwing
```

Five moving parts: a catalog, layers, a ledger, counts, and the two reports
that hang off it (lot cost, Redwing postings).

---

## The one rule that shapes everything: cost freezes

Read `docs/processing-cost-and-protocol-versioning.md` before arguing with
this. Processing cost is derived live, and editing a drug price silently
rewrites closed lots and prior fiscal years. Treatment cost freezes per row at
save time and does not.

**Feed follows treatment, not processing.** A feed item carries **no price
column at all.** Price lives on the receipt that brought the load in. When
usage consumes a layer, `feed_usage_costs` records the layer, the pounds and
the dollars *as of that moment*, and nothing later can move them. Correcting a
receipt's cost after its pounds have been consumed is refused by the RPC — you
reverse the usage, fix the receipt, re-post.

Corollary: **never put a `cost_per_lb` on `feed_items`.** The first person who
"just updates the corn price" would rewrite a year of closeouts. There is
nowhere to type it.

Second corollary, straight from the unpriced-medication trap: an uncosted
receipt yields NULL, `SUM()` ignores NULL, and the feed silently becomes free
instead of erroring. A receipt saves without a cost only under an explicit
**cost pending** flag, which shows on Anomalies and blocks the accounting
report for that period until it clears.

---

## Schema

Seven tables, three of them small. All `security_invoker` views, all RLS'd,
`supabase/migrations/20260821000300_rls_verify.sql` run after.

### `feed_items` — the catalog (the Medications analogue)

| column | notes |
|---|---|
| `id`, `name`, `is_active`, `notes` | as `medications` |
| `item_type` | `bulk_commodity` \| `bagged_feed` \| `mineral` \| `additive` |
| `category` | free grouping — energy, protein, byproduct, mineral, hay |
| `stock_unit` | always `lb` internally. See "Units" below. |
| `purchase_unit` | `ton` \| `bag` \| `lb` \| `cwt` — how the ticket reads |
| `lb_per_purchase_unit` | 2000 for a ton, 50 for a bag, 1 for lb |
| `is_counted` | true = counted in whole units (bags). false = estimated (bays). |
| `redwing_account`, `redwing_profit_center`, `redwing_production_center` | coding, carried onto the export |
| `default_location_id` | the bay or barn it normally lands in |
| `pb_name` | PB's own name for it, for import matching — e.g. `Corn hopper bin` |

**No price. Deliberately.** See above.

### `feed_storage_locations` — bays, barns, pallets

`ranch_id` → `ranches`, `name`, `kind` (`bay` \| `barn` \| `pallet`),
`is_bulk`, `capacity_lb`, `is_active`.

A location is somewhere feed is **stored and counted**: a bay, a barn, a
pallet of sacks. Nothing else. Bulk feeders standing in pastures are
deliberately **not** locations (John, 2026-08-27) — feed leaving the bay for a
feeder is simply usage, and no book inventory sits in the pasture.

**Bays are managed in the app, not seeded.** Add, rename, re-capacity and
deactivate, on the same screen pattern as Locations under Settings. There is
no list to hand over up front and no migration to run when a bay changes.
Deactivate rather than delete once a bay has ever held a layer — the same
posture as `medications.is_active`, and for the same reason: hiding it
everywhere without losing its history.

Bays are locations, not items. Corn in Bay 2 and corn in Bay 5 are the same
item at two locations and FIFO runs **per (item, location)** — see "FIFO
scope".

### `feed_receipts` — a load in. This row IS the FIFO layer.

`receipt_date`, `item_id`, `location_id`, `vendor`, `ticket_number`,
`invoice_number`, `qty_purchase_units`, `qty_lb`, `product_cost`,
`freight_cost`, `other_cost`, `total_cost`, `cost_pending` bool,
`qty_lb_remaining`, `notes`, audit columns.

- `unit_cost_per_lb` is **GENERATED**: `total_cost / nullif(qty_lb,0)`.
  Freight is capitalized into the layer — a delivered $/ton is the only number
  that means anything, and splitting freight into a separate expense line
  would make every lot's feed cost read low.
- `qty_lb_remaining` starts at `qty_lb` and only the RPCs touch it.
- Attachments (scale ticket, invoice) reuse the `invoice_attachments` pattern
  if it earns its keep — Phase 6, not Phase 1.

### `feed_usage` — the ledger. One row per feed-out, adjustment or transfer.

`usage_date`, `period_start`, `period_end`, `item_id`, `from_location_id`,
`destination_type` (`lot` \| `pasture` \| `adjustment` \| `transfer`),
`lot_id`, `pasture_id`, `to_location_id`, `qty_lb`, `source`
(`pb_import` \| `manual` \| `count` \| `correction`), `pb_row_key`, `reason`,
`notes`, audit columns.

- **`period_start` / `period_end` exist because feed is entered weekly.** A
  ticket dated Friday for the week's corn is not a Friday cost. Charging it on
  one date hands a lot that shipped Wednesday two days of feed it never ate,
  and hands the lot that arrived Thursday a week of it. The cost spreads
  across the period's head-days, which is the same reason the app writes one
  `sales` row per lot per DAY instead of collapsing a multi-day sheet onto the
  settlement date. A single-day entry just sets both to `usage_date`.

- `pb_row_key` is **UNIQUE and is an UPSERT key, not a duplicate check** —
  same lesson as `(entry_type, client_id)` on `pending_field_entries`. Re-
  importing yesterday's file must overwrite, not double-feed. A corrected row
  in PB re-imports under the same key and replaces (reverse + re-post inside
  one transaction).
- Adjustments and transfers live in the same ledger rather than a second
  table. One place to look for "where did the pounds go" beats two.

### `feed_usage_costs` — the frozen money

`usage_id`, `receipt_id`, `qty_lb`, `unit_cost_per_lb`, `cost`.

One row per layer the usage ate through. This is what makes a reversal exact:
put `qty_lb` back on `receipt_id` and the layers are as they were. It is the
`doctoring_event_meds.cost` of this module.

### `feed_counts` / `feed_count_lines` — the physical count

Header: `count_date`, `location_id`, `counted_by`, `status`
(`draft` \| `posted`), `notes`.
Lines: `item_id`, `counted_qty_lb`, `method` (`counted_bags` \| `estimated` \|
`measured`), `bags_counted`, `estimate_note`, `book_qty_lb` (snapshotted at
post), `variance_lb`, `adjustment_usage_id`.

Bagged is counted; bulk is estimated. `method` records which, because a −4,000
lb variance on an *estimated* bay is Tuesday and a −4,000 lb variance on
*counted* bags is a theft or a keying error, and the variance report must not
present them as the same fact.

### `pb_group_map` — Performance Beef group → lot

`pb_group_name` (unique), `lot_id`, `is_ignored`, `notes`.

PB's group on the 2026-08-27 invoice is literally `36-27`, our own lot number,
so this defaults to matching on `lots.lot_number` and exists for the cases that
do not match cleanly. **Group, not pen** — the invoice lists pens only as a
header string with no pounds against them, so there is nothing per-pen to map.

---

## Units: everything is pounds

Store `qty_lb` on every row. Display in the item's own unit.

A ton of corn in a bay and a 50-lb sack of the same product must be
comparable, and PB reports pounds fed. Every unit the paperwork uses — tons on
the commodity ticket, bags on the mineral pallet, cwt on some invoices —
converts at entry through `lb_per_purchase_unit` and is never stored in its
own unit.

The bag count is kept anyway (`feed_count_lines.bags_counted`) because "we
counted 43 sacks" is the fact that was observed, and reconstructing it from
2,150 lb ÷ 50 invites an off-by-one when someone changes the bag size.

---

## FIFO scope: per (item, location)

Corn moved from Bay 2 to Bay 5 is a `transfer` usage row that consumes Bay 2's
layers and creates a new receipt-layer in Bay 5 at the consumed cost. The
alternative — FIFO per item across all locations — means a count on one bay
can eat a layer physically sitting in another, and the on-hand-by-bay screen
stops reconciling to anything.

**Physically, a bay commingles.** FIFO here is a costing convention, not a
claim about which kernels went out the door. That is fine and it is what every
feedyard does; it is worth saying out loud so nobody tries to make the layers
"honest" later.

---

## Tracking by pasture: worth it, and nearly free

You flagged this as a debate. My read: **capture pasture on every row you can,
require it on none.**

The cost is close to zero, because in two of the three cases the pasture comes
along for free:

- Mineral → the put-out *is* a pasture event; there is no lot in the fact.
- Bunk-fed pen → pasture is whatever the lot is standing on, already in
  `lot_pasture_assignments`.
- Commodity charged straight to a lot with no location in the story → pasture
  is genuinely unknown, and the column stays null.

The payoff is the one you named: **cost of gain that drills down.** Feed by
pasture, against head-days by pasture and acres by pasture, answers questions
COG-per-lot cannot — which pastures are carrying cattle cheaply, what a
commodity actually costs against grass alone, whether the crop ground pays. It
is also *required*, not optional, for any usage aimed at a pasture holding more
than one lot; five pastures are in that position today and Steele / Front
Native has 416 head across two, so the split has to happen regardless.

The one thing to avoid: making pasture **mandatory** on lot-destination rows.
That turns a weekly entry screen into a guessing game on exactly the rows
where the answer is unknown, and a guessed pasture is worse than a null one.

---

## Going short: allowed, flagged, never blocked

A bulk bay is an estimate. PB will report feeding 6,000 lb out of a bay the
books think holds 4,200. Two options:

- **Block the post** until a receipt or count fixes the bay. Correct, and it
  stalls an entire day's imported feeding over an eyeball estimate.
- **Post it, cost the shortfall at the item's most recent unit cost at that
  location, flag the row `is_short`, surface it on Anomalies.**

**Take the second.** The pounds genuinely left; refusing to record them does
not un-feed the cattle, and a lot that shows no feed for three days is a worse
lie than a lot whose feed is costed at last week's corn price. The flag and
the Anomalies line are what make it honest, and the next count squares it.

`feed_usage_costs` still gets a row for the short slice, with a null
`receipt_id` and the cost basis recorded, so the money is auditable and the
reversal is still exact.

---

## RPCs — atomic, INVOKER, reversible

Same posture as `record_death_with_pasture` and friends. INVOKER, never
`SECURITY DEFINER` — none of these needs to bypass RLS and the head-math RPCs
set the precedent.

| RPC | does |
|---|---|
| `post_feed_usage(...)` | consumes FIFO layers oldest-first within (item, location), writes `feed_usage` + `feed_usage_costs`, decrements `qty_lb_remaining`. Handles the short case above. Returns the usage id. |
| `delete_feed_usage(usage_id)` | reverses exactly: adds each `feed_usage_costs.qty_lb` back to its `receipt_id`, deletes the cost rows, deletes the usage. |
| `delete_feed_receipt(receipt_id)` | **refuses** if `qty_lb_remaining <> qty_lb` — consumed pounds carry frozen costs downstream and orphaning them is the whole disaster this module exists to avoid. Reverse the usage first. |
| `post_feed_count(count_id)` | snapshots book quantity per line, computes variance, posts one adjustment usage per non-zero line, marks the count posted. |
| `import_pb_usage(rows jsonb)` | upserts by `pb_row_key`; a changed row reverses and re-posts inside the transaction. |

**The reversal trap from `delete_death_event` applies here in its own form.**
There, reopening a closed assignment *and* adding head back double-counted.
Here it is: a usage that consumed a layer to exactly zero must not be treated
differently from one that partly consumed it — both are just "add
`feed_usage_costs.qty_lb` back." No branch, no special case. Test it against a
usage that emptied a layer outright, not only a partial one.

---

## Views

All `WITH (security_invoker = true)`.

- `feed_on_hand` — item × location: `qty_lb_remaining`, `$ value`,
  weighted-average `$/lb`, oldest layer date, days of supply where a burn rate
  exists.
- `feed_item_on_hand` — rolled to item.
- `lot_feed_costs` — lot: pounds, dollars, `$/hd in`, `$/hd/day`. Head-days
  come from **`lot_head_days_by_month`, the VIEW** — never
  `lot_head_days(uuid,date)`, which anchors on invoice dates and read 29% low
  on 36-27. Cattle eat from the day they hit the ground.
- `lot_feed_daily` — lot × day. **This is where a weekly row gets spread**:
  each usage's dollars are divided over the head-days inside
  `[period_start, period_end]` and land on the days the cattle were actually
  there. It feeds the Closeout projection's burn rate.
- `pasture_feed_allocation` — pasture-destination usage split to the lots
  standing there **by head-days across the usage's period**, largest-remainder
  so the parts sum exactly. Five pastures currently hold more than one lot;
  Steele / Front Native has 416 head across two. Mineral put out on a shared
  pasture is the normal case, not the edge case.
  **In practice this serves mineral and hand-entered pasture rows only** —
  imported commodity feed arrives at lot level and never touches it.
- `pasture_feed_costs` — feed and mineral by pasture: total $, `$/hd/day`,
  `$/acre`, and the lots it split to. The drill-down that makes pasture-level
  capture worth doing.
- `pasture_mineral_costs` — mineral only, by pasture and by lot, `$/hd/day`.
- `feed_count_variance` — book vs counted, by location and item, with `method`
  carried through.
- `feed_accounting_rows` — the Redwing export (below).
- Test lots (`TEST_` / `TEST-`) excluded from every roll-up, as elsewhere.

Everything counting days uses `public.ranch_today()`. The database runs UTC and
the ranch does not; `lot_daily_head` shipped with `CURRENT_DATE` and gained a
whole extra day of head-days every evening after 7pm Central.

---

## Performance Beef: what the 2026-08-26 invoice settles

John sent one real report (36-27, Group Invoice, Aug 17 – Aug 26 2026, ten
days). It answers more than it was asked to, and two of its numbers tie to our
books exactly.

### It ties. Both numbers, on the nose.

| | Performance Beef | our books | |
|---|---|---|---|
| Current head count | 537 | `lot_status.head_current` = **537** | ✅ |
| Total head days | 3,756 | receipts walked day by day, Aug 17–26 = **3,756** | ✅ |

That second one is not a coincidence anyone should take for granted — it means
PB is being kept in step with arrivals as they land, and that **our head-days
and PB's are the same head-days**. Since head-days are the allocation basis for
everything in Phase 4, the two systems will agree on `$/hd/day` by
construction rather than by luck.

It also means the tie-out is worth *checking on every import*, because the day
it stops being true is the day the cost per head quietly stops meaning
anything. See the import mechanics below.

### It is commodity level. Rations are dead.

Eight rows, each naming a commodity — Corn hopper bin, Molasses, DDG, Peanut
Hulls, SoyHull Pellets, Whole Cottonseed, Deccox-Corrid Crumbles, Pennchlor
50G. No ration name anywhere on the sheet.

**So `feed_rations` and `ration_components` are cut from the plan entirely.**
That was the contingency that would have added a table and brought protocol-
style recipe versioning back with it. It is gone, and Phase 3 gets simpler
rather than harder.

### Import the pounds. Never the dollars.

John, 2026-08-27: *"PB doesn't have a very good inventory system. I want to
build a great inventory system. May not even keep cost in PB, just usage."*

That settles the division of labor, and it is the right one:

- **`Amount Fed` is the only column that posts.** It relieves the bay and our
  own FIFO layers price it.
- **`Cost Per Ton` and `Feed Cost` are read for cross-check only** and never
  written. They may go stale, or blank, the moment John stops maintaining
  prices in PB — an importer that depended on them would break silently and
  cost a lot of feed at $0.
- **`Dry Matter Cost Per Ton` and `Dry Matter Fed` are ignored outright.**
  Inventory is bought, stored and counted **as fed**. On this sheet as-fed is
  69,510 lb against 60,881 lb of dry matter — relieving the bay by the dry
  matter figure would leave **12.4% of every load sitting in inventory that
  isn't there.** Dry matter is a nutrition number; it has no business in a
  stock ledger.

The cross-check still earns its place on the preview: our FIFO cost against
PB's, per item, with the variance shown. Divergence is not an error — it is
the difference between what John typed into PB months ago and what the feed
actually cost — but a large one is worth seeing.

### Group = lot. There is no pen breakdown.

The group *is* `36-27`, our lot number. The pens appear once, as a header
string — *In Pens: Corner 1, 2, 3, 4, 7, 9, 8* — with **no pounds broken out
per pen**. So:

- `pb_pen_map` becomes **`pb_group_map`** (PB group name → `lot_id`), and it
  can default to matching on `lots.lot_number` with a manual override for
  anything that doesn't match cleanly.
- **Commodity feed lands at lot level. Full stop.** The per-pasture drill-down
  is not reachable from this report, because the number does not exist in it.
  Pasture allocation stays in the plan for **mineral and hand-entered pasture
  rows only**, which is where it was always load-bearing anyway.

If PB turns out to have a per-pen version of this report, that changes and it
is worth a look — but nothing waits on it.

### Skip the bottom third of the sheet

Yardage ($0.50/hd/day) and the Management Fee ($0.20/hd/day) are John's own
estimates, typed into PB the same way `assumed_labor_per_day` is typed into
the office app. **The importer reads the feed rows and stops.** Pulling in
Yardage or the Management Fee would double-charge against the office app's own
labor and COG lines, which is precisely the double-count this module exists to
stop making.

### The number that matters, with the caveat it needs

Against 3,756 head-days, this invoice runs:

| | total | per head-day |
|---|---|---|
| Feed | $9,643.73 | **$2.57** |
| Yardage | $1,878.00 | $0.50 |
| Management fee | $751.20 | $0.20 |
| **Invoice total** | **$12,272.93** | **$3.27** |

The office app's `assumed_cog_per_day` is about **$0.75**. Feed alone here is
three and a half times that.

**The caveat, stated plainly: this is the worst window in the lot's life to
judge that from.** These are fresh receiving cattle in the Corner pens,
averaging seven days on feed, eating 18.5 lb/hd/day as fed. And $2,860.93 of
the $9,643.73 — **30% of it** — is two medicated additives, Deccox-Corrid
Crumbles at $2,800/ton and Pennchlor 50G at $5,200/ton, which are a receiving
cost and not a grazing one. A month on grass will not look remotely like this.

So: not proof that $0.75 is wrong, but a strong reason to stop guessing. This
is exactly the number Phase 4 produces from real data, which is the argument
for building it rather than deciding it.

One flag for Redwing: **the two additives should almost certainly code to
animal health, not commodity feed.** They are feed-grade drugs. `item_type =
'additive'` already exists to carry that split, and the coding columns on
`feed_items` will do the rest.

### Import mechanics

The export is CSV/Excel — John confirmed one exists. Note it is a *report-
shaped* file, not a flat table: group headers, a feed block, an added-cost
block, a yardage block and a totals block, and "Combined Invoice" / "Select
Groups" means **several groups can sit in one file**. The parser walks
sections; it must not assume one header row and uniform columns.

1. Office picks a file on **Feed → Usage → Import from Performance Beef**.
   Parse client-side — the file never leaves the browser except as parsed rows.
2. Column mapping is confirmed on screen the first time and remembered in
   `localStorage`, wrapped in try/catch — storage *throws* in a private window
   rather than returning empty.
3. Every group resolves through `pb_group_map`. **An unmatched group blocks
   the whole import** and is listed with a picker. A silently skipped group is
   a lot that quietly stops eating.
4. Every feed row resolves through `feed_items.pb_name` — PB's names are PB's
   ("Corn hopper bin" is a commodity and a bin in one string). Unmatched item
   blocks too, with a picker that offers to remember the alias.
5. **Overlap check — the one that matters most.** See below.
6. Preview shows, per group: pounds by item, **lb/hd/day** (18.5 on this
   sheet — a transposed weight shows up here immediately), PB head count and
   head-days against ours, which layers the pounds will consume, which will go
   short, our FIFO dollars, and PB's dollars beside them for comparison.
   Nothing posts until the preview is accepted.
7. Post through `import_pb_usage` in one transaction. Partial failure unwinds,
   same posture as approvals batches.

### Overlapping periods, not duplicate rows, are how this gets corrupted

`pb_row_key` handles re-importing *the same* invoice — it upserts, so running
Aug 17–26 twice is harmless.

**It does not handle an overlapping one.** The date range on that report is
whatever John picks. Run Aug 17–26, then later run Aug 20–31, and the four
overlapping days post twice under *different* keys. The pounds double, the bay
draws down twice, and every $/hd/day on that lot inflates — silently, because
nothing about either import is individually wrong.

So: **`import_pb_usage` refuses any import whose `[period_start, period_end]`
overlaps an already-posted PB period for the same lot**, and names the
conflicting import. Reversing the earlier one first is the deliberate way
through. This is the single most likely way to corrupt this module's books,
and it is cheap to make impossible.

---

## Redwing accounting report

Modelled directly on **Sales → Accounting Report**, which already works and
which John already keys from.

- Reads the ledger, **does not recompute.** A report that re-derived the split
  could drift from the books it documents.
- Two report modes:
  - **Purchases** — one row per `feed_receipts` in the period. Account and
    coding come off `feed_items`, overridable per row.
  - **Period-end usage** — one row per (account, profit center, production
    center = lot) for feed consumed in the period, which is the journal that
    moves feed out of inventory and onto the cattle.
- Columns follow the sales report's order and its editable, `localStorage`-
  remembered Account / Profit Center / Production Year.
- Landscape print, PDF through `sharePdfFile()`, **Copy rows** to
  tab-separated clipboard — the copy button is what actually saves the typing.
- A tie-out line on every render: rows must sum to the period's receipt total
  or usage total. It refuses to look clean when they disagree.
- Blocked while any receipt in the period is `cost_pending`.

---

## Mineral: same module, different destination

Confirmed with John. One catalog, one FIFO engine, one count screen. Mineral
differs in exactly three ways, none of which is worth a second module:

1. It is **counted in sacks**, not estimated — `is_counted = true`.
2. It is consumed by a **pasture**, not a pen or lot, so it allocates through
   `pasture_feed_allocation` by head-days.
3. It reports on its own line: **Mineral $/hd/day**, by pasture and by lot.

It gets its own sub-tab for entry (put-out is a different act from feeding a
pen, and the person doing it thinks in pastures and sacks) and its own report
line. It does not get its own tables.

**Where mineral put-out gets recorded is a live question.** PB may not carry
it. If it does not, the honest answer is the field app — the cowboy who drops
four sacks at Corner is the only one who knows — through
`pending_field_entries` and the Approvals tab, exactly like doctoring. That is
Phase 6 and it is optional; office entry works until then.

---

## Where the money lands, and the one thing that needs deciding

Feed cost per lot per day is the payoff. It plugs into Closeout's *Actual*
column, and the lot's own observed $/hd/day carries the *Projection* forward —
the same treatment `treatment cost` already gets, and for the same reason:
once there is history, the lot's own burn rate beats an assumption.

**Open decision, John's call: does actual feed replace assumed cost of gain,
or sit beside it?**

Today `cog_mode`/`assumed_cog_per_day` (typically ~$0.75/hd/day) is a single
number covering — as best I can tell — feed, grass and yardage together. Drop
actual feed in beside it and that portion is counted twice.

- **A. Feed as its own Actual line; COG keeps running as-is.** Nothing already
  closed moves. Double-counts by whatever share of the $0.75 is feed.
- **B. Actual column stops charging COG entirely once a lot has feed history;
  feed and labor stand alone.** Cleanest arithmetic. Understates any real
  grass and yardage cost that COG was carrying.
- **C. Split the assumed rate: add `lots.assumed_nonfeed_cog_per_day`, and the
  Actual column charges actual feed + non-feed COG.** One new column, no
  history rewritten, arithmetic honest.

**My vote: C**, and it needs one number: of the ~$0.75/hd/day, how much is
feed? Whatever is left becomes the non-feed rate and the books stop guessing
at the feed half.

### Until the split exists

John does not have that number yet (2026-08-27) and is working on it.
**Phase 4 does not wait for it**, because C degrades cleanly:

- Add `lots.assumed_nonfeed_cog_per_day` now and leave it **null**.
- While it is null the Actual column behaves as option **A** — real feed shows
  on its own line, assumed COG keeps running unchanged — and the closeout
  carries a visible note: *"COG still includes an assumed feed share; feed is
  shown separately and the two overlap."* An overlap you can see is a
  different thing from one you cannot.
- The day a lot gets a non-feed rate, that lot switches to C. Per lot, not
  global, so the number can be worked out on one lot and rolled out as
  confidence grows.
- Nothing is recomputed retroactively at the switch. **Do not re-cost lots
  that closed under the assumed rate** — their closeouts are what they were.

That also makes the number easier to find rather than harder: after a few
weeks of real feed data, `lot_feed_costs.$/hd/day` **is** the feed half. The
answer falls out of Phase 4 instead of blocking it.

---

## Access control

Feed is a cost surface. `data-perm="office"` on the whole tab; office + owner
read and write; **crew cannot read any of it.**

- Deletes owner-only, per the standing rule — `feed_usage` and
  `feed_receipts` are audit trails.
- New tables need RLS **and** policies. `ENABLE ROW LEVEL SECURITY` with no
  policy is a total lockout; policies without `ENABLE` are decoration.
- Never GRANT to `anon`. Revoke from `PUBLIC`, not just `anon`.
- If Phase 6 lands, crew writes mineral put-out to `pending_field_entries`
  only — never to `feed_usage` — and the field app must never be handed a
  dollar figure. A crew SELECT returning zero rows is indistinguishable from
  offline; the field app calls `current_user_role()` on load already.

---

## Phases

Each ships on its own and is useful on its own. Nothing here is a big-bang.

| # | what | ships | blocked on |
|---|---|---|---|
| **1** | Schema, RLS, `feed_items`, `feed_storage_locations` (**add / edit / deactivate bays in the app**), `feed_receipts`, `feed_on_hand`. Feed tab with Items / Locations / Receipts / Inventory. | Inventory value on hand, by bay, FIFO-layered. | nothing |
| **2** | `post_feed_usage` + `delete_feed_usage` + the **weekly entry screen** (a grid: commodity × lot, pounds, one period). Counts screen + `post_feed_count` + variance report (printable count sheet). | Books that move, a week keyed in minutes, and a count that squares them. | 1 |
| **3** | *Accelerator, not a prerequisite.* PB import: `pb_group_map`, `pb_name` aliases, section-aware CSV parser, overlap guard, preview with the head-day tie-out, `import_pb_usage`. **No ration recipes — the export is commodity level.** | The weekly keying stops. | nothing (one CSV export to build against) |
| **4** | `lot_feed_costs`, `lot_feed_daily`, `pasture_feed_allocation`, mineral $/hd/day. Closeout integration, degrading to option A while the split is unknown. | Actual cost of gain. The point of all of it. | 2 |
| **5** | Redwing accounting report, both modes. | Postings you copy instead of key. | 2 |
| **6** | *Optional.* Field app mineral put-out → `pending_field_entries` → Approvals. Receipt attachments. | The cowboy records the sacks. | 3, 4 |

Rough sizing: 1 and 2 together are the bulk of the schema and about the size
of the Moves tab. 3 is small once the file is in hand and moderate if rations
need versioning. 4 is small. 5 is a copy of a screen that already exists.

---

## Landmines, collected

Written down because every one of these has already bitten this codebase in
another module.

1. **No price on the item.** Price lives on the receipt layer. Cost freezes on
   consumption. (`medications` → processing cost, the exact opposite behavior,
   is the cautionary tale.)
2. **An uncosted receipt is NULL, and `SUM()` ignores NULL** — feed silently
   becomes free. `cost_pending` flag, Anomalies line, accounting report
   blocked.
3. **A reversal restores the layer and nothing else.** No branch for a layer
   consumed to exactly zero. Test that case first, not last.
4. **`pb_row_key` is an upsert key, not a duplicate check** — and it does
   **not** stop an *overlapping* import. Re-running Aug 17–26 is harmless;
   running Aug 20–31 after it double-feeds four days under different keys.
   `import_pb_usage` refuses overlapping periods per lot.
5. **Relieve inventory with `Amount Fed`, never `Dry Matter Fed`.** On the
   2026-08-27 invoice that is 69,510 lb against 60,881 — a 12.4% phantom
   balance in every bay if the wrong column is read.
6. **Import pounds, never PB's dollars.** John may stop maintaining prices in
   PB entirely; a cost column read from it would go stale or blank in silence.
7. **Head-days come from `lot_head_days_by_month`**, the view, never the
   function.
8. **A weekly usage row spreads over its period, it does not land on its
   date.** A lot that shipped Wednesday must not be charged Thursday and
   Friday's corn. Same rule as one `sales` row per lot per DAY.
9. **`ranch_today()`, never `CURRENT_DATE`**, and `ranchToday()` in the app.
10. **Check `error` on every read.** A `lot_status` read keyed on `id` instead
   of `lot_id` returns undefined data and the code quietly does nothing —
   two live instances were found on 2026-08-26.
11. **Paginate.** PostgREST caps at 1000 rows; a year of daily feed rows across
   60 pastures clears that in a quarter. And a pager takes a builder
   *function* — PostgREST query builders are single-use.
12. **All views `security_invoker = true`**, then run
   `20260821000300_rls_verify.sql`.
13. **Idempotent migration SQL**, `begin;`/`commit;` in the file, stripped only
    if it ever goes through the CLI. Applied by paste into the SQL editor —
    the MCP connector is read-only.
14. **Validate after every `index.html` edit:**
    `osascript -l JavaScript scripts/validate.jxa.js index.html`.

---

## What I need from you to start

1. **One CSV/Excel export of that same invoice** — the screenshot answered
   every design question; the file is only so the parser is built against real
   column headers and real section breaks rather than a guess at them.
   Phase 3 work, not Phase 1.
2. **How a bay gets estimated** — depth and width off a known density, or an
   eyeball in tons? It decides whether the count screen asks for measurements
   or a number. Answerable any time before Phase 2.
3. **Whether mineral put-out is in PB at all.** If not, it is keyed on the
   weekly screen, and Phase 6 (the cowboy records the sacks in the field app)
   stops being optional sooner than the table above suggests.
4. **A view on the two medicated additives** — Deccox-Corrid Crumbles and
   Pennchlor 50G. My read is they code to animal health rather than commodity
   feed in Redwing. Not urgent; it changes two rows on `feed_items`.

**Nothing here blocks a phase.** The COG split is deferred by design (above),
and the bays are typed in on the Locations screen whenever you want — that is
the whole point of building them editable rather than seeded.

Phases 1 and 2 wait on nothing at all.
