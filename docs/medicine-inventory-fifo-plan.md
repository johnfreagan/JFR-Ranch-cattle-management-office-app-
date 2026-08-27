# Medicine inventory — FIFO plan

Purchases, usage, shrink and ending inventory for medications, on FIFO, with an
efficiency number for crew doctoring and for the buyers who process our cattle.

Drafted 2026-08-26, updated 2026-08-27. **Plan only — nothing here is built yet.**

Decisions taken by John:

| | |
|---|---|
| Costing | **FIFO becomes the books.** Treatment *and* processing cost come out of inventory, not out of `medications.cost_per_unit`. |
| Crew usage | **One shared crew location, custody tracked per person.** Issues are checked out to a named crew member; a periodic count trues the location up. Nothing new for the field app. |
| Buyer meds | **Each buyer is a stock location.** Supplier invoice receives into their account; expected usage comes from head processed × protocol. |
| Go-live | **Opening count, soft target 2026-09-01**, subject to build speed. No backfill. |
| Invoice intake | **Attach the PDF and paste the rows**, through a review grid that must tie to the invoice total. No straight-to-post parsing. |
| Redwing | **Date-ranged report in the Sales accounting-report format.** Weekly vs monthly becomes a picker, not a schema decision. |

The module lives entirely in the office app (`index.html`). The field app is
not touched.

---

## Why this is three phases and not one

Two of those decisions are cheap and one is not.

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

`name`, `kind` (`barn` | `crew` | `buyer` | `vet`), `is_active`, `notes`.

Barn, **one shared crew location**, and one row per buyer — *Buyer — Thigpen*,
*Buyer — Jake Taylor*. Buyer locations are what make the buyer story fall out of
the same machinery as everything else: meds picked up at the supplier never
touch the ranch, so they are received straight into the buyer's location and
consumed from there.

`lots.source` already carries the buyer as free text (`Thigpen`, `Jake Taylor`).
A nullable `source_key` on the location maps to it, so a lot's processing draw
knows whose account to pull from without a schema change to `lots`.

### `med_purchases` / `med_purchase_lines`

Header is the supplier invoice: date, vendor, invoice number, total, notes,
`fiscal_year` (derived by trigger, same July–June rule as everything else).
Attachments follow the `invoice_attachments` pattern — `uploadAttachment()` and
the storage bucket already exist.

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
barn, two bottles with the crew — so on-hand is its own row per location. A
transfer decrements one layer and creates or increments a layer at the
destination carrying **the same `unit_cost` and the same `received_date`**, so
moving a bottle to the crew does not make it younger and jump the FIFO queue.

FIFO order is `received_date`, then purchase line sequence.

### `med_txns` / `med_txn_layers`

Every movement, one row: `txn_date`, `txn_type`, `medication_id`,
`from_location_id`, `to_location_id`, `qty_units`, `crew_user_id`,
`ref_kind`/`ref_id`, notes, `created_by`, `fiscal_year`.

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

### Crew doctoring — one location, custody by person

The crew pulls bottles and uses them across lots for days. Nobody is going to
log a bottle as it empties, and inventory is an office screen anyway. Bottles
also move between hands freely, so **the stock location is shared and the
custody is per person** — a location per cowboy would only manufacture variance
every time somebody handed a bottle across a chute.

- **Checkout** is an `issue` txn: barn → crew location, carrying
  `crew_user_id`. Custody, not consumption.
- **Usage** is consumed per doctoring med line at approval — `dose_cc` units out
  of the crew location, FIFO, cost frozen onto `doctoring_event_meds.cost`.
  `doctoring_events.recorded_by_user_id` already says who gave it.
- **The count trues the location up.** What the crew should hold is checkouts
  minus recorded doses; what they actually hold is the count. The difference is
  shrink.

`med_custody` (view) is the per-person sub-ledger: checked out − returned −
doses recorded by that person = outstanding. **That number is fair over a
month and unfair over a day** — a bottle checked out by one man and finished by
another shows up as one running high and the other low until it washes out. The
dollars still reconcile at the location level either way, because the count
does not care whose hand the bottle was in. Say that on the screen; a per-person
number nobody trusts is worse than none.

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
per crew member or buyer.

Theoretical is the sum of recorded doses. Note what that already includes:
`round_up_to` models **the syringe setting including waste**, not drug consumed.
A 6.3 cc dose recorded at 7 cc has already counted 0.7 cc of intended waste. So
this ratio does not measure ordinary dosing waste — it measures the rest:
broken and dropped bottles, expired product, transfer loss, over-drawn
syringes, and **treatments given but never recorded**.

That last one is the reason to build it. A crew running at 80% is either
wasting a fifth of the drug or doctoring cattle that never made it into the
books, and both are worth knowing.

Reported alongside it, because a ratio with no scale is easy to dismiss:

- units and dollars of variance
- doses per bottle achieved vs. label doses per bottle
- treatment cost per head and per head-day, against the lot's own history

Buyer efficiency is the same ratio with expected-from-protocol as the numerator.

---

## Getting the invoice in

The app is one static HTML file on GitHub Pages. No build step, no server, and
the only libraries are the four already on CDN. That is what bounds this
answer.

| approach | reads a **scan**? | cost |
|---|---|---|
| **Attach the PDF, type the lines** | n/a | already built — `uploadAttachment()`, storage bucket, `invoice_attachments` pattern |
| **Paste rows** — Claude/Cowork reads the PDF, hands back tab-separated rows, paste into a review grid | **yes**, and well | small; it is the accounting report's "Copy rows" run backwards |
| pdf.js text extraction, parsed per vendor | **no** — a scan is an image and pdf.js finds no text in it | medium, and only ever helps invoices that arrive by email |
| Tesseract.js OCR in the browser | yes, poorly | 2–4 MB of wasm, slow per page, and it errs precisely on digits |
| Supabase Edge Function → Claude → structured lines | **yes**, best | real infrastructure: a function, a stored secret, and a deploy path this repo does not have yet |

**Recommended: attach + paste rows now, Edge Function later if the volume
justifies it.** The Cowork habit already exists for Redwing exports (roadmap
item 4) and this is the same motion — and unlike the browser options it reads a
photographed or faxed invoice as well as a clean one.

**One rule holds regardless of method: nothing posts straight from a parse.**
Every extracted line lands in a review grid showing quantity, unit cost and
extended cost with a running total against the invoice, and it **cannot post
until that total ties**. A wrong unit cost does not throw. It silently prices
every future FIFO draw off that layer, and by the time it surfaces it is frozen
into treatment cost on a dozen lots.

---

## The Redwing report

Same shape as the Sales → Accounting Report, for the same reason: it is the
format Redwing takes. Twelve columns in Redwing's order, Account / Profit Center
/ Production Year editable and remembered in `localStorage` (try/catch — storage
throws outright in a private window), landscape print, PDF through
`sharePdfFile()`, and **Copy rows** to tab-separated text, which is what
actually saves the typing.

Rows for a period:

| row set | Production Center | Amount |
|---|---|---|
| Usage, one row per (lot, med category) | the lot | FIFO cost consumed |
| Shrink and expiry write-offs | blank | adjustment value |
| Ending inventory | blank | on-hand valuation at period end |

**The report is date-ranged, so weekly vs monthly is a picker rather than a
decision that has to be made now.** But the two are not equally meaningful:
usage can be stated for any range because doctoring events are dated; **shrink
cannot, because it only exists once a count is posted.** For a range that does
not end on a count date the report states usage and says plainly that shrink is
un-counted for the period, rather than printing a zero that reads as "none".

**Open question — does Redwing already receive the vet-supply invoice through
AP?** If it does, this report posts only the usage allocation and the inventory
adjustment; adding purchase rows would double-count the same invoice. If it does
not, purchases get a row set of their own. A sample of what gets handed to
Redwing for meds today settles it in one look.

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
| `med_custody` | per crew member: checked out, returned, doses recorded, outstanding |
| `med_buyer_reconciliation` | per buyer: drawn, expected from head processed, variance, balance still on their account |
| `med_exceptions` | negative on-hand, unpriced purchase lines, expired stock still on hand, layers older than a year |

Dates use `public.ranch_today()`, never `CURRENT_DATE`. The database runs UTC
and the ranch does not; `lot_daily_head` already lost a day to this once.

---

## The office tab

New top-level **Inventory** tab, `data-perm="office"` — it is all dollars, so
crew never sees it. Sub-tabs:

1. **On hand** — by location, with value, expiring soon, and negatives flagged
2. **Purchases** — attach the invoice PDF, paste or type the lines, tie, post
3. **Checkouts & transfers** — barn → crew (to a named person), supplier →
   buyer, returns
4. **Counts** — enter a count, see the variance, then post it
5. **Efficiency** — crew by person, buyers by name, with the period roll-forward
6. **Reports** — Redwing report, roll-forward and valuation; print landscape and
   PDF through the existing `sharePdfFile()` path

---

## Phases

### Phase 1 — the ledger (no effect on the books)

Target: **opening count 2026-09-01**, soft. If the build runs past it, the count
is still dated 9/1 and everything since is entered in date order behind it —
what cannot happen is a txn dated before the opening layers exist.

Note the first fiscal year of inventory is a partial one: FY 2027 runs
2026-07-01 to 2027-06-30, so its roll-forward opens on the 9/1 count rather than
on zero. The report should say so on its face, or the year looks short.

Tables, RLS and policies, RPCs, views, the Inventory tab. Purchases with the
paste-and-tie importer, checkouts, transfers, counts, shrink, on-hand value,
the Redwing report, and both efficiency reports.

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
field-app dependency forcing a compromise. Crew members are *named* in custody
rows without being able to read them.

Owner-only DELETE on `med_txns`, `med_purchases` and `med_counts`, matching the
existing rule: the ledger is an audit trail, and an accidental delete there is
unrecoverable in a way an accidental insert is not. Corrections are reversals,
not deletions.

---

## Settled since the first draft (2026-08-27)

1. **Insufficient stock at doctoring** — save anyway, cost at the last known
   unit cost, flag on exceptions. Never block an animal health record.
2. **Expired product** — track `expires_on`, warn on the on-hand screen, write
   off with an `expired` txn, kept separate from count shrink; expiry is a
   buying problem and shrink is a handling problem.
3. **Freight on the vet invoice** — allocated across lines by value into unit
   cost, so FIFO carries landed cost.
4. **Crew locations** — one shared crew location, custody per person.
5. **Count cadence** — monthly, and mandatory at 6/30 for the fiscal year close.
6. **Opening count** — soft target 2026-09-01.
7. **`medications.cost_per_unit`** — kept, relabelled "last purchase price",
   used as the fallback when there is no layer. It stops being called the price.

## Still open

- **Does Redwing already get the vet-supply invoice through AP?** Decides
  whether the report posts purchases or only usage and adjustments.
- **Report cadence** — weekly or monthly. Deliberately deferred: the report is
  date-ranged, so this is a habit rather than a build decision.
