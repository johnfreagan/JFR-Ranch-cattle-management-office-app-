# Medicine inventory — FIFO plan

Purchases, usage, shrink and ending inventory for medications, on FIFO, with an
efficiency number for crew doctoring and for the buyers who process our cattle.

Drafted 2026-08-26. **Plan only — nothing here is built yet.**

Decisions taken by John, 2026-08-26:

| | |
|---|---|
| Costing | **FIFO becomes the books.** Treatment *and* processing cost come out of inventory, not out of `medications.cost_per_unit`. |
| Crew usage | **Issues + periodic physical count.** No new burden on the field app. |
| Buyer meds | **Each buyer is a stock location.** Supplier invoice receives into their account; expected usage comes from head processed × protocol. |
| Go-live | **Opening count, go forward.** No backfill. History stays as it is. |

The module lives entirely in the office app (`index.html`). The field app is
not touched.

---

## Why this is three phases and not one

Two of those four decisions are cheap and one is not.

Inventory itself — purchases, issues, counts, shrink, on-hand value — is new
tables and a new tab. It cannot break anything that exists because nothing
reads it.

Making FIFO *the books* is different. Treatment cost is already frozen per row
at save time, so switching the source of that frozen number only affects rows
saved after the switch — low risk. **Processing cost is derived live** off
`delivery_receipts → protocol_meds → medications`, and every lot that ever ran
a protocol reads today's prices. Freezing it means writing cost rows that did
not exist before and rewriting `lot_processing_costs` to read them. Get it
wrong and closeout moves on lots that are already sold.

So: build the ledger, run it in parallel until the numbers are trusted, then
flip the two cost streams — treatment first, processing last, both behind a
cutover date so nothing before the cutover moves at all.

The upside is worth the care. Freezing processing cost **retires the worst
landmine in this app**: today, editing a drug price or a protocol silently
rewrites processing cost for every lot that ever used it, closed lots and prior
fiscal years included, with no audit trail. After phase 3 a price change moves
nothing that already happened. `protocols.effective_from`, which is decorative
today, stops mattering because the cost is captured when the cattle are
processed.

---

## Model

```
med_purchases ── med_purchase_lines ──┬── med_layers (on hand, per location)
   (vet invoice)   (immutable origin: │      qty_remaining, location
                    qty, unit cost,   │
                    mfr lot, expiry)  │
                                      │
med_txns ── med_txn_layers ───────────┘
 (every movement)  (which layers it took, at what cost — frozen)

med_counts ── med_count_lines        med_stock_locations
 (physical count → variance → adjustment txn)
```

Six tables and one lookup. The shape is the shipment allocation shape — a
header, lines, and an allocation table that records exactly which units at
exactly which cost — for the same reason: a movement that cannot say what it
took cannot be reversed.

### `med_stock_locations`

`name`, `kind` (`barn` | `truck` | `buyer` | `vet`), `is_active`, `notes`.

Barn, each crew truck, and one row per buyer — *Buyer — Thigpen*, *Buyer — Jake
Taylor*. Buyer locations are what make the buyer story fall out of the same
machinery as everything else: meds picked up at the supplier never touch the
ranch, so they are received straight into the buyer's location and consumed
from there.

`lots.source` already carries the buyer as free text (`Thigpen`, `Jake Taylor`).
A nullable `source_key` on the location maps to it, so a lot's processing draw
knows whose account to pull from without a schema change to `lots`.

### `med_purchases` / `med_purchase_lines`

Header is the supplier invoice: date, vendor, invoice number, total, notes,
`fiscal_year` (derived by trigger, same July–June rule as everything else).
Attachments follow the `invoice_attachments` pattern.

Each **line is a FIFO layer's origin** and is immutable once posted:

- `medication_id`, `qty_bottles`, `bottle_size`, `unit` (`mL` | `doses`)
- `qty_units` = bottles × size — **the base unit is the unit of account**, not
  the bottle. A 500 mL bottle against a 6 cc dose is not a whole number of
  anything; tracking bottles alone cannot answer "what is on hand".
- `unit_cost` = landed cost ÷ `qty_units`. Freight and handling on the invoice
  allocate across lines by value, so unit cost is landed cost.
- `mfr_lot_number`, `expires_on`, `received_date`

`bottle_size` is **snapshotted on the line**, not read from `medications`.
Bottle sizes change; a layer bought at 500 mL must stay 500 mL after the
catalog says 1000.

### `med_layers`

`purchase_line_id`, `location_id`, `qty_remaining`, `unit_cost`,
`received_date`.

One purchase line can sit in several places at once — half the case in the
barn, two bottles in a truck — so on-hand is its own row per location. A
transfer decrements one layer and creates or increments a layer at the
destination carrying **the same `unit_cost` and the same `received_date`**, so
moving a bottle to a truck does not make it younger and jump the FIFO queue.

FIFO order is `received_date`, then purchase line sequence.

### `med_txns` / `med_txn_layers`

Every movement, one row: `txn_date`, `txn_type`, `medication_id`,
`from_location_id`, `to_location_id`, `qty_units`, `ref_kind`/`ref_id`, notes,
`created_by`, `fiscal_year`.

Types: `opening`, `purchase`, `issue`, `transfer`, `return`,
`usage_treatment`, `usage_processing`, `adjustment` (from a count), `waste`,
`expired`.

Anything that **consumes** writes `med_txn_layers` rows — `layer_id`,
`qty_units`, `unit_cost`, `extended_cost`. That is where the FIFO cost freezes,
and it is what makes a reversal exact: put back precisely what was taken, to
the layers it was taken from. The `delete_death_event` lesson applies —
a reversal that guesses is a reversal that double-counts.

### `med_counts` / `med_count_lines`

Header: `count_date`, `location_id`, `status` (`draft` | `posted`),
`counted_by`. Lines: `medication_id`, `counted_units`, and at post time the
system quantity, the variance in units, and the variance in dollars.

A count is entered as a draft, the variance is **shown before it posts**, and
posting writes one `adjustment` txn per non-zero line. Short lines consume FIFO;
long lines add back to the newest layer at its cost.

**This is where the shrink number comes from.** Nothing else produces one.

---

## Where consumption is recorded

### Crew doctoring — issues, then a count

The crew pulls bottles and uses them across lots for days. Nobody is going to
log a bottle as it empties, and inventory is an office screen anyway. So:

- **Issue** moves bottles barn → truck. Custody, not consumption.
- **Usage** is consumed per doctoring med line at approval — `dose_cc` units out
  of the truck's location, FIFO, cost frozen onto `doctoring_event_meds.cost`.
- **The count trues it up.** What the truck should hold is issues minus recorded
  doses; what it actually holds is the count. The difference is shrink, and it
  is attributed to a truck and a period rather than being a single ranch-wide
  mystery number.

**Never block a doctoring entry on inventory.** If the stock is not there the
entry saves anyway, costs at the most recent layer's unit cost, and the
location goes negative with a flag on the exceptions report. This is animal
health data and a bookkeeping gap is not a reason to lose it. The same rule the
offline queue follows: never a silent drop, never a hard stop on a field record.

### Processing — the buyer's draw

Meds for processing are picked up by the buyer at the supplier and used on our
cattle before they ship. So the pickup is a purchase into that buyer's location,
and the processing of a receipt consumes from it.

Expected units for a receipt are exactly what `lot_processing_costs` already
computes — protocol dose per head at the receipt's weight, rounded by
`round_up_to`, times head — so the arithmetic is not new, only its timing and
its price source.

Two numbers, and they will not agree:

| | |
|---|---|
| **Expected** | head processed × protocol dose. What the cattle should have got. |
| **Drawn** | what the buyer actually picked up. |

**The lot is charged expected, at FIFO cost. The difference is the buyer's
efficiency variance, and it lands on the buyer, not on whichever lot happened
to be processed last.** A buyer who draws a case and uses two thirds of it has
not made one load of cattle more expensive; he has left our stock sitting on his
place. Charging drawn would put his waste onto an arbitrary lot and make
lot-to-lot comparison meaningless.

Unused balance stays on the buyer's location as JFR-owned inventory and shows in
ending inventory, because it is ours.

---

## Efficiency — what the number actually means

Efficiency = **theoretical units ÷ units consumed**, per medication, per period,
per crew truck or buyer.

Theoretical is the sum of recorded doses. Note what that already includes:
`round_up_to` models **the syringe setting including waste**, not drug consumed.
A 6.3 cc dose recorded at 7 cc has already counted 0.7 cc of intended waste. So
this ratio does not measure ordinary dosing waste — it measures the rest:
broken and dropped bottles, expired product, transfer loss, over-drawn
syringes, and **treatments given but never recorded**.

That last one is the reason to build it. A truck running at 80% is either
wasting a fifth of the drug or doctoring cattle that never made it into the
books, and both are worth knowing.

Reported alongside it, because a ratio with no scale is easy to dismiss:

- units and dollars of variance
- doses per bottle achieved vs. label doses per bottle
- treatment cost per head and per head-day, against the lot's own history

Buyer efficiency is the same ratio with expected-from-protocol as the numerator.

---

## Reports

All views `WITH (security_invoker = true)`, no exceptions.

| view | answers |
|---|---|
| `med_on_hand` | units, bottle equivalent, FIFO value, oldest layer, expiring within N days — by med and location |
| `med_inventory_value` | totals by category and location; the number for the balance sheet |
| `med_activity` | the ledger, filterable by med, location, date, type |
| `med_roll_forward` | beginning + purchases − usage − shrink = ending, by month and by fiscal year. Ties by construction. |
| `med_efficiency` | theoretical vs consumed, units and dollars, by med and location and period |
| `med_buyer_reconciliation` | per buyer: drawn, expected from head processed, variance, balance still on their account |
| `med_exceptions` | negative on-hand, unpriced purchase lines, expired stock still on hand, layers older than a year |

Dates use `public.ranch_today()`, never `CURRENT_DATE`. The database runs UTC
and the ranch does not; `lot_daily_head` already lost a day to this once.

---

## The office tab

New top-level **Inventory** tab, `data-perm="office"` — it is all dollars, so
crew never sees it. Sub-tabs:

1. **On hand** — by location, with value, expiring soon, and negatives flagged
2. **Purchases** — enter the vet invoice, attach the PDF
3. **Issues & transfers** — barn → truck, supplier → buyer, returns
4. **Counts** — enter a count, see the variance, then post it
5. **Efficiency** — crew by truck, buyers by name, with the period roll-forward
6. **Reports** — roll-forward and valuation, print landscape and PDF through the
   existing `sharePdfFile()` path

---

## Phases

### Phase 1 — the ledger (no effect on the books)

Tables, RLS and policies, RPCs, views, the Inventory tab. Opening count on a
date John picks. Purchases, issues, transfers, counts, shrink, on-hand value,
and both efficiency reports.

`doctoring_event_meds.cost` and `lot_processing_costs` are **not touched**.
Inventory records usage in parallel and the two costings can be compared before
anything is trusted.

RPCs, all INVOKER with a pinned `search_path`:

- `med_consume(medication_id, location_id, qty_units, txn_type, ref_kind, ref_id, txn_date)`
  → allocates FIFO, writes the txn and its layer rows, returns cost
- `med_reverse_txn(txn_id)` → restores exactly the layers named in `med_txn_layers`
- `med_transfer(...)` → consume at source, mirror the layer at the destination
  preserving unit cost and received date
- `med_post_count(count_id)` → variance → adjustment txns, all or nothing

Run `supabase/migrations/20260821000300_rls_verify.sql` after the migration.

**Run this alone for a period — a month, or through a full round of doctoring —
before phase 2.**

### Phase 2 — treatment cost from FIFO

At approval, each doctoring med line consumes from the crew location and the
FIFO extended cost freezes onto `doctoring_event_meds.cost`. Deleting a
doctoring event reverses the consumption.

No backfill and no cutover table needed: that column is already frozen per row,
so rows written before the switch keep the cost they were written with. Only new
rows change source.

Approvals keeps its unpriced-med flag, which now also means "no layer to draw
from".

### Phase 3 — processing cost from FIFO (the careful one)

1. Pick a **cutover date**.
2. **Snapshot** every existing receipt's currently-derived processing cost into
   `delivery_receipt_med_costs` (receipt, med, units, unit cost, extended cost)
   — the frozen record of what the books said before the switch.
3. New receipts on or after the cutover consume from the buyer's or barn's
   location and write their own frozen rows.
4. Rewrite `lot_processing_costs` / `lot_processing_cost_detail` to read the
   frozen rows instead of recomputing. Keep `unpriced_line_count` — it now means
   "no layer or no cost", which is the same warning wearing a different hat.
5. Verify **every lot's total is unchanged to the cent** on the day of the
   switch. That is the acceptance test; if a lot moves, stop.

After this, repointing a receipt to a new protocol version (the documented
Draxxin → Macrosyn procedure) means reverse and re-consume, not just an
`UPDATE`. `docs/processing-cost-and-protocol-versioning.md` and the CLAUDE.md
section both need rewriting when this lands — the rule they teach is
deliberately reversed by it.

---

## Access

Office and owner read and write. Crew: no access to the tab and no grants on
the tables — this is entirely dollars, and unlike `medications` there is no
field-app dependency forcing a compromise.

Owner-only DELETE on `med_txns`, `med_purchases` and `med_counts`, matching the
existing rule: the ledger is an audit trail, and an accidental delete there is
unrecoverable in a way an accidental insert is not. Corrections are reversals,
not deletions.

---

## Open questions — my votes, not yet decided

1. **Insufficient stock at doctoring.** My vote: save anyway, cost at the last
   known unit cost, flag on exceptions. Never block an animal health record.
2. **Expired product.** My vote: track `expires_on`, warn on the on-hand screen,
   and write off with an `expired` txn — separate from count shrink, since
   expiry is a buying problem and shrink is a handling problem.
3. **Freight on the vet invoice.** My vote: allocate across lines by value into
   unit cost, so FIFO carries landed cost.
4. **Trucks — one location or several?** My vote: one per truck if the crew's
   boxes are actually distinct; one shared "Crew" location if bottles move
   between them freely. A location that does not match reality only manufactures
   variance. Needs John's read on how the boxes are actually run.
5. **Count cadence.** My vote: monthly, and mandatory at 6/30 for the fiscal
   year close.
6. **Opening count date.** Needs a date from John.
7. **Does `medications.cost_per_unit` stay?** After phase 3 nothing costs from
   it. My vote: keep it, relabel it "last purchase price", and use it as the
   fallback when there is no layer — but stop calling it the price.
