# Strays and missing head — design decisions

Decisions taken 2026-09-07 with John, from his question: *"Occasionally we get
cattle back that we killed off, or sometimes so long gone that the lot has been
closed. How do we propose handling these situations."*

Migration: `docs/sql/2026-09-07d_strays_and_missing.sql`.

Each decision records what was decided **and why the alternative lost**, because
the reason is the part that stops it being re-litigated in six months.

---

## The problem, from the live books

Lot **47-26** was closed on 2026-09-03 by writing 2 head off as a **death**,
cause `missing from shipping`, note *"unaccounted for at shipping removed to
close lot. jfr"*. Nothing died. That single row is the whole problem in
miniature:

- It sits in the lot's **mortality rate** (8 of 187, 4.28%; the honest figure is
  6 of 187, 3.21%), in the **death-timing card**, and in the **pull-failure
  denominators** of the Doctoring & Deaths report.
- It carries those head on the closeout's **death-loss line**.
- And it makes deleting a death that never happened the **only** way to bring
  the animal back if it walks out of a thicket in October.

The feed pen settled the first half of this on 2026-09-07 — *butchered and
missing are negative `adjustment` events with a cause, not deaths, because
filing either as a death puts it in the mortality rate* — and that ruling simply
never reached ordinary lots. This is it reaching them, plus the symmetric entry
for a head that comes back.

Both closed lots on the place (`31-26`, `47-26`) are FY 2026, which has been
reported. That is not an edge case to design around later; it is the common case
for a stray.

---

## 1. Missing head leave as a NEGATIVE adjustment, never as a death

`record_missing_head` writes `lot_events` with `event_type='adjustment'`,
`head_count = -n`, `cause='missing'`, and draws the pasture assignment down
exactly the way `record_death_with_pasture` does.

**Rejected: keep filing them as deaths with a descriptive cause.** That is the
status quo and it is precisely what corrupts the health reports. Nothing in the
Doctoring & Deaths report reads `cause`; it counts `head_dead`.

**Rejected: a new `event_type`.** `adjustment` is already signed and already
summed by `lot_status.head_current` and `lot_daily_head` — the two views every
dollar in this app is built on. A fifth event type means teaching both of them a
new word, for no gain. This is the same argument the feed pen made for butchered
and missing, and it was right there too.

The head-math invariant in CLAUDE.md is written `head_in − head_dead −
head_sold = head_current`. `lot_status` has always computed it with the transfer
and adjustment terms as well; a missing write-off makes that visible for the
first time on an ordinary lot. Nothing in the app needed changing for it — the
Anomalies drift check compares pasture sum to `head_current` and is unaffected.

## 2. A stray comes back as a POSITIVE adjustment, dated the day it was found

`record_stray_return`, `cause='stray_return'`, at a **$0 basis**: `head_in`
never moves, no invoice changes, nothing is added to cattle cost. The lot has
already spent everything it is going to spend on this animal.

**Rejected as the general answer: delete the write-off.** That is right when the
entry was simply *wrong* and the mistake is fresh, and both reversals
(`delete_head_adjustment`, `delete_death_event`) are offered for exactly that.
It is wrong once time has passed, because `lot_daily_head` would hand the lot
every head-day back to the date of the write-off, **silently re-pricing feed,
cost of gain, labor and treatment on every day since** for an animal nobody was
feeding. A stray that comes back after months is a new fact on a new date, not a
correction of an old one.

The app says so at the point of decision: the reversal's confirm text spells out
what a reversal does to head-days and names the other button.

## 3. A closed lot is never re-opened for a stray

`record_stray_return` refuses one, and the error names the feed pen.

`lot_daily_head` bounds every lot by `LEAST(closed_at::date, ranch_today())`.
Re-opening a lot moves that end date to today, which un-finalises a fiscal year
that has been reported to Redwing. Both closed lots stand at 0 head, so the gap
days would carry no head-days and cost nothing — but the year is still re-opened,
and the closeout, the death rate and the Active Lots report all move.

**The stray goes into the FEED PEN at $0, naming the closed lot it came off.**
Everything that needs is already built:

- `record_feed_pen_opening` exists and takes head onto the pen with no transfer.
- Its `source_lot_id` is **already nullable**, for John's own case — *"they
  literally don't come from a lot"* — and NULL is its own group on the pen's
  cost report rather than a lot number nobody believes.
- Pen cost is **tracked, never charged back**, so naming a closed lot touches
  that lot's books in no way at all.
- The pen already keeps its own books and posts its net at year end.

**Rejected: a `STRAY-27` lot per fiscal year, mirroring the pen.** A second copy
of the pen's machinery — one per year, its own rollover, its own removals, its
own reconciliation — for a handful of head. The pen is defined as *"cripples,
chronics and anything else with little value left"*, and a stray off a lot that
closed six months ago has zero book value by definition. It fits the definition
literally.

**Rejected: hang the stray on whatever current-year lot is standing in that
pasture.** It contaminates a real cohort with an animal that is not part of it —
its mortality, its cost per head, and its rows in the Doctoring & Deaths report's
cohort tables, which only mean anything because every head is in exactly one
group.

If the stray is sound and worth finishing, it is finished on the pen and sells
off it; the pen's salvage line captures the check.

## 4. `feed_pen_ledger.entry_kind` gains `'stray'`

A stray recovered after its lot closed is not the same fact as a calf that was
standing in the pen and had never been carried anywhere, and the pen's
cost-by-source report is where that difference shows. Lumping them repeats the
Doctoring report's lesson exactly: three kinds of missing paperwork filed as one
made the gap look four times its real size.

`record_feed_pen_opening` gained `p_entry_kind` and was **DROPped and recreated,
not overloaded** — PostgREST resolves an RPC by argument names and two
candidates make that ambiguous, the lesson `post_feed_usage` taught. The verify
block asserts exactly one of each function name survives.

## 5. One reversal for all three, and both directions carry a trap

`delete_head_adjustment` handles missing, stray return and the pen's opening
entry, because all three are signed adjustments carrying a pasture and all three
reverse the same way. Three separate reversals would drift.

- **Negative** (missing — head come back). If the event closed the assignment
  outright, **reopen it with exactly the head returning**, never adding to the
  stored `head_count`, which was deliberately left where it stood when the row
  closed. That is the `delete_death_event` bug — 3 head, death of all 3,
  reversal, and the lot came back with 6. Tested against an emptied assignment,
  not just a partial one.
- **Positive** (stray back, pen opening — head leave again). **Refuse** when the
  assignment no longer holds them. They have since been moved, sold or died, and
  silently taking a count negative puts the lot into drift that surfaces days
  later on a report nobody connects back to this delete.

A pen's butchered / missing rows are the tail end of a **removal**, which has
its own reversal that also unwinds the frozen source-lot cost and the salvage
split. The card offers Reverse only on the pen's own arrivals; everything on an
ordinary lot is reversible from there.

## 6. `feed_pen_ledger.opening_event_id`, ON DELETE CASCADE

An opening writes a `lot_events` row **and** a `feed_pen_ledger` row, and
nothing tied the two together — so an opening typed wrong could not be undone
without leaving the ledger holding head the head math no longer carries, which is
precisely the drift `feed_pen_reconciliation` exists to shout about.

A cascade rather than a `DELETE` inside the RPC: the guarantee then holds for
anyone who removes the event by any route, including one nobody has written yet.

The backfill links pre-existing rows only where **exactly one** candidate event
matches on pen, date, head and kind. A guess there would attach the cascade to
the wrong row.

## 7. The closeout carries a Missing line, carved out of Cattle in

Without it the closeout keeps carrying written-off head as live cattle, which is
the thing the write-off just said they are not.

`missingLossUsd = netMissing × avgCostIn`, subtracted from Cattle in exactly the
way death loss is — never added on top — so **Cattle in + Death loss + Missing
still sum to the invoices** and total cost is unchanged. `survivingHead` drops
the missing head, which is what the transfer basis and the per-head divisions
read. Strays back net the line down again, and when more come back than were
ever written off the row flips to **Strays back** and reads as a credit, which
is what has actually happened to that lot.

**Nothing projects forward.** Nobody assumes a rate of going missing the way
they assume a death rate, and inventing one would be a number with no source.

## 8. Two Anomalies findings

1. **Head written off as missing, lot still open** — medium inside 90 days, low
   after. John's rule for a mixed pasture applies here too: the moment there are
   few enough head left to read tags is the moment to go look. The detail names
   the right button and says why a reversal is the wrong one.
2. **Death recorded for head that may not have died** — a death whose `cause`
   matches `/missing|unaccounted|not found|never found|lost|stray/i`. Medium on
   an open lot, low on a closed one. Flagged on closed lots deliberately: it is
   inflating that lot's death rate right now, and it is a data correction
   somebody can still approve.

## 9. Reclassifying 47-26 is offered, not run

The migration carries the `UPDATE` commented out with the reasoning. 47-26 is
closed and sits in FY 2026, which has been reported, and `delete_head_adjustment`
refuses a closed lot for exactly that reason. `head_count` is already `-2` and
stays that way — `lot_status` subtracts a death's absolute value and **adds** an
adjustment's signed value, so `head_current` lands in the same place.

John's call, on his explicit say-so, noting that it rewrites a prior year.

---

## What was tested

Applied to a scratch PostgreSQL 16 cluster against a harness of the tables it
touches, then:

| | |
|---|---|
| Write-off that **empties** a pasture, then reverse | reopens at exactly 3, not 6 — the `delete_death_event` trap |
| Partial write-off, then reverse | 20 → 15 → 20 |
| Stray onto an **open** assignment, then reverse | 20 → 22 → 20 |
| Stray **creating** an assignment, then reverse | closes it, leaves `head_count` intact |
| Reversing a stray whose head have since gone | refused by name |
| Stray onto a **closed** lot | refused, points at the feed pen |
| Stray / missing on the **feed pen** | refused, points at the pen's own entries |
| Date before the lot had cattle, and a future date | both refused |
| More head than the pasture holds | refused |
| Pen opening as `'stray'` | ledger kind, event link, and the cascade on delete |
| A bad `entry_kind` | refused |
| A **death** through `delete_head_adjustment` | refused, names `delete_death_event` |
| The migration applied three times over | idempotent, and the third run is a no-op |

The idempotency test caught a real bug: the `DROP` targeted only the old 7-argument
signature, so a second run left the 8-argument version standing and the `CREATE`
failed. Both signatures are dropped now.
