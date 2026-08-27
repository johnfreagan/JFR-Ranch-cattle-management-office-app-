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

---

## The shape

```
purchases  →  feed_receipts  ────────── FIFO layers (qty_remaining, unit cost)
                    │
Performance Beef ──▶ feed_usage ──▶ feed_usage_costs   (frozen $ per layer slice)
   (CSV import)          │
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

**No price. Deliberately.** See above.

### `feed_storage_locations` — bays, barns, pallets

`ranch_id` → `ranches`, `name`, `kind` (`bay` \| `barn` \| `pallet` \|
`pasture_feeder`), `is_bulk`, `capacity_lb`, `is_active`.

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

`usage_date`, `item_id`, `from_location_id`, `destination_type`
(`lot` \| `pasture` \| `adjustment` \| `transfer`), `lot_id`, `pasture_id`,
`to_location_id`, `qty_lb`, `source` (`pb_import` \| `manual` \| `count` \|
`correction`), `pb_row_key`, `reason`, `notes`, audit columns.

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

### `pb_pen_map` — Performance Beef pen → JFR

`pb_pen_name` (unique), `pasture_id`, `lot_id`, `is_ignored`, `notes`.

PB's pen names are PB's. Mapping them is our side, exactly like mapping the
buyer's truckloads to lots on a shipment.

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
- `lot_feed_daily` — lot × day, for the Closeout projection's burn rate.
- `pasture_feed_allocation` — pasture-destination usage split to the lots
  standing there **by head-days on the usage date**, largest-remainder so the
  parts sum exactly. Five pastures currently hold more than one lot; Steele /
  Front Native has 416 head across two. Mineral put out on a shared pasture is
  the normal case, not the edge case.
- `pasture_mineral_costs` — mineral only, by pasture and by lot, `$/hd/day`.
- `feed_count_variance` — book vs counted, by location and item, with `method`
  carried through.
- `feed_accounting_rows` — the Redwing export (below).
- Test lots (`TEST_` / `TEST-`) excluded from every roll-up, as elsewhere.

Everything counting days uses `public.ranch_today()`. The database runs UTC and
the ranch does not; `lot_daily_head` shipped with `CURRENT_DATE` and gained a
whole extra day of head-days every evening after 7pm Central.

---

## Performance Beef import

**Blocked on one thing: a sample export.** I need one real file before writing
a parser — column names, date format, whether pens repeat, and the question
below.

### The question the sample answers

**Does PB export at commodity level or at ration level?**

- *Commodity/ingredient level* (each row names corn, DDG, hay): imports
  straight into `feed_usage`, one row per (date, pen, ingredient). Nothing
  more is needed.
- *Ration level* (rows name "Grower 12%" and pounds fed): the app must hold
  the recipe to relieve inventory. That adds `feed_rations` and
  `ration_components` (item, inclusion %, effective_from), and it brings back
  the versioning problem in full: **change a recipe and you rewrite what every
  past load was made of** — unless component percentages are frozen onto the
  usage rows at import, which is what I would do. Same lesson as protocols,
  same fix, one more table and about a day of work.

Assume ration level until the file says otherwise; PB's whole model is rations
and most exports follow it.

### Import mechanics

1. Office picks a file on **Feed → Usage → Import from Performance Beef**.
   Parse client-side (no upload; the file never leaves the browser except as
   parsed rows).
2. Column mapping is confirmed on screen the first time and remembered in
   `localStorage`, wrapped in try/catch — storage *throws* in a private
   window rather than returning empty.
3. Every row resolves its pen through `pb_pen_map`. **Unmatched pens block the
   whole import** and are listed with a picker to map them. A silently skipped
   pen is a lot that quietly stops eating.
4. Preview shows: rows, pounds by item, destinations, which layers they will
   consume, which will go short, and total dollars. Nothing posts until the
   preview is accepted.
5. Post through `import_pb_usage` in one transaction. Partial failure unwinds,
   same posture as approvals batches.

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

**My vote: C** — and I need one number from you to set it: of your ~$0.75/hd/
day cost of gain, how much is feed? Whatever is left becomes the non-feed rate
and the books stop guessing at the feed half.

Either way, **do not retroactively re-cost lots that closed under the assumed
rate.** Their closeouts are what they were.

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
| **1** | Schema, RLS, `feed_items`, `feed_storage_locations`, `feed_receipts`, `feed_on_hand`. Feed tab with Items / Locations / Receipts / Inventory. | Inventory value on hand, by bay, FIFO-layered. | nothing |
| **2** | `post_feed_usage` + `delete_feed_usage` + manual usage entry. Counts screen + `post_feed_count` + variance report (printable count sheet). | Books that move, and a count that squares them. | 1 |
| **3** | PB import: `pb_pen_map`, parser, preview, `import_pb_usage`. Ration recipes if the export needs them. | The daily data stops being typed. | **a sample PB export** |
| **4** | `lot_feed_costs`, `lot_feed_daily`, `pasture_feed_allocation`, mineral $/hd/day. Closeout integration per the decision above. | Actual cost of gain. The point of all of it. | 2, and the A/B/C call |
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
4. **`pb_row_key` is an upsert key, not a duplicate check.**
5. **Head-days come from `lot_head_days_by_month`**, the view, never the
   function.
6. **`ranch_today()`, never `CURRENT_DATE`**, and `ranchToday()` in the app.
7. **Check `error` on every read.** A `lot_status` read keyed on `id` instead
   of `lot_id` returns undefined data and the code quietly does nothing —
   two live instances were found on 2026-08-26.
8. **Paginate.** PostgREST caps at 1000 rows; a year of daily feed rows across
   60 pastures clears that in a quarter. And a pager takes a builder
   *function* — PostgREST query builders are single-use.
9. **All views `security_invoker = true`**, then run
   `20260821000300_rls_verify.sql`.
10. **Idempotent migration SQL**, `begin;`/`commit;` in the file, stripped only
    if it ever goes through the CLI. Applied by paste into the SQL editor —
    the MCP connector is read-only.
11. **Validate after every `index.html` edit:**
    `osascript -l JavaScript scripts/validate.jxa.js index.html`.

---

## What I need from you to start

1. **A Performance Beef export.** Any real day or week. This is the only hard
   blocker, and it decides whether Phase 3 is small or medium.
2. **The COG split** — of ~$0.75/hd/day, how much is feed? (Option C above.)
3. **The bay list**: which bays exist, at which ranch, and roughly what each
   holds.
4. **How a bay gets estimated** — depth and width off a known density, or an
   eyeball in tons? It decides whether the count screen asks for measurements
   or a number.
5. **Whether mineral put-out is in PB at all.** If not, Phase 6 stops being
   optional sooner than the table above suggests.

Phase 1 does not wait on any of it except the bay list, and that can be typed
in the app once the screen exists.
