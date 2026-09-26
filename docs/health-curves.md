# Health curves: pull, re-pull and death baselines

Built 2026-09-25 from John's brief. Migration: `docs/sql/2026-09-25_health_curves.sql`
(applied the same day, checked object by object against a scratch build).
Old-rule check: `docs/sql/2026-09-25_health_curves_verify.sql`.

The question this answers: **is this lot pulling and dying faster than cattle
like it usually do?** "Cattle like it" means the same weight class that came
in in the same season. Every number is computed in SQL; the app lays the
numbers out and does no arithmetic of its own.

```
lot_tags ─ delivery_receipts ─ invoices          health_estimated_loads (37X)
        └──────────────┬───────────────────────────────┘
                 health_head_base  (one row per head: arrival, weight)
                       │
   doctoring_events ─ health_pull_days     lot_events ─ health_death_days
                       │                              │
                 lot_health_class (class · season · flags · override)
                       │
             health_curve_lot_daily (each lot, day 0-180 + close)
                       │
             health_curve_measured (cells)    health_estimate_points / _daily
                       └──────────────┬──────────────┘
                              health_baseline          (whole cells)
                              lot_health_status        (each lot, itself left out)
                              health_exceptions        (Position Desk hook)
   lot_death_capture (crew)   health_anomalies   health_excluded_lots
```

## Rules (decided by John, 2026-09-25)

1. **Weight classes** live in `health_class_bands`: 200–400 · 401–550 ·
   551–650 · 651+. Bands are **half-open on the lower bound**:
   `[min_lb, max_lb)`, with max 401 / 551 / 651. So 650.73 lb is 551–650,
   and 400.5 is 200–400. The first band starts at 0, so a lighter lot still
   has a home.
2. **Seasons** are held in two tables. `health_seasons` maps month to season,
   and `health_season_defs` holds the label and the order round the year:
   Dec–Mar(1) · Apr–May(2) · Jun–Sep(3) · Oct–Nov(4). "Nearest season" is
   the distance round that cycle.
3. **Class and season are per lot.** Class comes from the head-weighted
   average invoice weight. Season comes from the month of the head-weighted
   arrival date. Two flags mark a lot for review:
   - **class-span**: any load's weight falls in a different band from the
     lot average.
   - **season-span**: receipts fall in more than one season.

   A flagged lot sits where the rule puts it until John sets a
   `lot_health_overrides` row (owner only, reason required). The override
   wins everywhere. On 2026-09-25 two lots were flagged:
   - 60X (650.73 lb, loads at 648/651/652, receipts May–Jun): both flags.
   - 36-27 (390 lb, Sep loads at 409/413): class-span.

   John asked for this discretion until there are more data points.
4. **Day on ranch is per head**: event date in America/Chicago minus that
   head's receipt date.
   - An **untagged death** uses the lot's weighted arrival date instead.
   - A tagged death the lot never received uses the same fallback and shows
     on anomalies.
5. **First pull** is a tag's first doctoring **day**. **Second pull** is any
   later day. Several entries for one tag on one day count once and show on
   `health_anomalies`. Pulls match on `lot_id` + tag, because tags recycle
   across years.
6. **Metrics are cumulative**:
   - 1st pull % of head received
   - 2nd pull % of 1st pulls
   - deaths % of 1st pulls
   - deaths % of head
   - loss % of head (deaths + shorts), **at close only**
7. **Denominator.** A head counts toward day *d* only once it has reached
   day *d*: today for an open lot, or the lot's close. A pull or death counts
   on day *d* only if it came on or before *d* and that head has reached *d*.
   Dead and sold head **stay in the denominator**, because this is incidence
   per head received.
8. **A lot is never part of its own baseline.** `lot_health_status`
   subtracts the lot's own counts from its cell before dividing. When no
   other lot has reached a day, that day uses the estimate.
9. **Curves are stored daily**, day 0–180 plus a close row for each closed
   lot. The screens show checkpoints 7 · 14 · 21 · 30 · 45 · 60 · 90 · 120 ·
   180 · close.
10. **Every baseline figure carries provenance**:
    - `Measured · N lots, H hd`
    - `Assumed — borrowed from <class · season> · N lots, H hd`
    - `Assumed — John`
    - `Measured to day X, then …` when a lot's head span both kinds of day.
11. **Flag thresholds** are percentage points **above** baseline, one per
    metric, in `health_flag_thresholds` (owner only). They are blank until
    John sets them. With no threshold the deltas show and nothing flags.

### How a lot is scored against its baseline

An open lot is still receiving or has head at very different ages. 36-27's
head, for example, arrived Aug 11 to Sep 15. So the baseline is **not** read
at one average day. Each head is scored at the day it has actually reached:

- `expected 1st pulls` = Σ over head of the baseline's per-head 1st-pull rate
  at that head's day. The same sum gives 2nd pulls and deaths.
- The baseline % is then expected / head, or expected / expected 1st pulls
  for the ratio metrics.

On measured days the per-head rates come straight from the other lots'
counts. On estimate days they come from the four estimates John types.
Deaths % of 1st pull uses `1st pull % × deaths % of 1st`, and deaths % of
head uses its own estimate. So every figure John edits has an effect.

A head past day 180 is scored at day 180, and the card says "baseline held
at 180". A closed lot compares close against close (the other closed lots
in its cell, or the close estimate).

**Deltas and flags subtract the rounded figures**, so each row adds up as
printed: 16.7 − 15.1 reads 1.6, not the 1.5 the unrounded numbers give.
This was changed the day it was built, after the first 36-27 card showed
the mismatch.

## Estimates

- **Stored at the checkpoints**, not daily: 4 metrics × 9 days plus close,
  and loss at close, for 656 rows over 16 cells.
- `health_estimate_daily` draws a **straight line** between the two nearest
  checkpoints, from 0 at day 0. Past day 180 it holds the day-180 value.
- **Seeding** (`seed_health_estimates()`, run by the migration, safe to run
  again) fills every cell/metric/checkpoint that has **no active
  estimate**. For each one it takes the nearest *other* measured cell that
  has a value at that checkpoint:
  1. same class, nearest season
  2. adjacent class, same season
  3. adjacent class, nearest season
  4. anything else, nearest first

  Ties go to the earlier season in the year, then the lighter class. It
  **never borrows from the cell itself**, so a lot alone in its cell still
  gets a baseline. One cell can borrow from different cells at different
  checkpoints, because the nearest cell with data at day 45 may have none at
  day 120. The Estimates grid lists every source, and each box shows its own
  source on hover.
- **John edits through `set_health_estimate()`** (owner only; accountant's
  wrapper refuses it). The old row is stamped `superseded_at` and a new row
  tagged `john` is inserted. **Estimate rows are never deleted.** No DELETE
  policy exists and the grant is revoked.
- **Measured replaces an estimate day by day, not cell by cell.** A day is
  measured when another lot in the cell has reached it. The estimate row
  stays, as history and as the fallback for self-exclusion.
- The seeded values are a **snapshot**. Re-running the seed fills only gaps,
  so borrowed values do not update themselves as data arrives. Measured data
  takes over anyway wherever it exists, and this is what makes that
  acceptable.

## Shorts

"Shorts" means head missing at shipping. Two things count as a short: a
death with cause `missing from shipping`, and a negative `adjustment` with
cause `missing`. A positive `stray_return` nets the shorts down at close.

- Shorts have no day on ranch, so they are on **no daily curve** and not in
  any death metric.
- They show on the death capture line.
- They show in **loss % of head at close**, because John's point is that in
  the end they cost the same as deaths.

Today the only short is 47-26's 2 hd.

## 37X: loads estimated from tag order

37X has one receipt: 8 hd, 2026-09-03, a book correction. Its invoice head
is 369, and its 72 registered tags carry no receipt. The general exclusion
rule would leave it out: receipt head < 80% of invoice head, the same bar
the Doctoring report uses for Avg DOF.

John asked whether tags and invoice dates could estimate it. They can:

- Tags went on in sequence at processing, so the three real invoices take
  4213–4389 (12-04, 177 hd, 423 lb), 4390–4467 (12-07, 78 hd, 415 lb) and
  4468–4573 (12-21, 106 hd, 413 lb). Each range holds exactly its invoice's
  head.
- Checked against the pulls: no tag was pulled before its estimated arrival,
  and the median first pull sits at a normal ~15–29 days per load.
- These rows are `health_estimated_loads`. Deleting them drops 37X back to
  "excluded" with its reason. The 8 hd internal invoice is left out.
- One registered tag (5170) falls outside the ranges and shows on
  anomalies.

## Access

- **Every new table** reads through `can_read_operational()`, which covers
  owner, office, crew and accountant. There are no dollars here, and crew
  need the card and the capture report. **Every write is owner only.**
  `health_baseline_estimates` has no DELETE policy and no DELETE grant.
- **Every view** is `security_invoker = true` and read-only, with
  insert/update/delete revoked from `authenticated`.
- **The base sets come through four SECURITY DEFINER functions**
  (`health_lot_basis_rows`, `health_head_rows`, `health_pull_rows`,
  `health_death_rows`; pinned `search_path`, EXECUTE revoked from public
  and anon). They replaced `health_receipt_weights()` the same day
  (`docs/sql/2026-09-25b_health_curves_speed.sql`). Two reasons:
  - crew cannot read `invoices`, and the weight class comes from invoice
    weight — `lot_projected_weight`'s reason;
  - speed. Under a real login every base-table policy runs its role check
    once per ROW, and the curves read the same tables several times. As an
    owner through the API the lot card took 21 s against PostgREST's 8 s
    limit ("canceling statement due to statement timeout"); as postgres in
    the SQL editor it took 0.4 s, which is why it was missed. With the gate
    checked once per call the owner reads the lot card in ~0.7 s, the whole
    Health Curves page in about 2 s.

  They return operational rows every active role can already read, plus
  invoice weight and head — no dollar column. They return nothing to an
  inactive or unknown user (verified on scratch as `authenticator`: owner and
  crew 4,109 head, inactive 0, anon permission denied), except when
  `session_user` is not an API role (a migration or the SQL editor); a
  client cannot change `session_user`. The same fix removed two per-row
  lookups: the death-to-tag LATERAL in `health_death_days` and the
  "pulled before death" sub-select in `lot_death_capture`.

## Screens

- **Lot page → Animal Health → Health vs baseline** (top card). It shows:
  - class · season · day, and a "by rule — review" chip until the lot is
    confirmed
  - the four metrics (plus loss at close) against the baseline, with Δ in
    points
  - the baseline's provenance
  - the death line: dead · tagged (capture %) · pulled first · never
    pulled · shorts

  The card loads unawaited, because the view takes about 0.5 s, and it
  ignores its result if another lot has opened meanwhile.
- **Reports → Health ▾ → Health Curves** has these sections:
  - lots vs baseline (click a row to open the lot)
  - class & season to confirm (owner sets overrides)
  - baseline table by class × season at the checkpoints for a chosen
    metric (bold measured, italic assumed, hover for provenance)
  - estimates grid per cell (owner)
  - flag thresholds (owner)
  - excluded and estimated lots, and the anomaly list
- **Reports → Health ▾ → Death Capture**: per lot by month plus a lot
  total, printable and shareable as PDF. Capture under 90% shows red.
- **Position Desk hook:** `health_exceptions` holds open lots over any
  threshold. It is empty until thresholds are set. The panel is not built.

## Verification (2026-09-25)

With the old rule (every head classed by its own load, all lots in, no
self-exclusion), the build's base views reproduce John's table exactly:

| Cell | Lots | Hd | 1st pull % d14/d30/d60 | 2nd % of 1st d30 | Deaths % of 1st d30 |
|---|---|---|---|---|---|
| 200–400 Dec–Mar | 31-26 | 1,766 | 9.3 / 21.5 / 27.3 | 13.4 | 6.1 |
| 401–550 Dec–Mar | 47-26, 37X-1, 37X-F | 778 | 7.2 / 17.0 / 20.2 | 12.9 | 6.8 |
| 551–650 Apr–May | 59X | 241 | 8.7 / 19.5 / 25.3 | 12.8 | 4.3 |

31-26 death capture: 116 dead · 52 tagged · 38 pulled before death · 14
never pulled.

Under the built rules:

- **401–550 Dec–Mar** gains 37X: 1,139 hd, reading 6.2 / 16.1 / 19.7, 12.0,
  6.0.
- **551–650 Apr–May** gains all of 60X, because classing is per lot: 492 hd,
  reading 7.7 / 18.7 / 22.6, 9.8, 4.3.
- **All 712 head of 36-27** land in 200–400 Jun–Sep.
- **Self-exclusion leaves some lots on estimates:**
  - 31-26 and 36-27 are alone in their cells.
  - 59X's head are past the day 60X has reached.

## Known limits

- **Estimates borrowed from a young lot are noisy early.** Borrowed d7/d14
  values can come from a handful of head; the grid's hover says how many.
  John overwrites what he does not believe.
- **The per-lot class can move.** A lot whose receipts are still arriving
  (36-27) can change weighted weight, and so class, until the last load
  lands. The review chip shows while it straddles.
- **By-order-buyer cut:** `lots.source` is carried as `order_buyer` on
  `lot_health_class` and `lot_health_status`. The cut itself is not built.
