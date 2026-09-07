# The feed pen — design decisions

Decisions taken 2026-09-07 with John. The feed pen holds cripples, chronics and
anything else with little value left. Cattle **leave their lot at a $0 basis,
leaving every dollar of cost behind**, accrue feed and a little medicine in the
pen, and are then sold, butchered, die, or simply disappear.

Each decision records what was decided **and why the alternative lost**, because
the reason is the part that stops it being re-litigated in six months.

---

## The problem

Three things the app cannot do at all:

- **Move a chronic out of its lot without moving its cost.** `lot_transfers`
  moves cattle **at cost** by design — that is decision 2 of
  `docs/lot-transfers-design.md`, and it is right for a fold-in or a sort. It is
  wrong here. A cripple carries $900 of purchase and carry that it will never
  pay back, and shipping that basis into a pen makes the pen look like a
  disaster and the lot look better than it is.
- **Keep the pen's own economics.** The pen buys feed and a little medicine and
  takes in salvage checks. Nothing today can hold that.
- **Dispose of an animal any way other than sold or died.** Butchered and
  simply-gone are real outcomes and both are currently unrecordable.

And behind all three: **what did the feed pen cattle off lot 60X actually cost
us?** That number does not exist anywhere today.

---

## 1. The feed pen is a LOT

A lot flagged `lots.is_feed_pen`, not a new kind of object.

Everything the pen needs is head math, feed allocation and doctoring, and the
app already has one careful implementation of each — keyed on `lot_id`:

- `lot_status` / `lot_daily_head` give head on hand and head-days.
- `lot_feed_daily` spreads a feed usage over head-days with no new costing path.
- `doctoring_events.lot_id` already carries medicine with its cost frozen.
- `lot_pasture_assignments` already says which pen they are standing in.

**Rejected: a cost center.** `cost_centers` (2026-09-01) exists for feed that
leaves inventory for something that is not a lot — the cowherd, the bulls, the
horses. It is deliberately the *absence* of a lot: `lot_feed_daily` and
`feed_cost_unallocated` both read `destination_type = 'lot'` only, so a cost
centre draws its FIFO layer and contributes to no lot's cost of gain. That is
exactly wrong for the pen, which has head, head-days, deaths and sales.

**Rejected: its own animal table.** A second head-math implementation and a
second feed-costing path, both of which would drift from the first. The app has
already been bitten by exactly this shape twice — two head-day implementations
that disagree by 29%, and two `renderDoctoringTable` declarations in one scope.

## 2. Cattle enter at a $0 basis; the source lot keeps every dollar

The existing `record_lot_transfer` path, with a new `kind = 'feed_pen'` and
`basis_per_head = 0`.

- **Rejected: at cost**, the rule for every other transfer. It hands the pen a
  $900 animal and flatters the lot that bred the problem. The whole point of the
  pen is that the loss is already realized on the lot that took the cattle in.
- **Rejected: a new transfer mechanism.** The pasture sync, the date floor, the
  fiscal-year capture, the optional tags and the reversal are all built, tested
  and already correct. A feed pen move is a transfer with a different number in
  one column.

**Schema consequence:** `lot_transfers.basis_per_head` and `basis_total` carry
`CHECK (> 0)`. Both relax to `>= 0`. They were written when at-cost was the only
basis, and a zero basis was then genuinely a bug.

**Consequence accepted, and it is the point:** the source lot's cost per
surviving head goes UP when a chronic leaves, because the same dollars now
divide over fewer head. That is an honest read — the money was spent on cattle
that will not pay it back.

## 3. One pen per fiscal year

`FEEDPEN-26`, `FEEDPEN-27` — one open pen lot per fiscal year, unique by a
partial index. John's call.

- **Rejected: one perpetual pen.** It never closes, so its net never lands
  anywhere, and `lots.fiscal_year` is `NOT NULL` and derived from arrival — a
  perpetual pen would carry one year's label forever while spending four years'
  money.

Cattle still standing on June 30 roll into the next year's pen — see decision 8.

## 4. The pen keeps its own books: salvage counts against pen cost

John: *"Feed pen becomes its own lot sales count against feed pen cost."*

Pen revenue (salvage sales) less pen feed less pen medicine is the pen's net.
It is a small salvage operation and it is measured as one.

- **Rejected: salvage credited back to the source lot.** The reason it loses is
  decision 5's reason: John: *"the source lot might be closed by time feed pen
  calf is cleaned up."* A chronic can sit in the pen for months. Crediting a
  closed lot and a prior fiscal year means reopening books that are finished —
  the same failure mode as editing a drug price, which silently rewrites closed
  lots through the live processing-cost views.
- **Rejected: the pen as a pure conduit**, pushing both cost and revenue back to
  source lots. Same closed-lot problem, and it leaves nothing to manage.

## 5. Cost by source lot is TRACKED, never booked back

This is the number John asked for: *"keep count of cost of feed pen cattle at
date removed associated with the lot they left."*

**At every removal the pen cost that head accrued is frozen and tagged with the
lot it came from.** That frozen figure is reporting — it is on the feed pen
screen and its report, by source lot and by fiscal year. **It does not post to
the source lot's closeout.**

- **Rejected: a closeout line on the source lot.** The source lot is very often
  closed by then, and a booked charge would reopen it. Also: the lot has already
  taken the whole loss on that animal at decision 2, so charging it the pen's
  feed on top double-charges the same head.

The two are not the same claim. The lot's books say *these cattle cost us
everything they cost and returned nothing*. The tracked figure answers a
different question — *what are we spending to salvage them, and off which lots
are they coming* — which is a management question, not an accounting entry.

## 6. Four ways out of the pen: sold, butchered, died, missing

`missing` is John's *other disappearance* — no carcass, no check, no
explanation. It exists because the alternative is booking a death that nobody
saw, which corrupts the one number the health reports are built on.

Each writes the head-math artifact that outcome actually is:

| removal | head math | dollars |
|---|---|---|
| sold | a `sales` row on the pen lot | proceeds, in the pen |
| butchered | negative `adjustment` event, `cause = 'butchered'` | none (decision 7) |
| died | `record_death_with_pasture` — the existing RPC | none |
| missing | negative `adjustment` event, `cause = 'missing'` | none |

- **Rejected: new `lot_events.event_type` values** for butchered and missing.
  That means widening a CHECK and then teaching `lot_status` and
  `lot_daily_head` — the two views every dollar in the app is built on — about
  two new types. `adjustment` is already signed, already summed by both, and
  `lot_events.cause` already exists. The safe change is the one that touches
  neither view.
- **Rejected: butchered and missing as deaths.** A butchered animal is a
  decision and a missing one is a hole in the count. Filing either as a death
  puts them in the mortality rate, the death-timing card and the pull-failure
  denominators of the Doctoring & Deaths report, all of which exist to measure
  whether the health program is working.

## 7. Butchered carries no value

John's call. It is a disposal, not a sale: no revenue, no check, nothing
credited. The pen cost that head accrued is still frozen against its source lot
like every other removal.

## 8. Year end: the pen closes, the net goes to Redwing, the next pen starts at zero

John: *"Restart at zero at year end and net income or loss to redwing books."*

At June 30 the pen lot closes, its net (salvage less feed less medicine) posts
to Redwing as a journal entry off the pen's own accounting report, and any head
still standing transfer into the new fiscal year's pen — at **$0**, kind
`fy_rollover`.

- **Rejected: carrying accrued pen cost forward** into the new pen. It keeps
  each animal's lifetime pen bill in one number, which is tidier, but it drags a
  balance across a year that has been posted and closed. Restarting at zero is
  what "net to Redwing" means.

**Consequence:** an animal that spans a year end has its pen cost split across
two fiscal years, each frozen in its own year, and the by-source-lot report is
therefore always read within a fiscal year.

## 9. The pen accrues feed and medicine ONLY

No cost of gain, no labor, no interest, no death loss assumption, no budget,
no target ADG, no break-even. John: *"we then will accrue feed and a little
medicine but no other cost."*

The pen's lot page therefore does **not** show the ordinary Closeout. It shows
what the pen has: head by source lot, removals, feed, medicine, salvage and the
net. Leaving the standard closeout in place would put nine assumption boxes on a
screen where every one of them is wrong.

## 10. Attribution when the tags are unknown is pro-rata by head standing

The pen holds head from several lots at once. When a removal cannot name which
lot the animal came from — and per `docs/lot-transfers-design.md` decision 4,
*tags will generally not be available except for a couple of head* — the head
are drawn across source lots **pro-rata on what is standing in the pen,
largest-remainder so the parts sum exactly.**

This is the mixed-pasture rule (2026-08-31) applied to the pen, and for the same
reason John gave then: nobody can tell by eye which animal belongs to which lot.
The removal form pre-fills the split and it is editable — a named tag overrides
it outright.

## 11. `lot_daily_head` has to learn a third start date

**This is the one change that reaches existing books, and it is a no-op for
every existing lot.**

`lot_daily_head` bounds each lot by `LEAST(first receipt, first invoice)`. A pen
lot has **neither** — it only ever receives transfers. Its `start_date` comes
back `9999-12-31`, it is dropped from the `live` CTE, and it therefore has **no
rows at all**: no head-days, so `lot_feed_daily` can spread nothing to it and
every pound of pen feed lands in `feed_cost_unallocated`.

The bound gains a third term: the lot's first `transfer_in` event.

For an ordinary lot this can never fire, because `record_lot_transfer` already
**refuses** a transfer dated before the destination's first arrival — that floor
is decision 11 of the transfer design and exists for this exact clamping
behaviour. The migration asserts it: it raises if any existing lot has a
`transfer_in` earlier than its first receipt or invoice, so the change is proven
to be a no-op before it is applied rather than assumed to be one.

`record_lot_transfer`'s own floor gains the matching branch: for a feed pen
destination the floor is the pen lot's `arrival_date`, since it has no receipts
to measure against.

---

## Derived decisions — taken without asking, flagged for John

1. **A pen death does not count against the source lot's mortality.** It cannot:
   the animal left that lot as a `transfer_out` before it died. So a lot that
   sends its chronics to the pen will read a **better** death rate than it
   earned. Nothing can fix this in the lot's own numbers without double-counting
   the head, so the feed pen report carries **deaths by source lot** and the
   lot's health section notes how many head it sent to the pen. Worth a look
   before anyone compares mortality across lots that used the pen differently.
2. **The pen is excluded from lot economics reports** — Active Lots break-evens,
   the Anomalies "open lot with 0 head" and "no pasture assignment" checks,
   budget nags and closeout drift — the way test lots already are. It is
   included in Doctoring & Deaths as an ordinary cohort, because its medicine
   and its deaths are real.
3. **Weight is optional on a feed pen transfer**, unlike every other transfer.
   Decision 5 of the transfer design requires a weight because a blank falls
   back to the destination's arrival weight and that assumption is wrong. Here
   there is nothing downstream to be wrong: the pen has no ADG, no break-even
   and no cost of gain. Asking for an estimated weight on a cripple invites a
   made-up number into the books for no purchaser.
4. **Office and owner record; owner deletes.** Same posture as transfers, and
   the pen carries dollars so it reads through `can_read_books()` — crew sees no
   pen money. Crew records the physical sort as an ordinary pasture move.
5. **Removals reverse.** `delete_feed_pen_removal` is owner-only and unwinds the
   head-math artifact it created — reopening an assignment the removal closed
   outright rather than adding head back on top of it. That is the
   `delete_death_event` trap, and the reversal is tested against a pen the
   removal emptied.
6. **A removal cannot be edited, only deleted and re-entered** — the posture of
   a saved shipment, for the same reason: an edit would unwind head math that
   already happened.

## Still to settle

- **Which physical pens.** The pen lot stands in ordinary pastures
  (`Shop / Pens`, `Corner / Pens`, `Shop / Woodpens` all exist), so nothing is
  hardcoded. If the feed pen is always one place, that becomes a default rather
  than a schema change.
- **Field entry.** Crew can see the pen as an ordinary lot and record doctoring
  and pasture moves against it. Sending an animal TO the pen is office-only for
  now, matching transfers; a `pending_field_entries` type is deferred for the
  same reason it was deferred there — the approval ordering against deaths and
  moves is real machinery for a handful of events.
