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

## Decisions from the design review (2026-08-29)

A question-by-question walk of the design tree. These supersede anything
earlier in this document that disagrees with them.

### Scope and catalog

1. **Everything in `medications` is inventory** — drugs, implants, and the three
   tag products — with a per-medication **`track_inventory`** flag to switch off
   anything not worth counting. The flag cannot be retrofitted: once counts
   exist, changing what is in scope changes what past counts meant.
2. **A medication with no container size is flagged, not stocked.** Synovex
   Primer, Protivity and Dexamethasone have no `bottle_size`. They show on the
   inventory screens saying so, a purchase line for them will not post, and they
   are left off the printed count sheet until fixed. Doctoring is never blocked:
   `dose_cc` is already in base units, so doses still record — they just show as
   uncovered until the medication is set up and stocked.

### The count

3. **A posted count hard-locks its location on and before the count date.** A
   purchase or adjustment dated into a locked period is refused. **Un-posting is
   owner-only** and reverses every adjustment the count made. Without this a
   late invoice silently rewrites a month whose shrink is already booked.
4. **A count cannot post while doctoring entries dated on or before it are
   unapproved.** The screen lists how many and from which days. This is the
   trap that makes the whole thing worth building: count the shelf on the 31st
   with the 28th's treatments still in Approvals, and the count books those
   doses as shrink — then the approval posts them again. Two hundred units
   recorded where a hundred moved, and **it does not wash out next month.**
   The rhythm is: enter the count on the 31st as a draft, clear Approvals on
   the 1st, post it dated the 31st.
5. **The sheet has two column-pairs — barn and crew — that add to one total.**
   Still one Ranch pool and no transfers; this is only how the count is
   gathered, and it tells you whether shrink is sitting in the barn or in the
   trucks, which is a stock problem versus a handling problem. **Open bottles
   are recorded in quarters** (crew writes ½, not 250) because that is the
   precision a man in a truck can honestly give.

### Where the money goes

6. **Redwing changes to match lot usage.** It allocated meds by head-days, like
   mineral, only because nothing could say which lot got the drug. That is what
   this replaces — the report is not a new posting, it retires an existing
   allocation.
7. **Shrink is allocated to lots, per medication, pro-rata by units of that
   medication used** (largest-remainder, so the parts sum exactly — the method
   the shipment allocation already uses). Draxxin shrink is split only across
   lots that actually got Draxxin. Every dollar of med spend therefore lands on
   cattle and closeout ties to the P&L. **Consequence:** a lot that shipped in
   August receives its share when the August count posts in early September —
   its cost moves once, then never again, because a posted count is locked.
8. **A buyer's leftover is handled as a count on his location.** He reports what
   is left at month end or when a lot finishes processing; the variance posts
   as an adjustment exactly like barn shrink, allocated across the lots he
   processed since his last count, pro-rata by **expected** usage per
   medication. Nothing about buyers is special — same sheet, same lock, same
   rule — and his balance is always a number a human stated rather than one
   that compounds unwatched.
9. **Closeout grows an "Animal health" line that opens into Processing,
   Treatment and Shrink.** The headline is total dollars ÷ **head in** — head in
   never moves, so lots stay comparable and the figure cannot flatter itself as
   cattle die or ship. The drill-down keeps each component's existing
   convention (processing per head in, treatment per live head), so no number
   anyone already reads changes meaning; it just gains a parent.
10. **"Shrink" keeps its name.** It is the word cattle accounting uses, and
    naming it is what makes it something you can work to control. The app now
    carries two shrinks — pay-weight on Sales, medicine on Inventory — on
    different screens, which is disambiguation enough.

### Custody

11. **The crew is pooled for now; no per-person number yet.** Every one of the
    1,095 doctoring events is recorded by John, because the cowboys do not have
    logins yet — `recorded_by_user_id` currently means *who typed it in*, not
    *who gave the shot*. A per-person custody figure built on that would be
    nonsense. Checkouts still record a name for traceability.
    **Superseded in part by decision 26** — logins were assumed to be the
    trigger that would make a per-person number valid. They are not.

### Timing

12. **Lite in September, books switch 1 October.** Opening count in the first
    week of September and `usage_from` set so the ledger runs for real — but
    Redwing keeps its head-day allocation for September and closeout does not
    change. The 9/30 count is then a dress rehearsal that can be held against
    Redwing's September allocation, and that comparison is the only way to earn
    trust in the number before it drives anything. Going live in October with
    no month of operation behind it would make the first count that matters
    also the first count ever taken.

### Cost boundaries and cutover

13. **Expired product is overhead, and is NOT allocated to lots.** Waste (a
    dropped bottle) goes with count shrink, because both are handling losses on
    cattle being worked. Expiry is an *ordering* problem — nobody's cattle
    caused a jug to reach its date — and it is lumpy enough that one jug would
    swamp a month. Keeping them apart keeps both signals: shrink says the crew,
    expiry says the buying.
14. **The pre-May-2026 receipts are a data gap, and we are NOT backfilling.**
    Confirmed with John. Every receipt before 2026-04-27 has no receiving
    protocol and no protocol in the system predates that date, so a backfill
    would mean reconstructing one from old vet invoices. Five lots therefore
    show $0.00 processing — 31-26 (1,766 hd, closed), 37X, 47-26, 37X-1, 37X-F,
    about 2,900 head and roughly $58,000 at the ~$20/hd the newer lots run.
    **That cost is picked up by the cost ledger instead**, and most of those
    lots ship soon. The only change is cosmetic and worth doing: show
    *"protocol not recorded"* rather than a bare `$0.00`, which reads as a real
    number.
15. **Medicine leaves the cost allocation on 1 October — split by cost DATE,
    not by lot.** Vet invoices before the cutover stay head-day allocated;
    from the cutover they are inventory purchases reaching lots as actual
    usage. **Meds stay in the cost allocation for September** (John: "leave in
    next month"). A lot running across the boundary gets allocated meds early
    and actual usage after — correct, and unavoidable however it is cut.
    Non-med lines on a vet invoice (fees, supplies) stay in the ledger
    throughout.
16. **History is held, not rewritten.** John: *"Program will hold the
    allocations from previous months which have said cost. Will just start
    allocating that month's actual usage going forward. Should be as close to
    complete as possible."* Prior months keep the allocation they were closed
    with; the switch is forward-only. That is exactly what the phase 3 snapshot
    does — freeze what the books already said, derive nothing retroactively.
    **"As complete as possible" is read as: treatment and processing both
    switch on 1 October rather than staggering them.**

    **The gate on that stays non-negotiable.** Before processing flips, the
    snapshot must show every lot's processing total unchanged to the cent. If a
    single lot moves, processing does not flip that day and treatment goes
    alone. Completeness is the goal; a silently changed closed lot is not a
    price worth paying for it.
17. **A processing draw comes off the buyer's shelf when his source key matches
    the lot's Source, and off Ranch stock otherwise.** Covers both the buyer
    processing before delivery and a load worked at the ranch, with nobody
    choosing per receipt. A short buyer shelf records a shortfall and flags it
    rather than failing, same as everywhere else.

### Opening balances

18. **The opening count is valued at Redwing's carrying value, item by item.**
    Your physical count sets the QUANTITY; Redwing's unit cost sets the PRICE.
    Day one then ties to the penny by construction, so there is never a founding
    difference nobody can explain, and everything that diverges afterwards is a
    real transaction you can point at. FIFO runs forward from there and takes
    over as the opening stock is used up.
    **Prerequisite:** `medications.redwing_item_code` has to be mapped before
    the opening count — you cannot take a per-item value without matching the
    items. It also forces the quantity comparison on day one, when it is
    cheapest to fix.
19. **Buyer opening balances are established at the OCTOBER cutover, not in
    September.** Nothing consumes a buyer's stock until processing starts
    drawing on 1 October, so a 9/1 figure would sit untouched for a month and
    end up overstated by whatever he actually used. Ring each buyer as part of
    the switch, enter what he is holding as an opening count on his location,
    priced at our last invoice for those items. His balance starts true on the
    day it first matters, and September is free for the phone calls.
20. **September's shrink is reported, not allocated.** The 9/30 count posts its
    adjustments so inventory is right going into October, but the shrink is not
    pushed onto lots and not sent to Redwing — September meds already reach lots
    through the head-day allocation, and allocating as well would count them
    twice. The figure exists to be looked at and held against Redwing's
    September number, which is the entire point of the rehearsal month.
    **Allocation to lots begins with the October count**, posted in early
    November, on the first month meds are out of the cost ledger.

### When the crew doesn't turn a number in

21. **Carry the crew's last reported figure forward and flag the count as
    estimated.** John's call over blocking. The month always closes and no fake
    shrink is booked from stock that is sitting in a truck. The cost is that a
    stale figure looks like a real one, so: every screen carries a **"crew last
    actually counted"** date, and when a real crew count finally lands after
    estimated months the catch-up variance is booked in the month it is found —
    the period lock forbids reopening the closed ones — **labelled with the
    period it covers**, so a month does not appear to have lost a case.

22. **PARKED — "a new bottle means the old one is empty."** John's idea, and a
    good one: when a cowboy draws another bottle of the same medication, treat
    his previous one as finished. It stops crew holdings rolling up and gives a
    continuous signal instead of a monthly one. It splits in two, though:
    - **As an estimate** it is strictly better than a carried figure — crew
      holdings become the sum of the latest checkout per person per medication,
      refreshed every time anyone draws. Books untouched.
    - **As a shrink trigger** it needs to know which doses came out of *that*
      bottle, which needs per-person dose attribution — so it waits for crew
      logins. Pooled across the whole crew it degenerates into "every
      checked-out bottle is consumed", which is bottle-level expensing one
      bottle late: the head-day allocation wearing a different hat.

    **Revisit once there is real running experience and the cowboys have
    logins.** Until then, decision 21 stands.

### The go/no-go

23. **No written threshold — judged on the numbers in early October** (John's
    call over pre-agreed gates). The four things worth looking at are still
    worth looking at: quantities against Redwing item by item, the roll-forward
    tying to on-hand (asserted automatically by the tests), shrink as a share of
    usage, and total September med dollars against the head-day allocation.
24. **The app computes BOTH sides of the September comparison.** One report,
    per lot: actual FIFO usage against a head-day allocation of the *same total
    spend*, with the difference in dollars and $/hd. Because both sides come off
    one total, every gap on the page is purely distribution — which lot was
    really carrying the drug — and that is the thing being judged. Nothing has
    to be extracted from Redwing, and it is ready the day September closes.

    **The expected signature: the totals should land close and the per-lot split
    should differ noticeably.** The difference is the product. If the *totals*
    disagree, something is wrong and it wants finding before the switch, not
    after.

### Crew members are names, not accounts

25. **A crew member is a row on a list; an app login is optional** (John,
    2026-08-29). Some hands are regulars who will get field-app accounts; some
    come occasionally and should never see field-app information at all. Both
    need to be checked out to, and the office or the head crew leader enters on
    their behalf.

    So `med_txns` points at a **`med_crew_members`** row — name, active, and a
    *nullable* link to a `user_profiles` account — rather than at a user id.
    When a member has an account and crew logins arrive, per-person dose
    attribution works for him; for the hands without one it never will, and the
    design should not pretend otherwise. This also settles the picker: it was
    reading `admin_list_users`, which today returns only John and Lauren.

    **The crew bottle count will be attempted near month end** rather than
    relying on the carried estimate, so decision 21 is the fallback and not the
    plan.

### Why per-person never works, and what replaces it

26. **Crew-level is the honest ceiling. `med_custody` is deleted, not hidden.**
    John, 2026-08-29: two men work together, use meds out of *one* man's box,
    and the *other* documents the treatment.

    That breaks per-person reconciliation permanently, and logins do not fix
    it. Logins fix *who typed it*; they do nothing about *whose box it came
    out of*. If A carries the box and B writes the treatments up, A's checkouts
    drain against B's records — A looks like he is losing drug and B looks like
    he is conjuring it. Where that is the habitual pairing it is a **systematic
    bias, not noise**, so it does not wash out over a longer window either.

    **The pool is unaffected**, because it does not care whose hand the bottle
    was in — checkouts in, doses out, the count trues the whole thing up. Only
    the per-person split breaks.

    The single thing that would fix it is recording *whose meds* at the moment
    of treatment, and that is not worth a field-app change, an extra tap on
    every doctoring entry, and a default that is wrong precisely when two men
    are working together.

    So: **`med_custody` is dropped** — it computes a comparison now known to be
    invalid, and no future event makes it correct. A plain **checkout log**
    replaces it, answering "who has bottles" and nothing more. Shrink is a crew
    number. The plan no longer promises a per-person one.

### Still open

- **The Redwing posting grain** — one row per lot per period, or split by
  medication or category. Waiting on the Redwing reports.
- **Whether `medications.cost_per_head` is retired** once every in-scope
  medication carries a container size and a unit cost. Two meds currently carry
  both it and a unit cost (Ivomec Long Range, Lot Tag), where it is dead weight
  today and a landmine if a dose is ever null.

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

## Trying it out without touching anything

The whole module can be run for real, in the live app, against the live
database, without a single row of the books moving. Three facts make that true
rather than hopeful.

**1. It writes to nothing that exists.** Every write in the Inventory tab goes
to a `med_*` table. `medications`, `doctoring_events`, `lots`, `invoices`,
`delivery_receipts` and `protocol_meds` are read-only to it. This is checkable,
not a promise: grep the module for `.insert(`, `.update(`, `.delete(`.

**2. Doctoring does not draw stock until you say so.**
`med_stock_locations.usage_from` is the go-live switch. Until it is set, the
doctoring save path records nothing against inventory, so treatments carry on
exactly as they do today while the tables sit there empty. Set it on **Inventory
→ Setup**, and it takes effect for entries dated on or after that day.

**3. A rehearsal happens in a test location and erases without a trace.** Make a
location with `is_test`, post practice purchases to it, count it, print sheets,
run every report — all through **the same code paths as the real thing**, which
is the only kind of rehearsal worth doing. Then erase it in one click.
`med_purge_location()` **refuses outright on a location not marked as a test**;
without that check it is a delete statement pointed at the inventory and one
wrong id takes the real books with it.

### The order

1. **Apply the migration.** Safe before any decision is made: it creates the
   `med_*` tables, seeds one *Ranch* location with `usage_from` unset, and adds
   one nullable column (`medications.redwing_item_code`) to a live table. That
   column is the only change to anything that already existed.
2. **Deploy `index.html`.** The tab appears for office and owner. It reads live
   `medications` so the pickers are real, and writes only to its own tables.
3. **Rehearse.** Setup → + Location → answer *yes* to "is this a test
   location". Post a purchase against it, take a count on it, break the tie-out
   on purpose and watch it refuse, print the blind sheet, run the roll-forward.
4. **Erase it.** Setup → Erase & delete. Verified to leave zero rows and zero
   orphaned allocations.
5. **Go live.** Add the real buyer locations, take the opening count on *Ranch*,
   then Setup → Go live and set the date to the count date.

Nothing in steps 1–4 can move a lot, a receipt, a treatment or a dollar of
existing cost, and step 5 is a single date on a single row — reversible with
*Turn back off*, which stops new usage without removing anything already
recorded.

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

---

## Rebuilt on main, 2026-10-01

Everything above still stands as the design. What changed is the ground it was
built on.

The work described here was done in late August on branch
`claude/medicine-inventory-fifo-03tqg9`, cut from `60a6a2d`, and was never
merged. Main moved a long way in the meantime, and three of the things it
changed are things this module had to be rebuilt against rather than merged
into:

1. **`CLAUDE.md` was split into `docs/`** (2026-09-27). The rules this module
   has to satisfy now live in `docs/conventions.md` and `docs/database.md`.
2. **The `accountant` role landed** (2026-09-01) and with it
   `can_read_operational()` / `can_read_books()`. The August migration's
   SELECT policies named `owner` and `office` directly, so an accountant
   would have been unable to read one row of this module. The rebuilt
   migration goes through `can_read_books()`, which also means the next
   read-only role is one line in one function rather than another eight-table
   migration.
3. **Feed inventory wave 1 shipped the Inventory tab** with a material chip
   (`docs/inventory-flow-design.md`), built explicitly so meds would mount
   under it: *"Adding meds — or fuel, or parts — is a chip and a
   `data-material` attribute, not another screen."* The August build had its
   own `navInventory` tab and its own `inventorySubtabs` row. The screens are
   the same screens; the mounting is the chip.

So the ledger is now `docs/sql/2026-10-01_med_inventory.sql` and the August
file is superseded. The August screens are re-applied to today's `index.html`
under the chip, with four changes:

- `showInventoryTab()` stays the shared router; the med half became
  `showMedInventoryTab()`, which is called when the chip is on Meds.
- `loadInvPurchases` / `invPurchasesView` already existed on the spine side,
  so the med pair is `loadInvMedPurchases` / `invMedPurchasesView`.
- Write controls carry `data-write`, which did not exist in August. It is its
  own attribute, not `data-perm="write"` — half these buttons already carry a
  `data-perm`, and an element holds only one.
- Needs Attention, Orders and Invoices are shared spine screens and meds use
  them unchanged. For meds, **Purchases and Receipts are one screen**: the vet
  invoice *is* the receipt and its lines *are* the FIFO layers, so there is no
  second delivery ticket to reconcile the way a feed load has.

### Two things the rebuild found

**The roll-forward identity did not hold for a shorted adjustment.**
`med_roll_forward` netted the uncovered part out of `adjustment_units` while
`uncovered_units` added it back, so a waste entry made against an empty shelf
had its units removed twice and
`beginning + purchases + opening − used + adjustments + uncovered = ending`
stopped holding for exactly those rows. `adjustment_units` and
`adjustment_value` are now gross and signed, and uncovered is taken out once,
for every transaction type at once. Covered by T24 and T25 in
`docs/sql/tests/`.

**Crew entering a treatment in the office app cannot reach the ledger.**
`med_consume` is INVOKER and every policy here goes through
`can_read_books()`, which excludes crew by design — a FIFO draw reads layer
costs. So a treatment typed by a crew member in the office app saves
correctly and never reaches inventory, and the next count reads those doses
as shrink. The field app is unaffected: a field entry becomes a treatment
when the office approves it, and the office draws the stock.

This is latent today — every doctoring event on the books was entered by the
owner, and crew logins are not set up — so it is **surfaced rather than
worked around**: the treatment is kept, the person is told plainly that the
dose was not drawn, and the office records it. Closing it properly means
making `med_consume` SECURITY DEFINER and withholding the cost it returns
from anyone who cannot read books. That is a change to the role model, so it
is John's call and it is in `docs/OPEN-ITEMS.md`.

---

## The opening count, 2026-10-01

Source: the Redwing **Medicine RM Inventory 1/1/1900 to 9/30/2026**, account
117500 Animal Health RM. A ScanSnap scan with no text layer, so the figures
were read off the image; both of the report's own control totals — 731.00
units and $21,896.25 — were reproduced from that reading before anything was
entered.

Two properties of that report shape everything downstream:

- **The `$ / unit` column is blank on every line.** Unit cost is derived as
  amount ÷ quantity.
- **The quantity column is not one unit of measure.** Enroflox 21 at $183.57
  is bottles; Synovex C 110 at $1.10 is doses. This ledger multiplies by
  bottle size, so reading one for the other puts the opening balance out by a
  factor of a hundred. Every count line records which it took.

### Two cost gaps, and they are not the same problem

**Enroflox is a genuine disagreement about price.** Redwing's derived
$0.367130/mL against this catalog's $0.264360 — plus 38.9%, $1,079.09 across
the 21 bottles on hand, $3.18 a head on a 31 mL dose. Both figures are
internally consistent; they are simply not the same number. John's answer on
2026-10-01: **a rebate we might get later.** So Redwing's figure is what the
cash went out at and is the right FIFO cost today. What to do when a rebate
actually lands is `docs/OPEN-ITEMS.md` item 0b.

**Excede is Redwing disagreeing with itself,** and working out *why* took
three passes. It carried the drug on two lines: 100 mL × 24 at $2.138917/mL,
and 250 mL × 1 at $10.386840/mL — 4.86× the first. $2,596.71 ÷ 5 = $519.34 a
bottle, within 0.3% of this catalog's $517.78, so the line read like **five
bottles of money booked against a quantity of one**.

The arithmetic was right and the first explanation for it was wrong. It was
not a case price keyed against a single unit at receiving; it was **product
charged out and mis-posted**, left sitting in inventory at the wrong value.
John had it corrected in Redwing the same day, and corrected the line reads
**1 bottle at $519.35** — which is what "$519.34 a bottle" had been pointing
at all along.

So Redwing's Excede is $5,133.40 (24 × 100 mL) + $519.35 (1 × 250 mL) =
**$5,652.75**, and **$2,077.36** came out of inventory. The shelf holds both
containers — 1 × 250 mL and 24 × 100 mL, 2,650 mL, confirmed by John — valued
at $2.133113/mL, which back-multiplies to $5,652.75 exactly.

This is the finding John called the reason for the whole module.

The worked memo and the medicine-room worksheet are in `docs/worksheets/`.

### Where it landed, end of 2026-10-01

The bridge closes in **both** directions, which is the test that the
reconciliation is complete rather than merely plausible:

| | |
|---|---|
| Redwing at 9/30/2026 | $21,896.25 |
| less Excede, re-allocated in Redwing on 10/1 — *already done* | $2,077.36 |
| less Macrosyn 250 mL, from the July close — *Jayci and Brenda* | $373.15 |
| **plus medicine in the crew trucks, back into inventory** | **$2,419.56** |
| less expired product written off, net | $1,783.66 |
| &nbsp;&nbsp;&nbsp;One Grass $1,804.00 + Synovex S $165.00 + Synovex C $121.00 | $2,090.00 |
| &nbsp;&nbsp;&nbsp;less the $306.34 moved to Multi Min rather than written off | $306.34 |
| **Redwing after all of it** | **$20,081.64** |
| **The count — barn and trucks — valued** | **$20,081.64** |

Ten lines carry stock, and none of the 21 is left uncounted. Every stocked
line reconciles its four gathering boxes — barn full, barn open, crew full, crew open — against `counted_units`,
and that assertion is in the migration's verify block because it caught a real
error: the Excede crew boxes once implied 312.5 mL against a counted 2,775.

**The account goes up, not down.** $2,419.56 of crew stock coming in against
$1,783.66 of expired product going out is a net of **+$635.90**. The trucks
are holding more than the shelf is throwing away.

### Counting what the crew carries, rather than waiting

John's question on 2026-10-01: *"The cowboys have inventory in their trucks and
saddle bags as of today. Do we ignore for now and start inventorying at 10/31?
This med was charged out last month to cattle but not used yet. Will fix itself
over the month but throws first month off?"*

It does fix itself over a month, and it does throw the first month off, and
those are not the same size of problem. Ignoring it means the opening count
understates stock by whatever is in the trucks, and October then shows a
windfall when that product gets used against nothing. John chose to count it.

Four men reported, in two messages, in bottles and fractions rather than
millilitres — which is the right precision to ask a man in a truck for, and is
why `med_count_lines` stores `crew_open` as a **fraction of a bottle** and does
the multiplication itself. $2,419.56 in four drugs:

| | in the trucks | |
|---|---|---|
| Excede | 475 mL | $1,013.23 |
| Resflor | 875 mL | $726.92 |
| Enroflox | 1,250 mL | $458.91 |
| Draxxin KP | 125 mL | $220.50 |

All four were charged out in September and are still unused, so **Redwing is
understated by them** and they go back in at the October close.

**The fourth one was booked to the wrong drug first.** It was reported as
Macrosyn and valued at $195.47; John corrected it to Draxxin KP, 125 mL at
$220.50. The second-order effect is the one that matters: with no Macrosyn
anywhere on the place, **all** $373.15 Redwing carries against no quantity
from the July close is the posting error, not $177.68 of it. Jayci and Brenda
are the accountants, so that entry is theirs.

**Three of the crew's phrasings carried more than one meaning, and all three
were put back to John rather than guessed at.** Two were confirmed as read.
The third — Excede's truck bottles, taken as 100 mL because that is what the
shelf is mostly made of — was wrong: the actual is four containers, 475 mL
rather than 187.5 mL, **$613.27** more. It was the reading flagged as the
weakest of the three, and the one that moved. The rule for the next count is
to ask for the container size with the fraction, every time.

**Three places Redwing was understated**, which nobody was looking for — every
difference the exercise was designed to catch was expected to run the other
way:

- **Protivity**: eight 10-dose boxes on the shelf, Redwing zero. Its count
  line was corrected twice and the pair is worth keeping. It first said a
  counted zero copied from Redwing — a false statement about 80 real doses —
  so it went back to NOT COUNTED while a price was looked for. Then John: the
  product was charged to a lot in a past period and goes to processing at no
  cost to burn up. So it is **zero by decision** now, and that is the true
  statement: the doses exist, their cost does not. Same number, opposite
  meaning, and only the second one is honest.
- **Multi Min**: four bottles against Redwing's three, $306.34.
- **Ivomec Long Range**: two bottles Redwing never carried at all. Going back
  to the vendor, so neither side holds them — but they arrived and were never
  booked.

With the Excede mis-posting, that is four things in one day where product moved
and the books did not follow. All four point at receiving rather than at
inventory.

### What the opening count still waits on

It is deliberately still a **draft**: posting creates the opening FIFO layers
and locks the period. What it waits on is Jake Taylor's count, and seven
medications whose `bottle_size` is still NULL
because the Redwing report gives a container count and a dollar amount and
never says how big the container is. A guess there would misprice every future
dose of that drug silently, so they stay flagged **needs a container size**
until somebody reads a label. All seven count zero today, so none of them
blocks the post. `docs/OPEN-ITEMS.md` item 0c has the detail.

Jake Taylor's processing medicine is counted the same day and is in no figure
above. His **buyer location now exists** — `kind = 'buyer'`, `source_key =
'Jake Taylor'` matching the five lots that carry it, `usage_from` NULL so
nothing accrues until his count posts.

John also asked for **three stock locations** — Medicine Room, Cowboys, Jake
Taylor — against a module built deliberately on one ranch pool with custody
tracked per person. Jake Taylor fits the design; the room/truck split does
not, and inserting a second `kind='ranch'` row without fixing
`invLedgerReady()` first would draw doses off an arbitrary shelf, silently.
**Decided 2026-10-01: Jake Taylor now, the real split in wave 2.** Item 0d has
the finding, the two defects and what is left to do.

### Two ways to fill a count line

Added 2026-10-02, on Jake Taylor's count. The grid was built for a man holding
a part bottle: four boxes, open bottles as a **fraction** in quarters, capped
at three quarters, because that is the precision an eyeball estimate honestly
has. Jake's sheet came in thirds, eighths and exact doses — 1 ⅔ of a 500,
1 ⅛ of a 50, **90 doses** off an implant strip. Six of his nine lines could
not be typed at all.

Rounding them to quarters was the alternative and it is worse than it looks:

| | as written | to quarters |
|---|---|---|
| the count | $2,668.56 | $2,712.55 |

**1.6% high, and four of the five rounded lines round up** — not random, since
a man writing ⅔ is reporting less than the ¾ above it. It also puts our books
deliberately at odds with the sheet he signed.

So a line is now filled **one of two ways**:

- **the four boxes**, for an estimate, unchanged;
- **Counted units**, for an exact figure, typed straight in.

Typing in one blanks the other, so the two can never sit there disagreeing
while somebody guesses which posted. The grid shows which way each line was
filled, because a reader next month should know whether 833.3 was measured or
guessed at.

**No schema change was needed** — the shape already said it. A line with boxes
has boxes; a line with a `counted_units` and no boxes was typed. The loader
reads that back.

The quarter assertion in `2026-10-01l` still holds: a typed line has no boxes,
so its `coalesce(barn_open,0)` is zero, which is a quarter and under the cap.

### The day's corrections, in order

Each is its own file in `docs/sql/`, each with its own verify block, because
the opening balance of a real set of books should show its working:

| file | what it did |
|---|---|
| `2026-10-01_med_opening_count.sql` | the first pass off the scanned report |
| `2026-10-01c_..._excede_macrosyn.sql` | Excede priced off Redwing's 100 mL line, Macrosyn counted empty |
| `2026-10-01d_..._container_sizes_and_count.sql` | container sizes off the medicine-room sheet, seven more lines |
| `2026-10-01e_..._final_lines.sql` | the last two sizes, Protivity corrected off a false zero |
| `2026-10-01f_..._excede_corrected_synovexc_expired.sql` | Synovex C expired; the Excede half of this file was wrong |
| `2026-10-01g_med_excede_final.sql` | Excede is 2,650 mL — 1 × 250 mL and 24 × 100 mL |
| `2026-10-01h_med_crew_held_stock.sql` | what the crew carries, first pass |
| `2026-10-01i_med_crew_actuals.sql` | the crew's actual counts, $2,394.53 |
| `2026-10-01j_med_jake_taylor_location.sql` | Jake Taylor's buyer shelf; Resflor confirmed |
| `2026-10-01k_med_draxxin_kp_truck_and_protivity.sql` | the truck bottle is Draxxin KP; Protivity written off |
| `2026-10-01l_med_excede_bottle_size_100.sql` | Excede on a 100 mL bottle so the count screen can take it |
| `2026-10-01m_med_checkout_bottle_size.sql` | a checkout records the size of bottle that left the room |
| `2026-10-01n_med_go_live.sql` | both counts posted, usage_from set, today's doses drawn |
| `2026-10-02_med_processing_draw.sql` | processing draws off the shelf; a count will not post ahead of a weight |
| `2026-10-02b_med_count_delete_guard.sql` | a posted count cannot be deleted; drafts can |
| `2026-10-02c_med_estimated_weight.sql` | an office estimate doses per-cwt meds until the first invoice |
