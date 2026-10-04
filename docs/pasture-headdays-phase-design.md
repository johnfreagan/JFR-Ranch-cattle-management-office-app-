# Phases, pasture head-days and pasture cost — design interview (in progress)

Started 2026-10-04 with John, one question at a time, each with a recommended answer. Decisions
below are John's answers; the reason is recorded so it is not re-litigated. **Status: design only,
nothing built.** Continue from "Open question" at the bottom.

## The goal

John: "Big reason for this whole app build is baselines and comparisons." Feed is now charged to
lots daily from the PB import, but nothing splits a lot's life into **phases** (preconditioning,
then grower on crop, grass, growyard), and nothing measures **pasture use** — head-days by pasture
and season — which is what spreads pasture cost ("more head-days lowers the cost per head").
Inputs and office operations must stay simple: John's explicit constraint, after early options
leaned complex.

## Where lot feed shows today (2026-10-04)

Lot detail → Closeout "Actual" (actual feed after the feed-direct cut-over, assumed COG before),
Inventory → Feed → Cost ("Feed cost by lot": lb, $, $/hd in, $/hd-day, lb/hd/day), Inventory → Feed
→ Cost centres, Inventory → Reports (Redwing). Lot transfers freeze cost-to-date per head, feed
included, into the destination lot.

## Decisions

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | What should the precon number drive? | **Both**: price a preconditioned calf and judge the phase (CoG, $/hd-day) | One calculation gives both |
| D2 | How does precon end? | **A clock, no entry.** Precon = the first **75 days**; nobody marks it | Transfers, phase dates and per-tag tracking were all rejected as too much input. Pasture alone cannot mark it: Corner traps are precon on arrival and growyard traps later in life |
| D3 | Clean-up move before day 75? | **Day 75, period.** Moves never change precon | Same window every lot = comparable baseline |
| D4 | Whose 75 days? | **Each calf's own**, from the date its load arrived (8/11 load: precon through 10/25; 9/09 load: through 11/23). The lot's precon closes when its last load reaches 75 days | Every calf gets exactly 75 precon days; no pasture grouping needed |
| D5 | Office notice | The office app warns as a lot's (or a trap's) last calves near day 75 — e.g. "Corner 1's last calves reach day 75 on 10/28" | John's ask |
| D6 | Labels after precon | Pasture labels **Crop, Grass pasture, Growyard, Other** | John's list. "Other" catches hospital traps, pens, odd ground so head-days always tie |
| D7 | Seasons | Crop: **winter Sep 1 – May 15** (oats), **summer May 16 – Aug 31** (cover crop, residue, volunteer). Grass: **winter Nov 1 – Apr 1**, **summer Apr 2 – Oct 31**. Growyard and Other: no season | John's "best guess for now"; one settings spot |
| D8 | Label changes | **Dated label history** — a change takes a "from" date; earlier days keep the old label | A label is a fact about the land; editing in place would rewrite history |
| D9 | Season-date changes | **Forward only** — a change applies from its effective date; past days keep the season they were sorted into | Head-days will carry cost; re-sorting past years would confuse look-backs |
| D10 | Which costs are charged by head-days | **Pasture costs only** (lease/rent, fertilizer, seed, spraying, planting/cultivation) | Feed is already charged exactly per drop by PB; labor and the non-feed rate are already per head-day in the closeout. Labor/overhead come with the accounting integration John is close to |

Resulting head-day buckets: **precon** (first 75 days, wherever the calf stands), then
**crop·winter, crop·summer, grass·winter, grass·summer, growyard, other**.

## What the books hold today (D11 context)

Pasture expenses are "a jumbled mess that needs structure": WIP accounts as lump sums for
**grazing oats, summer native, winter native**. These map almost 1:1 to buckets: grazing oats =
crop·winter, winter native = grass·winter, summer native = grass·summer.

## Later list (John: "keep in mind what other costs would be important and how to structure the capture")

- Lease broken out **by acre** per pasture (pastures already carry acres / usable_acres fields).
- Agronomic passes per field (fertilizer, seed, spray, planting) from **John Deere Operations Center**.
- Cost buckets for crop·summer and growyard.
- Labor and overhead (option C of D10) with the accounting-expense integration.
- Feed rows do not keep the pasture once posted to a lot; PB knows it at plan time (pb_posting_plan)
  and `post_feed_usage` takes `p_pasture_id`, so per-pasture feed could be recorded going forward
  if a later question needs it.

## Data already in place

- `lot_pasture_assignments` (moves, with moved_in / moved_out) → head per pasture per day.
- `lot_daily_head`, arrival-date weighting, invoices/receipts by date → each load's arrival.
- `lot_feed_daily` spreads lot feed over head-days; `lot_transfers` freeze basis.
- `pastures` has acres, total_acres, usable_acres, is_crop_ground, current_crop, planting_date,
  expected_termination.

## Open question (resume here)

**Q14. How do we start, given the books are lump sums?**
- A. Spread each WIP lump sum over all head-days in its bucket, ranch-wide ($ grazing oats ÷ all
  crop·winter head-days = $/hd-day), charged to each lot by its days in that bucket. Per-pasture
  detail later (lease by acre, JD passes).
- B. Wait and build per-pasture costing from the start.
- C. Count head-days only for now; charge no cost yet.

Recommended: **A built on C** — head-day counting first (automatic from moves; gives utilization
numbers immediately), then the WIP lump sums so every lot carries real pasture cost now; per-pasture
costs slot into the same head-days later and only sharpen the $/hd-day.

Then still to walk: where head-days and phase costs appear on screen (closeout, a pasture report),
how strays / transfers / deaths count against the 75-day clock, how the notice is delivered, how
the lump sums get entered (per season? per FY?), and which FY a season straddling Jul 1 belongs to.
