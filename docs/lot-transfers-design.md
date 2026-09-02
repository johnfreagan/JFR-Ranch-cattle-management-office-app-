# Lot transfers and mergers — design decisions

Fourteen decisions taken 2026-09-01 in one working session with John, reached in
dependency order. Each records what was decided **and why the alternative lost**,
because the reason is the part that stops it being re-litigated in six months.

Supersedes `OPEN-ITEMS.md` #9 ("Merging lots and transferring cattle between
lots — wanted, not designed"), which is now answered and should be marked so.

**Status:** BUILT 2026-09-02, schema NOT YET APPLIED.
Migration `docs/sql/2026-09-02_lot_transfers.sql` is written and waiting for
John to run it in the SQL editor; the app code is in `index.html` and degrades
to "no transfers" until the migration lands, because a missing view returns no
rows and no error.

---

## The problem

Two operations the app cannot do at all:

- **Fold a remnant into another lot.** Four lots on the place are nearly empty
  and cannot be closed: 47-26 has 3 head of 187, 37X-1 has 10 of 274, 59X has
  24 of 241, 60X has 29 of 251. Those 66 head are physically running with other
  cattle; the books say otherwise.
- **Sort head between lots.** Occasionally 10–20 head match another lot better
  by growth or condition and are moved. Same mechanism, both lots continue.

## What was already built and unused

The head math is closer to done than OPEN-ITEMS #9 assumed:

- `lot_events.event_type` already permits `transfer_in` / `transfer_out`.
- `lot_status.head_current` already adds and subtracts them.
- `lot_daily_head` already places them **on their own date**, so a mid-life
  arrival eats grass only from the day it lands — the exact failure OPEN-ITEMS
  worried about is already avoided.

Zero such rows exist (99 deaths, nothing else). What is missing is the write
path, the pasture sync, and — the real work — the money.

## The shape

```
   lot detail (source lot)
      ├── "Transfer head"        ──┐
      └── "Merge into another lot" ─┤  same code path, merge pre-fills
                                    ▼
                            lot_transfers            ← the event, frozen $ basis
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
          lot_transfer_lines  lot_transfer_tags  lot_events ×2
          (from/to pasture)   (optional)         transfer_out + transfer_in
                    │                                   │
                    ▼                                   ▼
        lot_pasture_assignments                  lot_status.head_current
        (source credited, dest debited)          lot_daily_head (own date)
```

`invoices`, `delivery_receipts` and `sales` are all deliberately untouched —
see decision 2b.

---

## 1. Merge and transfer are one mechanism, two commands

Both are a partial-or-total transfer at a valuation; a merge is the case where
the source empties and closes.

**Rejected: combining the books** — repointing the source lot's invoices,
receipts and doctoring onto the destination. It needs no valuation decision and
is tempting for that reason, but it is wrong for every live case: folding
47-26's whole book into 37X would add 187 phantom head in and 178 phantom sold
at 47-26's prices. That framing only fits "I split this lot by mistake", which
John does not currently have. Not built.

## 2. Cattle move AT COST — the giving lot's actual cost per head

The transfer value is the **source lot's "Actual" cost per head off the Closeout
screen on the transfer date**: purchase plus booked carry (processing,
treatment, feed, cost of gain, labor, interest), frozen at transfer.

- **Rejected: purchase cost only.** 47-26 would give up 3 head at $1,955.67 and
  eat ~200 days of carry on cattle it no longer owns. Flatters the receiver.
- **Rejected: market value.** It books margin on cattle nobody sold and needs a
  weight on 3 head that will never cross a scale. Plainly wrong for the sort
  case, which is a reclassification, not a sale.
- **Rejected: no dollars move.** Both lots' books wrong by construction.

At cost is the only basis that behaves for **both** the fold-in and the sort:
neither lot books margin on the transfer, and the animal arrives carrying
exactly what it cost.

**Consequence accepted:** the basis is frozen from live sources. A late feed
invoice or an edited drug price moves the source lot's actual cost and not the
frozen number. Bounded in practice — feed is entered every Monday, so a basis
is stale at most a week. See decision 9.

**Manual override deferred.** Not built until missed.

**The division, settled during the build.** The basis is
`total cost to date ÷ SURVIVING head`, where surviving is
`head_in − dead − transferred_out + transferred_in`. The obvious candidate,
the closeout's existing `costPerHeadOnFeed`, is wrong here: it nets out
revenue already banked, so on a lot that is 95% sold — which every remnant
is — it can go negative. Dividing by survivors is the division
`breakEvenPerLb` already uses, and it is the closeout rebuild's own rule that
in total dollars death loss needs no line because it falls out of the
division. It is also always positive.

### 2b. Why not model it as a sale out and a receipt in

OPEN-ITEMS #9 proposed exactly this, "which reuses machinery that already
exists". It does not survive contact with the schema:

- A `delivery_receipts` row carries `receiving_protocol_id`, and processing cost
  is **derived live** off receipts × protocol × current prices. An internal
  receipt would re-charge the receiving meds on cattle already processed.
- An `invoices` row feeds `lot_daily_head`'s `GREATEST(invoiced, received)`,
  inflating `head_in`.
- A `sales` row lands in realized ADG, the Accounting Report and
  `shipment_reconciliation`, and would read as revenue with no check behind it.

The dollars therefore need their own table and their own path into Closeout.

## 3. One closeout line each side; `head_in` stays "head this lot received"

Source shows `Transferred out — 3 hd, ($7,020)`; destination shows
`Transferred in — 3 hd, $7,020`, beside cattle cost.

- **Rejected: decomposing** the basis back into cattle / processing / treatment
  / feed so each of the destination's lines absorbs a share. It corrupts two
  denominators the app is careful about: processing $/hd is per head **in** and
  treatment $/hd is per **live** head, so the destination's rates would describe
  cattle that were never on that protocol.
- **Rejected: closeout ignores it.** Leaves both sets of books wrong.

**Transferred-in head do NOT count toward `head_in`.** Those animals were
received onto the source lot and processed on its protocol; the destination's
head in and its processing $/hd keep describing what it actually received.

**Follows from this:** the head invariant gains a term —
`head_in − dead − sold − transferred_out + transferred_in = head_current`.
`lot_status` already computes it this way.

**Corrected 2026-09-02 during the build:** this was written expecting the
Anomalies drift check to need teaching. It does not. That check compares the
sum of open pasture assignments against `head_current`, not the three-term
formula — and `head_current` already carries the transfer terms while the RPC
keeps the assignments in step. The lot-detail drift badge does the same. **No
change was needed anywhere**, and nothing in the app asserts the old
three-term form.

**Drill-down.** Clicking the transferred-in line opens provenance per transfer:
source lot, date, days on that lot before transfer, **the receiving protocol
those cattle were actually processed with**, arrival weight, frozen basis, tags.
The protocol line matters most — a withdrawal clock travels with the animal.

## 4. Tags optional, with an explicit "no tags available"

Head move on a count. Naming tags is a second step that repoints `lot_tags`.
Until tags are named or the box is ticked, the transfer sits on Needs Attention
and ages visibly.

The checkbox follows `paperwork_done`: an explicit "stop asking" recording who
decided and when — not a note someone must remember to write. **John: tags will
generally not be available except for a couple of head.**

- **Rejected: tags required.** Blocks the thing that matters most — head math —
  on the thing usually unavailable.
- **Rejected: count only.** Leaves a loose end with nothing tracking it.

**An idea that failed on the data.** Hoped a full remnant transfer could
auto-repoint every still-active tag with certainty. `lot_tags.status` does not
follow sales or deaths: 47-26 has 187 tag rows, **all retired**, though 3 head
are alive; 37X-1 has 274 **all active** for 10 live animals; 37X has 72 tag rows
for 361 head in. The table is a partial registry, not a live roster. It also
means transfers cannot make field tag lookup much worse than it already is —
those tags resolve to nothing today. **Tag hygiene is a separate problem.**

## 5. A transfer carries a weight

One field, pre-filled from `lot_projected_weight` for the source lot on the
transfer date, overwritable, labelled an estimate. **John: cattle usually do not
cross a scale.**

Without it, transferred head are silently modelled as having arrived with the
destination's cattle at its arrival weight — noise on 3 head, real on a 20-head
sort. And the sort case is adverse by construction: those head move **because**
they grew differently, so they are not average. The pre-fill is a lot average
and will read light when the big end is cut off a lot. Say so on the field
rather than dressing it up as a weight.

**Rejected: optional.** A blank has to fall back to an assumption, and the
fallback is the wrong answer being avoided.

## 6. Entry is on lot detail, with pasture lines

Source lot → "Transfer head" / "Merge into another lot". Modal: destination lot,
date, then **one line per source pasture** (head, destination pasture defaulting
to the same one). 47-26's 3 head sit across 2 open assignments, so even the
smallest fold-in needs lines. Availability netting reuses
`loadOpenPastureInventory()`, shared with the shipment and Moves screens.

- **Rejected: a Transfers tab.** A whole screen for a few events a year.
- **Rejected: extending the Moves tab.** Its entire premise is that head math is
  untouched and only location changes. Hanging a lot change on it produces a
  screen where some tickets move dollars and some do not, distinguished by a
  dropdown — which is how someone books a transfer thinking they logged a move.

No separate Transfers list. A transfer appears on both lots' activity timelines,
as the Closeout line with its drill-down, and on Needs Attention while tags are
outstanding.

## 7. The destination lot's budget is left alone

`lot_budgets` stays frozen. Closeout carries a note — *budget covers 274 head;
20 transferred in 2026-09-14* — and per-head figures say which denominator they
are on.

- **Rejected: scaling the budget pro-rata.** Quietly rewriting the plan to match
  what happened destroys the only thing a frozen budget is for.
- **Rejected: owner deletes and rewrites.** That escape hatch exists for a
  budget *typed wrong*. Using it here launders a mid-life event into the
  original plan and loses the fact that the lot changed shape.

Cost accepted: budget $/hd and actual $/hd run over different head counts on a
lot that took cattle in. Label it. Totals stay comparable.

## 8. Office-only now; field entry later if the lag bites

Crew records the physical sort as an ordinary pasture move; office records the
lot change. Each lot's head math stays internally consistent meanwhile — only
lot attribution lags, and **John: the office usually hears the same day.**

**Office and owner create; owner-only deletes** (a reversal touches the same
audit trail as a shipment reversal, and deletes are the narrowest privilege).
Accountant reads. The surface carries `data-perm="office"`; buttons carry
`data-write`.

**Deferred, not rejected: a `pending_field_entries` type.** It needs its own
approval ordering against deaths and moves — a transfer must replay in
`event_datetime` order alongside them or a move outruns it — plus a rollback
path. Too much machinery for a few events a year where the person choosing the
destination lot is not in the pen.

## 9. A stale basis is recomputed on purpose, never automatically

Owner-only "recompute basis": re-freezes at the **original** transfer date from
today's books and appends the prior value to the notes.

- **Rejected: recompute automatically** on any source-lot cost change. That is
  the processing-cost failure with a longer fuse — silently rewriting two lots'
  books with no audit trail.
- **Rejected: frozen is frozen.** Nearly right, and the reason it is not: a
  consumed feed layer is *gone*, so restating it reaches into closed lots and
  prior years. A transfer basis is one number on exactly two open lots, and
  correcting it is a clean two-sided adjustment touching nothing else.

**The nag is bounded.** Feed is entered every Monday, so it fires once — when
feed covering the transfer date has been posted for the source lot — and clears
that week. Still open after two Mondays is odd and should age visibly.

## 10. Cross-fiscal-year transfers are allowed and flagged

Every remnant is FY2026; the lot with room to absorb them, 36-27, is FY2027. So
the realistic fold-in moves cost across a year boundary. The transfer record
carries both fiscal years, Closeout marks it, and the accounting report shows it
as its own line.

- **Rejected: blocking cross-FY.** The cattle are running together whether the
  paperwork is permitted or not; refusing just means the books keep saying head
  are somewhere they are not.
- **Rejected: allowing silently.** Money moves between fiscal years with nothing
  on any report saying so — found at year end with nobody able to explain it.

## 11. Date: hard floor, soft warning

Refused outright: before the destination lot's first arrival, or after
`ranch_today()`. Allowed with a warning past ~30 days back, because backdating
rewrites head-days on both lots.

**The floor is not a nicety.** `lot_daily_head` **clamps** events into
`[first arrival, today]`. A `transfer_in` dated before the destination's first
receipt does not error — it is silently moved up to that lot's first day, and
the lot collects head-days for cattle that were not there. Feed, cost of gain
and labor all charge against head-days, so the money follows the error. Same
shape as the `lot_head_days` 29% discrepancy on 36-27, but operator-introduced.

**Rejected: same day only.** A sort that happened Friday and is typed Monday
must be dated Friday — those cattle ate the destination's grass over the
weekend.

## 12. Transfers post to Redwing

Their own accounting report: one debit line and one credit line, production
center and production year on each side, in the same shape and share/print/copy
path as the shipment report.

- **Rejected: app-internal only.** A silent per-lot divergence between this app
  and Redwing, permanent, surfacing at year end with no explanation attached.
- **Rejected: cross-FY only.** A same-year transfer is exactly as real a
  reallocation; two behaviours means remembering which one you are in.

Cheap to build — the Accounting Report machinery exists and a transfer is a much
simpler document than a shipment: two lines, no weight groups, no deductions.

**Scoped during the build:** it is a **per-transfer document reached from the
Transfers card**, not a second picker screen under Sales. A transfer is not a
sale and does not belong in that tab, and the shipment report's picker exists
to choose among hundreds of shipments — there will be a handful of transfers a
year, each already in front of you when you want its posting. It uses the same
twelve columns so what Lauren keys in has the same shape either way, and the
same print / copy-rows path. **Production Year is taken per ROW from each
lot's own fiscal year**, which is the whole point for a cross-year fold-in:
the credit lands in one year and the debit in the next. The two lines net to
zero by construction and the screen says so.

## 13. Two commands, one code path

"Transfer head" and "Merge into another lot", where merge pre-selects all
remaining head and pre-checks close-the-lot.

The mechanism is identical and B is the same path with fields pre-filled. It
wins on intent: *fold 47-26 into 37X* is a specific thing, and making it out of
a generic transfer every time invites picking 2 head when you meant 3 and
leaving a lot open with one animal in it. The remnant case is the common one and
deserves one click.

## 14. Transferred-in cattle attract NO projected death loss

The projection's `head_in × pct − head_dead` base stays on received head only.
Closeout says so: *death loss projected on 361 received head; 3 transferred-in
head excluded as post-risk.*

This is what the decision-3 `head_in` choice already does by accident; decision
14 makes it deliberate. The assumed death loss is sized for high-risk
lightweight steers in their first weeks. A remnant off 47-26 has been on the
place ~200 days, has already survived that window, and **the source lot already
realized its actual death loss on it.**

- **Rejected: including them** at the lot's assumed percentage — double-counts
  risk the source lot already ran through.
- **Rejected: a reduced rate.** Defensible, but another per-lot assumption to
  maintain for an exposure of 3 to 20 head.

---

## Derived decisions — taken without asking, flagged for John

These follow from the fourteen but were not put to him directly.

1. **`lot_status.total_cost_in` is NOT changed.** It keeps meaning "cattle
   purchase cost from invoices". Transfer dollars arrive through a separate
   view (`lot_transfer_costs`) that Closeout adds. Changing `total_cost_in`
   would silently move every consumer of it — breakeven, cost per head,
   avg_cost_per_head — and several of those are read in places not yet audited.
2. **`lots.parent_lot_id` is not reused** for merge lineage. It appears intended
   for lot splits (37X / 37X-1 / 37X-F) and is unused today; overloading it
   would make two different relationships indistinguishable. Lineage lives on
   `lot_transfers`.
3. **Interest is not double-charged.** The frozen basis includes interest
   accrued on the source lot to the transfer date; the destination accrues
   interest on that amount only from the transfer date forward.
4. **A closed destination lot is refused.** A closed source lot is reopened by a
   reversal, since closure is only `closed_at`.
5. **Test lots are excluded**, consistent with shipment entry.
6. **`kind` is recorded** on the transfer (`fold_in` / `sort`) — the two have
   different economic stories and the drill-down should say which.

## Still to settle

- **Where the FY2026 remnants actually land** — 36-27 (FY2027, cross-year) or
  consolidated into a FY2026 lot. Decides whether cross-FY is the normal path or
  the exception. Not structural; asked twice, unanswered.
- **Whether Lauren posts to Redwing off these reports** or works the shipment
  paperwork directly. Shapes how much the transfer report has to carry.

## Build order

1. Schema + RLS + verify (`docs/sql/2026-09-01_lot_transfers.sql`), run
   `rls_verify.sql` after.
2. `record_lot_transfer` / `delete_lot_transfer` / `recompute_transfer_basis`
   RPCs — INVOKER, atomic, reversal tested against an assignment the transfer
   **closed outright**, not just decremented (the `delete_death_event` trap).
3. Lot detail entry modal, both commands, pasture lines, availability netting.
4. Closeout: the two lines, the drill-down, the budget and death-loss notes.
5. Anomalies: teach the drift check the transfer term; offer "Fold in" from the
   existing *mixed pasture, countable* row.
6. Needs Attention: tags outstanding, basis stale.
7. Accounting report for transfers.

---

## What was built, 2026-09-02

**Schema** — `docs/sql/2026-09-02_lot_transfers.sql`, not yet applied.
`lot_transfers` / `lot_transfer_lines` / `lot_transfer_tags`, four policies
each (books read, office+owner write, owner delete); `lot_transfer_costs` and
`lot_transfer_provenance`, both `security_invoker`; three INVOKER RPCs
(`record_lot_transfer`, `delete_lot_transfer`, `recompute_transfer_basis`).
The verify block asserts RLS, policy counts, no `anon` read, `security_invoker`
on both views, that none of the three RPCs is `SECURITY DEFINER`, that each has
exactly one overload, and — as a precondition — that `lot_events` still permits
`transfer_in` / `transfer_out`.

**The RPCs do not compute the basis.** The app passes it. Blending processing,
treatment, feed, cost of gain, labour and interest is the Closeout's own math,
and a SQL copy would be a second costing path that drifts from the first.

**Two improvements over the RPCs this was modelled on:**

- `lot_transfer_lines` records `source_assignment_closed` and
  `dest_assignment_created` — what the save actually did. `delete_move_event`
  has to *infer* the equivalent by comparing head counts and dates, which is
  fragile; the reversal here reads what happened.
- Both sides aggregate per pasture before touching anything, so a pasture named
  on two lines cannot have the first line close it and the second find nothing
  open. Same rule `delete_shipment_with_reversal` needed.

**App** — all in `index.html`:

- Lot detail gains a **Transfers** card (`data-perm="office"`) with the two
  commands, the history, the provenance detail (source protocol, days on the
  source lot, the basis broken out), a **Redwing posting** button and an
  owner-only **Delete**.
- The entry modal nets availability across the whole sheet and refreshes option
  labels in place rather than re-rendering, so a head field keeps its caret and
  an open dropdown is not shut — the shipment screen's rule.
- Closeout gains the two lines, the drill-down link, forward interest on the
  carried basis, and the notes explaining head-in and the death-loss exclusion.
- Anomalies gains `transfer_tags` and `transfer_basis_stale`. These are lot
  data-integrity follow-ups, so they went **here and not on the Inventory
  needs-attention list**, which is about feed and meds.

**Verification.** Both views were parsed against the live schema with stub CTEs,
which checks every column name on `lots`, `protocols`, `delivery_receipts`,
`invoices` and `feed_usage`. `validate.jxa.js` passes. The plpgsql bodies are
**not** verified — Postgres does not parse them at `CREATE` time and there is no
local Postgres on this machine, so the first real check is John's SQL editor run.

**One bug caught late:** the new code declared its own `round2`, which would
have silently overridden the existing `Number.EPSILON` money rounding at
`index.html:8793` for the whole app, including the shipment accounting report.
Removed.

**Recompute basis** is offered only on the **giving** lot's Transfers card,
owner-only, and only when the basis is actually stale. The basis is that lot's
cost per head and this is the only screen where its closeout math is loaded;
from the receiving lot there is nothing to recompute from. It re-freezes from
today's books at the original transfer date — the days in between add only cost
of gain on the head still standing, which is a rounding error against the feed
invoice it exists to pick up, and the confirm shows both numbers before it
moves anything.

## Still to build

- Field entry (decision 8, deliberately deferred until the same-day lag bites).
- Nothing else from the fourteen decisions is outstanding.
