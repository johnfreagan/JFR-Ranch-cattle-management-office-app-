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
| Invoice intake | **Cowork paste or hand entry, into the same grid** (John, 2026-08-27). The grid is the screen; paste fills it, typing fills it, and either way it must tie to the invoice total before it posts. |
| Build | **As simple as it can be and still be right** (John, 2026-08-27). One stock pool for the ranch, no transfers, five transaction types, three RPCs. |
| Where inventory lives | **Full inventory runs in the office app** (John, 2026-08-27). Redwing is a periodic cross-check, not the authority we defer to. |
| Redwing | **Redwing is the GL; this is the subsidiary ledger.** Date-ranged report in the Sales accounting-report format; weekly vs monthly becomes a picker, not a schema decision. |

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
med_purchases ── med_purchase_lines ──┐   the line IS the FIFO layer:
   (vet invoice)   (location, qty,    │   location + qty_remaining live on it
                    unit cost,        │
                    qty_remaining)    │
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

**What got cut to keep this simple.** The first draft had a separate
`med_layers` table so one purchase could sit in several places at once, plus a
transfer RPC that split layers and mirrored them at the destination preserving
received dates. All of that existed to move stock between locations — and in
practice stock never moves. Meds bought for the ranch stay at the ranch; meds a
buyer picks up at the supplier never come here. So **a purchase line is received
to one location and stays there**, `location_id` and `qty_remaining` sit on the
line itself, and the fiddliest machinery in the design disappears. If stock ever
genuinely does move, it is an adjustment out and an adjustment in — which the
count screen already writes.

### `med_stock_locations`

`name`, `kind` (`ranch` | `buyer`), `is_active`, `notes`.

**One row for the ranch, one per buyer** — *Ranch*, *Buyer — Thigpen*,
*Buyer — Jake Taylor*. That is the whole list.

The barn and the crew boxes are **one pool**, not two. A bottle in a truck has
not left the ranch; it is the same inventory in a different hand, and who has it
is custody, tracked on the person and not on the stock. That also makes the
monthly count simpler in the pen: count the barn and the trucks and enter one
number per med.

Buyer locations are what make the buyer story fall out of the same machinery:
meds picked up at the supplier never touch the ranch, so they are received
straight into the buyer's row and consumed from there.

`lots.source` already carries the buyer as free text (`Thigpen`, `Jake Taylor`).
A nullable `source_key` on the location maps to it, so a lot's processing draw
knows whose account to pull from without a schema change to `lots`.

### `med_purchases` / `med_purchase_lines`

Header is the supplier invoice: date, vendor, invoice number, total, notes,
`fiscal_year` (derived by trigger, same July–June rule as everything else).
Attachments follow the `invoice_attachments` pattern — `uploadAttachment()` and
the storage bucket already exist.

**Each line IS a FIFO layer.** `location_id` and `qty_remaining` live on the
line; everything else about it is immutable once posted:

- `medication_id`, `location_id`, `qty_bottles`, `bottle_size`, `unit`
- `qty_units` = bottles × size — **the base unit is the unit of account**, not
  the bottle. A 500 mL bottle against a 6 cc dose is not a whole number of
  anything; tracking bottles alone cannot answer "what is on hand".
- `unit_cost` = landed cost ÷ `qty_units`. Freight and handling on the invoice
  allocate across lines by value, so unit cost is landed cost.
- `qty_remaining` — what is left of this layer
- `received_date`; `mfr_lot_number` and `expires_on` **optional**, typed only
  when somebody cares. FIFO needs neither.

`bottle_size` is **snapshotted on the line**, not read from `medications`.
Bottle sizes change; a layer bought at 500 mL must stay 500 mL after the
catalog says 1000.

FIFO order is `received_date`, then purchase line sequence, within a location.

### `med_txns` / `med_txn_layers`

Every movement, one row: `txn_date`, `txn_type`, `medication_id`,
`location_id`, `qty_units`, `crew_user_id`, `reason`, `ref_kind`/`ref_id`,
notes, `created_by`, `fiscal_year`.

**Five types, not ten:** `opening`, `purchase`, `checkout`, `usage`,
`adjustment`. Treatment and processing are both `usage`, told apart by
`ref_kind`. Waste, expiry, a count variance and a plain correction are all
`adjustment`, told apart by `reason` — one code path, four labels, instead of
four near-identical types that each need their own handling. A return is a
negative `checkout`.

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

- **Checkout** is a `checkout` txn carrying `crew_user_id`. **It does not move
  stock** — the bottle is still ranch inventory, just in somebody's hand. Four
  fields to enter: person, med, bottles, date.
- **Usage** is consumed per doctoring med line at approval — `dose_cc` units out
  of the ranch pool, FIFO, cost frozen onto `doctoring_event_meds.cost`.
  `doctoring_events.recorded_by_user_id` already says who gave it.
- **The count trues the pool up.** What the ranch should hold is purchases minus
  recorded doses; what it actually holds is the count, barn and trucks together.
  The difference is shrink.

`med_custody` (view) is the per-person sub-ledger: checked out − returned −
doses recorded by that person = outstanding. **That number is fair over a
month and unfair over a day** — a bottle checked out by one man and finished by
another shows up as one running high and the other low until it washes out. The
dollars still reconcile at the location level either way, because the count
does not care whose hand the bottle was in. Say that on the screen; a per-person
number nobody trusts is worse than none.

**Never block a doctoring entry on inventory.** If the stock is not there the
entry saves anyway, costs at the most recent layer's unit cost, and the
location goes negative with a flag on the on-hand screen. This is animal
health data and a bookkeeping gap is not a reason to lose it. The same rule the
offline queue follows: never a silent drop, never a hard stop on a field record.

### Processing — the buyer's draw

Meds for processing are picked up by the buyer at the supplier and used on our
cattle before they ship. So the pickup is a purchase received to that buyer's
location, and the processing of a receipt consumes from it. Nothing transfers.

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

## A medicine used before the app knows what it cost

Rare, but it happens: something gets picked up at the supplier and given before
anybody enters the invoice. Two things go wrong, and the second is the dangerous
one.

**1. The dose books at zero.** With no layer and no catalog price there is
nothing to price it from. The treatment still saves — that rule does not bend —
but it books at $0.00, and a zero looks like an answer in a way a blank does
not. So the transaction is marked `cost_provisional`, and the on-hand screen
says *"used but booked at $0 — no cost known"* rather than showing a tidy zero.

**2. The shelf reads high, and the next count calls it shrink.** This is the
one worth catching. Say 3 doses are given on the 12th and the invoice is entered
on the 20th, dated the 8th. `med_consume` already ran on the 12th, found no
layer, and recorded a shortfall. The layer now lands **full**. On-hand claims 10
when 7 are really there, the count comes up 3 short, and those 3 post as shrink.

They were not shrink. They were a treatment the ledger had not heard about yet.
Left alone, **every late invoice quietly inflates the one number this module
exists to produce.**

### `med_settle_uncovered(medication_id, location_id)`

Walks uncovered usage oldest first and lets it draw on any layer that was
genuinely on the shelf when the treatment happened — **received on or before the
usage date**. A bottle bought afterwards is left alone; it cannot have been in
the syringe. Whatever is still uncovered gets re-priced to the best cost now
known, so a zero booked in ignorance does not stay a zero.

It moves no stock that is really on the shelf: the shortfall rows point at no
layer, so converting them into real draws only spends what was already spent.
Afterwards the usage is backed by a real layer, which means a reversal restores
it properly too.

- Runs automatically right after a purchase posts, and says in the toast how
  many units it matched. That is the moment it matters.
- Also a **Settle uncovered usage** button on On hand, for anything entered out
  of order afterwards.
- If it settles nothing, the message says why: there is no purchase dated on or
  before the day the medication was given.

A **freetext** medication — one typed by name rather than picked from the
catalog — carries no `medication_id` and so never reaches inventory at all. That
is not a hole in the ledger so much as a hole in the record; it is worth
knowing, and it is why picking from the list matters.

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

## Getting the invoice in — Cowork or by hand

**The review grid is the screen. Cowork fills it, or you type into it.** Both
land in the same rows, tie against the same total, and post the same way — the
paste box is just a faster way to fill a grid that always accepts typing. Which
also means the module is never blocked on Cowork being handy: a two-line invoice
is quicker typed, and one arriving as a clean emailed PDF may not be worth
handing off at all.

Why not have the app do it: this is one static HTML file on GitHub Pages, no
build step, no server, four CDN libraries. Inside that, **pdf.js cannot read a
scan at all** — a scan is an image and there is no text in it to find — and
browser OCR (Tesseract, 2–4 MB of wasm) errs precisely on digits, which is the
entire content of an invoice. Reading a scanned invoice properly takes a model,
and the model is already in the room.

So for a scanned or photographed invoice: hand it to Cowork, it reads the scan
and matches the products and returns one tab-separated block; paste that into
the Purchases screen, check the grid, post. For anything short, click **+ Line**
and type it. The PDF attaches to the purchase either way through
`uploadAttachment()`, which already exists.

**The paste format is the contract**, so it is printed on the screen beside the
box — the Cowork prompt stays stable, and the app never guesses at a layout.
One header line, then one line per product:

```
Vendor           2026-09-04    INV-88213
Draxxin          2    496.31
Ultrachoice 8    4    189.87
Valcor           6    150.71
```

Name, bottles, unit price — the same three fields a typed line asks for. Bottle
size and the base-unit conversion come from `medications`; `mfr_lot_number` and
`expires_on` stay optional and are usually left blank.

**A pasted name that does not match a medication stops and asks** — with the
same picker a typed line uses, so an unmatched paste degrades into hand entry
rather than into an error. It never picks the closest row on its own — a med matched to the wrong catalog entry prices the
wrong layer, and that error is invisible from the moment it posts.

**Nothing posts straight from a parse.** Every pasted line lands in a review
grid showing quantity, unit cost and extended cost with a running total against
the invoice, and it cannot post until that total ties. A wrong unit cost does
not throw — it silently prices every future FIFO draw off that layer, and by the
time it surfaces it is frozen into treatment cost on a dozen lots. **This is the
one place the build stays deliberately un-simple.**

If the typing ever becomes the bottleneck, the next step is a Supabase Edge
Function that takes the PDF and returns the same block — same format, same grid,
no paste. That is real infrastructure (a function, a stored secret, a deploy path
this repo does not have yet), so it waits until volume asks for it.

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

### Redwing already carries inventory (John, 2026-08-27)

That changes the posture, and it is worth being explicit about it because two
sets of books over the same bottles is how both end up wrong.

**The full inventory runs here; Redwing is the cross-check.** Redwing stays the
general ledger and keeps its own inventory value for the financial statements,
but the working inventory — what is on the shelf, what came in, what got used on
which lot — lives in the office app, and the two get compared on a schedule
rather than one being slaved to the other.

That is the right split because Redwing knows dollars in and dollars out, and
what it cannot know is that 1.1 cc/100 lb of Draxxin went into lot 36-27 on a
Tuesday, that the crew is running at 82% of theoretical, or that Thigpen drew a
case and processed 441 head with it.

### Comparing the two — quantities first, then value

**A quantity difference and a value difference are different diagnoses and the
report must not blur them.**

- **Quantities disagree** → something is genuinely missing on one side. An
  invoice entered in one system and not the other, a usage never recorded, a
  count posted here and not there. Real, and someone has to go find it.
- **Quantities agree but values do not** → that is the costing method, and it is
  expected, not an error. If Redwing costs at average or standard and we cost at
  FIFO, the same bottles carry two different values *by construction*.

So the comparison shows both columns side by side and labels the second one for
what it is. A value gap presented as an exception sends somebody out to count
bottles that are all there.

**Phase 1 prints our valuation in Redwing's item order** — that is enough to
compare by eye or in a spreadsheet, and it is nearly free. A paste box that takes
Redwing's own export and renders the side-by-side is a small follow-on, and it
waits until the actual Redwing report is in hand tomorrow so it is built against
the real columns rather than a guess.

So, provisionally, until the reports land:

- **`med_roll_forward` carries the costing difference as its own line**, so it
  is never mistaken for shrink.
- **The report almost certainly does not post purchases.** If the vet-supply
  invoice already enters Redwing through AP, a purchase row set here books the
  same invoice twice. Usage allocation and inventory adjustment are what Redwing
  cannot derive on its own.
- **We still have to value inventory ourselves.** Not to compete with Redwing's
  balance sheet, but because FIFO layer cost is what phases 2 and 3 freeze into
  treatment and processing cost per lot. Redwing cannot supply that number at
  lot grain.
- **Which means the two valuations will differ, and that has to be expected
  rather than discovered.** If Redwing costs at average or standard and we cost
  at FIFO, the ending values differ *by construction*, not by error. My vote:
  **Redwing owns the balance-sheet number, this module owns the per-lot
  allocation, and `med_roll_forward` is the reconciliation between them** —
  built to show the costing-method difference as its own line rather than
  burying it in shrink. Shrink that is really a costing difference is a number
  that will send somebody out to count bottles that are all there.

**Add `redwing_item_code` to `medications`.** The sales accounting report prints
lot numbers as the app holds them because we refused to guess Redwing's mapping.
Here there is no guessing to do: Redwing has an item master, so the mapping gets
stored once and the report emits Redwing's own item codes.

### What settles the rest (arriving 2026-08-28)

John is sending the Redwing reports and the shape he wants for usage and
adjustments. Four things answer everything still open:

1. **The inventory valuation report** — reveals Redwing's costing method (FIFO,
   average or standard) and its item numbering. This is the one that decides how
   the reconciliation line is built.
2. **The item master / item list** — the mapping for `redwing_item_code`.
3. **A recent vet-supply invoice as Redwing received it** — confirms purchases
   already land through AP, and settles the purchases-row question outright.
4. **Whatever usage / adjustment entry gets made today** — the format this
   report has to match.

---

## The count sheet and the monthly reconcile

The count is the only thing in this design that produces a shrink number, so
it gets a real workflow rather than a form. Two halves: a sheet you carry into
the medicine room, and a screen you key it back into.

### The sheet

Printed from **On hand**, one line per medication, ordered by category and name
so you walk the shelf once. Two write-in columns, because that is how counting
actually goes:

```
Medication            Unit    Full bottles ____   Open bottle ____
Draxxin               500 mL  ________________    ____________ mL
Ultrachoice 8         250 ds  ________________    ____________ ds
```

**Full bottles and the open one are counted separately.** A 500 mL bottle
half used is 250 units of real inventory, and a sheet with one box forces the
counter to do arithmetic on a clipboard — which is where the error gets made.
The app does the multiplication.

**My vote: the printed sheet does NOT show the expected quantity by default.**
A number printed on the sheet is a number that gets copied down, and a count
that agrees with the system because the system was printed on it finds no
shrink at all — which is the entire point of counting. So: a **"show expected"
checkbox, defaulting OFF**, for when the sheet is being used to chase a known
discrepancy rather than to take a clean count. Expected **value** is on the
screen and on the variance report either way; it is the expected *quantity* that
biases the count.

Overrule this if you want the expected column printed — it is a checkbox either
way, and it is your count.

### Entering it

The entry screen mirrors the sheet exactly: same order, same two columns. Type
what was written, leave untouched meds blank (blank means "not counted", which
is not the same as zero — a blank must never post an adjustment writing the
stock to nothing).

Then, before anything posts:

| | |
|---|---|
| **Expected** | units the ledger says should be there |
| **Counted** | full bottles × bottle size + the open bottle |
| **Variance** | units, and dollars at FIFO cost |

**The variance is shown and has to be looked at before posting.** Posting writes
one `adjustment` txn per non-zero line, `reason = 'count'`, and those adjustments
are the month's shrink.

### What it covers

The count covers the **Ranch** location. A buyer's shelf is on his place and
cannot be counted from here — buyer balances reconcile through
`med_efficiency` against head processed instead, which is what that report is
for.

Cadence is monthly, and mandatory at 6/30 for the fiscal year close.

---

## Reports

All views `WITH (security_invoker = true)`, no exceptions.

Six views. Valuation is a total row on `med_on_hand` and exceptions are flags on
it, rather than views of their own.

| view | answers |
|---|---|
| `med_on_hand` | units, bottle equivalent, FIFO value, oldest layer, and flags: negative, unpriced, expired, stale |
| `med_activity` | the ledger, filterable by med, location, date, type |
| `med_roll_forward` | beginning + purchases + opening − used + adjustments + uncovered = ending, by month and by fiscal year. Ties by construction, and verified to tie to `med_on_hand`. |
| `med_efficiency` | theoretical vs consumed, units and dollars — grouped by crew member, or by buyer against head processed |
| `med_custody` | per crew member: checked out, doses recorded, outstanding |
| `med_buyer_reconciliation` | per buyer: drawn, expected from head processed, variance |

Dates use `public.ranch_today()`, never `CURRENT_DATE`. The database runs UTC
and the ranch does not; `lot_daily_head` already lost a day to this once.

---

## The office tab

New top-level **Inventory** tab, `data-perm="office"` — it is all dollars, so
crew never sees it. Sub-tabs:

1. **On hand** — one list, ranch and each buyer, with value and the flags
2. **Purchases** — attach the invoice PDF, paste from Cowork or type the lines,
   tie, post
3. **Checkouts** — person, med, bottles, date. Four fields.
4. **Counts** — print the count sheet, walk the room, key the two columns back
   in, look at the variance, post. Blank means not counted, never zero.
5. **Efficiency** — crew by person, buyers by name
6. **Reports** — the Redwing report, the roll-forward, and our valuation in
   Redwing item order for the monthly comparison; print landscape and PDF
   through the existing `sharePdfFile()` path

---

## Phases

### Phase 1 — the ledger (no effect on the books)

Target: **opening count 2026-09-01**, soft. If the build runs past it, the count
is still dated 9/1 and everything since is entered in date order behind it —
what cannot happen is a txn dated before the opening layers exist.

Note the first fiscal year of inventory is a partial one: FY 2027 runs
2026-07-01 to 2027-06-30, so its roll-forward opens on the 9/1 count rather than
on zero. The report should say so on its face, or the year looks short.

Tables, RLS and policies, RPCs, views, the Inventory tab. Purchases (Cowork paste or
hand entry), checkouts, the count sheet and the monthly reconcile, shrink,
on-hand value, the Redwing report, the valuation in Redwing item order, and both
efficiency reports.

`doctoring_event_meds.cost` and `lot_processing_costs` are **not touched**.
Inventory records usage in parallel and the two costings can be compared before
anything is trusted.

RPCs, all INVOKER with a pinned `search_path`:

- `med_consume(medication_id, location_id, qty_units, txn_type, reason, ref_kind, ref_id, txn_date)`
  → allocates FIFO, writes the txn and its layer rows, returns cost
- `med_reverse_txn(txn_id)` → restores exactly the layers named in `med_txn_layers`
- `med_post_count(count_id)` → variance → adjustment txns, all or nothing

Three, not four. There is no transfer RPC because there are no transfers.

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

- **Redwing's costing method**, from the valuation report — decides how the
  reconciliation line between our FIFO value and Redwing's is built.
- **Does the vet-supply invoice already reach Redwing through AP?** Near-certain
  now that Redwing carries inventory, but confirm before deciding the report
  emits no purchase rows.
- **Report cadence** — weekly or monthly. Deliberately deferred: the report is
  date-ranged, so this is a habit rather than a build decision.
