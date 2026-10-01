# Estimating what the cattle weigh

Design record, 2026-09-10. From John: *"we don't weigh a lot of cattle …
sometimes when we weigh it's only for a pasture that might be doing better or
worse not whole group. Sometimes we sort a lot big and little and again a
total weight change doesn't work. This is going to be a tricky issue."*

He is right that it is tricky, and the trickiness is not where it first looks.

## Two corrections, not one

The anchor work of 2026-09-10 treated "what do these cattle weigh" as a single
question. It is two, and they have completely different costs:

| | what it fixes | what it needs | how often |
|---|---|---|---|
| **Level** | "these cattle weigh X today" | a scale | rare |
| **Rate** | "this lot gains Y, not what we assumed" | nothing | every sale |

**The rate correction is free**, and the ranch was already generating it and
throwing it away. `lot_realized_adg` has computed gain off real pay weights
since the `per_lb` COG work; the projection simply never read it. 37X was the
proof: 283 head shipped at a realized **1.473** while the projection carried
its last 32 head forward at the assumed **1.80** — 910.7 lb against about 823.

**Why 37X came in low, in John's words (2026-09-10):** *"the 37X adg missed
because we waited too long to ship and the cattle backed up. Not a projection
miss and mgt miss by me due to a falling market and holding too long."* This
matters for how the whole feature is read. The 1.80 was a good assumption; the
cattle were held past their window and the gain went flat at the end. So a
realized ADG under the assumption is **a question, not a verdict** — "held too
long" and "assumed too high" produce the same number, and only one of them is
a reason to change the assumption. It is also why a single blended rate is a
blunt instrument: 37X gained near 1.80 for most of its life and then stopped,
which is a curve, and `lot_adg_phases` is the thing that can say so.

**BUILT 2026-09-10** (`docs/sql/2026-09-10_realized_adg_projection.sql`). Rate
precedence is now phases → realized → assumed, gated on the sample, with
`adg_source` on `lot_status` so every screen can say which it used.

Everything below is the LEVEL correction, which is not built.

## Why the pasture is the natural unit of weight

Both of John's awkward cases are the same shape:

- *"only for a pasture that might be doing better or worse"* — pastures
  genuinely diverge. 36-27 is 584 head across eight of them right now.
- *"we sort a lot big and little"* — after a sort the lot has two populations
  and **no single average is true of either**. That is why "a total weight
  change doesn't work"; it is not a precision problem, the number is
  describing something that no longer exists.

Sorted cattle go to *different pastures*. So if the pasture carries the
weight, sorting stops being a special case and becomes two pastures with two
weights. **Pasture is the unit of weight; the lot stays the unit of money.**

`weights` already stores `pasture_id` and `applies_to`, so the data is there.

## The problem that makes this hard

**Cattle move, and the weight describes the animals, not the pasture.**

Weigh pasture 3 on the 10th and the number belongs to the head standing there
on the 10th. Move them to pasture 5 on the 14th and the anchor is now attached
to the wrong population at both ends — pasture 3 holds cattle that were never
weighed, pasture 5 holds cattle whose weight is filed under pasture 3.

This is not hypothetical. 36-27's assignments moved through eight pastures
across August, and 37X-F's remnant landed in four pastures on 8 and 9
September. There are no individual IDs to follow (tags recycle across fiscal
years), so once head are pooled and split there is no way back to "which
animals were on the scale".

Any per-pasture anchor decays the first time cattle move, silently, and looks
authoritative the whole time.

## Options

**B1 — Blend at the lot level, do not add a pasture dimension.**
A weighing covering N of the lot's M head updates the lot average once, as a
weighted blend: `(N × measured + (M − N) × projected) / M`. It becomes an
ordinary lot anchor on that date and is carried forward at the lot's rate
after that.
*For:* gets most of the value of a real weight; no new dimension; the move
problem cannot arise because the weight is applied once, on the day, and never
re-attached to a pasture afterwards. Works with what `weights` already stores.
*Against:* does not answer "is pasture 3 doing better" — it folds that into
the lot average rather than keeping it visible.

**B2 — True per-pasture anchors, head-weighted up to the lot.**
*For:* the only option that actually answers the pasture question.
*Against:* the move problem above, with no clean answer. Sub-options are
expire the anchor on any move (most weighings become worthless within days),
carry it pro-rata through moves (complex, and still guessing), or leave it
attached to the pasture (quietly wrong). Also a new dimension through the
projection, `lot_status`, the closeout and the lot tiles.

**B3 — A sort creates a lot, not a pasture split.**
`lot_transfers` already has `kind='sort'` and `record_lot_transfer` already
carries basis. Sorting big off little becomes a real transfer into a child
lot, and each side gets its own anchor, its own ADG and its own economics.
*For:* truthful — after a sort they ARE two groups; uses machinery that
exists; fixes the case John says a total weight cannot describe.
*Against:* more paperwork per sort, and it splits the lot's cost history at
the point of the sort.

## Recommendation

**B1 now, B3 when a sort actually happens, B2 only if the pasture question
survives both.**

B1 is cheap and immediately useful: a pasture weighing improves the lot number
instead of being captured and ignored, which is the status quo. B3 is the
honest answer to sorting and needs no new schema. B2 is the expensive one and
its central problem — cattle move and weights belong to animals — has no
clean solution, so it should not be built on a guess.

**ANSWERED 2026-09-10.** John: *"stand visible at least as a note. The time
this matters is in the growyard phase and cattle when we get closer to
shipping to have an accurate weight because different pastures perform
differently some years."*

That is neither B1 nor B2 as written, and it is better than both. **Visible,
but a note** — so the pasture number is on screen where it is wanted, and the
projection is left alone, which means the move-decay problem cannot corrupt
anything. And it narrows the horizon: the moment that matters is the run-up to
shipping, not the whole life of the lot, so a weighing has weeks to stay
honest rather than months to drift.

**BUILT** (`docs/sql/2026-09-10_lot_pasture_weights.sql`): the view
`lot_pasture_weights` and a **Last weighed** column on the lot's Currently in
table, carrying the average, the head weighed, the date, the age in days and
the difference against the lot estimate — plus `head_changed` /
`moved_in_since`, which turn the cell amber and say why when the weighing no
longer describes the cattle standing there.

**Still open, and cheaper now:** whether a partial weighing should also BLEND
into the lot average (B1). The note does not, deliberately. Worth revisiting
once there are real weighings to look at — the display will show whether the
pastures diverge enough for a blended lot number to be worth having.

## Standing rules, whatever gets built

- **Never estimate a weight upward to fill a gap.** `hedge_coverage_by_month`
  already refuses to guess `lb_expected` for the same reason: overstating is
  the direction that costs money.
- **A sample never anchors a lot average.** The first head into the trap are
  the gentle ones. `coverage='whole_lot'` plus `applies_to='lot'` stays the
  only combination that re-bases a lot.
- **Shipped head are not a random sample either.** Realized ADG is measured on
  the cattle that left, which are generally the best, so it tends to overstate
  what the remnant is doing. It still beats an assumption that is 18% wrong,
  and `adg_source` is on screen so the reader can discount it.
- **Say which basis a number is on.** The lot tile prints the ADG and whether
  it is measured, phased or assumed. A projection that silently changed basis
  when the first load shipped would be worse than either basis alone.

## BUILT 2026-10-01: a pasture weighing is the pasture's weight, and it moves with the cattle

John, 2026-09-29: *"We will seldom weigh entire groups. For example we
weighed corner traps 1-3 the other day and moved. I think those weights
should be applied to that starting pasture and then the weight in the new
pasture is that weight."* This is B2, and John's answer is the resolution of
the move problem that held it back: **the weight follows the head through
`lot_movements`, blended by head where groups meet.**

His four calls (2026-10-01):

1. **25% of the head in the pasture** qualifies a weighing, for now. The
   field app says how many that is at the scale.
2. **Weight only.** It does not move `lot_projected_weight()`, cost of gain,
   the closeout, break-even, the PB feed plan (`pb_lots_standing` /
   `pb_charge_prefeeds` read the book projection) or the dose suggestion.
   *"We need to see it in action for a while."*
3. **The sale-barn pay weight is the start weight** for the ADG a weighing
   implies, though it likely carries more shrink from handling: *"it is all
   we have."*
4. **The 9/29 corner-trap weighing counts** — *"that's the actual weight that
   day."* It was already `applies_to='pasture'`, so no data was corrected.

### How it works

`lot_pasture_weight_detail(lot)` is a read-only replay; nothing is stored, so
a reversed move or a late approval is reflected the next time anyone looks.

- **Offset from the book.** Every head carries pounds above or below
  `lot_projected_weight()`. Unweighed head have offset 0: they are the book.
  A qualifying weighing sets its pasture's offset to booked average minus the
  book that day. A move carries the source offset to the destination and
  blends there by head. The estimate is book + offset, so weighed cattle
  gain forward at whatever rate the book uses and no second ADG is walked.
- **Head is rebuilt backward**, from today's open assignments through
  `lot_movements`, because receipts never write `lot_movements` and deaths,
  sales and transfers carry a pasture only sometimes. A death or sale since
  the weighing is not added back, so the head behind the 25% test and the
  blend can read a little low. Head shown on screen is always the real head.
- **Within a day:** a whole-lot anchor, then pasture weighings, then moves in
  the order recorded. A weighing whose pasture holds no head at that point
  (gathered into a trap and weighed there the same day) waits for that day's
  moves.
- **A whole-lot anchor resets every offset to zero**, since it has already
  re-based the book. `applies_to='lot'` samples remain a note.
- **The ADG a weighing implies** runs from the last weighing of those same
  cattle (kept through a move only when every head arriving shares one weigh
  date), else from the lot's purchase average on the earlier of the lot's
  weighted arrival and the day the cattle went into that pasture. 36-27's
  corner traps were filled 8/12–8/16 against a weighted arrival of 8/27.

### First result: 36-27, weighed 9/29 and moved the same day

| Trap | Weighed / there | Booked avg | vs book | ADG since in |
|---|---|---|---|---|
| 1 | 30 / 85 | 501.8 | +37.5 | 2.43 from 8/14 |
| 2 | 32 / 81 | 523.8 | +59.4 | 2.79 from 8/12 |
| 3 | 32 / 74 | 489.2 | +24.9 | 2.25 from 8/16 |

Goat Hill (230 head from all three) carries +40.3; Trap (8 from trap 2, 1
from trap 3) +55.6; H3 (one from trap 2, one unweighed from pasture 7) +29.7
at 50% weighed. The lot blends to 482.9 lb against a book of 468.9 on
2026-10-01. Every other lot reads exactly its book.

### On screen

- Lot tile: a **Scaled** line under *Now* — the blend, and how many head of
  how many came off a scale. Only on a lot that has a qualifying weighing.
- Currently in: a **Weight** column (estimate, offset against the book, the
  share weighed and the weigh date; unweighed pastures say *book*), the blend
  in the footer, and a **Pasture weighings** table with gross and booked
  averages, the offset and the implied ADG, each under-25% weighing marked
  *note only*.
- This replaces the 2026-09-10 *Last weighed* note column; the
  `lot_pasture_weights` view stays in the database, unread.

### What would make it move money

Only when John says so, after watching it. The switch is to have
`lot_projected_weight_detail()` (or its callers) read the blend; the PB feed
plan, closeout and dose suggestion would all follow, and the migration that
does it should snapshot every lot's projection first and report the moves,
as the 9/10 migrations did.
