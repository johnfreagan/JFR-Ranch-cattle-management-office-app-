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
| D11 | How to start, given the books are lump sums? | **A built on C.** First count head-days per bucket (automatic from moves). Then spread each WIP lump sum ranch-wide over all head-days in its bucket ($ ÷ bucket head-days = $/hd-day) and charge each lot by its days in that bucket. Per-pasture costs (lease by acre, JD passes) come later on the same head-days | Head-day counting needs no new input and gives utilization numbers now. Lump sums give every lot real pasture cost now. Per-pasture detail only sharpens the $/hd-day later. B means no baseline for a year; C leaves closeouts without pasture cost |
| D12 | How do the lump sums become a $/hd-day? | **A budgeted rate, checked against the books.** Each bucket gets a budget $ and budget head-days; budget $ ÷ budget head-days = the rate. Lots are charged that rate × their actual head-days in the bucket. A **monthly CSV** from the books brings in the WIP accumulations (actual $) for the comparison: charged vs. booked. Actual $ and actual head-days become the base for the next year's budget. This year the head-days are budgeted too; later years build on actual head-days | John: "workout an estimation (budget for lack of a better word) and accumulate that by head day and compare to true bookkeeping and then use that as a base for future years." Lots carry pasture cost from day one without waiting for the books to close. The CSV is the one office input; goal is to load it this month (Oct 2026) |
| D13 | What period does a budget line cover? | **Per bucket per season**: one line per bucket per season, e.g. "Crop·winter 2026-27 (Sep 1 – May 15): $X budget, Y budget head-days". Growyard and Other (no season) budget per FY | One season = one crop or grazing period. Crop·summer and grass·summer cross Jul 1; per-FY lines would split one crop by guesswork. Each day's charge lands in the FY of that day, so FY reports still tie |
| D14 | What does the monthly CSV hold? | **Transaction detail** for the WIP accounts, exported from **Redwing** (the ranch's ag accounting software), as is. The app stores the rows and sums them per account per month. Re-importing a month replaces that month. John sends a sample export the week of 2026-10-05; columns are mapped to it then | Balances drop to zero when WIP is relieved; detail keeps the season total and the vendor/memo for per-pasture costing later. John: "can hold whatever we need and track." This is likely the same Redwing ledger OPEN-ITEMS #21 expects in October for COG actuals, so build one ledger import that serves both |
| D15 | How does a ledger row find its bucket and season? | **By Redwing coding.** One-time map in the app: Account (plus Profit Center when needed) → bucket; season from Redwing's Production Year. Rows that do not map (no map, or Production Year blank) land on an "unmapped" list for the office to sort | Coding happens once, in the books. Date alone mis-sorts costs paid ahead (August oat seed belongs to crop·winter) |
| D16 | Ranch-wide bucket rate, or per pasture? | **Per pasture, eventually.** Spread bucket cost to pastures **by acre**, then charge lots by head-days in each pasture. Start ranch-wide (D11); per-acre is the target | John: "Straight hd days would allow productive pastures to hide ones that are dragging us down or not utilizing." Per-acre is the only way to see pasture efficiency and utilization |
| D17 | With per-acre cost, who pays for under-used days? | **Capacity rate plus idle cost.** Pasture rate = pasture $ ÷ capacity head-days; a lot pays that rate × its head-days there. The rest is **idle pasture cost**, shown against the pasture. **At season end the idle cost must be charged somewhere** (where: Q19) | Lot closeout measures the cattle; the pasture report measures the land and stocking decisions; neither hides the other. John: the under-utilization "has to be charged somewhere" so the books tie |
| D18 | At season end, where does the leftover land? | **One season-end true-up per bucket-season, ranch-wide.** Leftover = booked $ (Redwing) − $ charged at the capacity rate. It is spread over every lot that grazed that bucket that season, by its head-days there. It shows as its own closeout line, "Pasture true-up". The pasture report splits it into idle cost and budget miss per pasture. Lots closed before season end: Q20 | Lot totals tie to the books (D1 pricing). Own line keeps cattle-only comparisons possible. Charging only the lots on the idle pasture would punish them for a stocking decision |
| D19 | A lot closed before season end grazed that bucket: its true-up share? | **The open lots absorb it.** The season-end true-up spreads over the lots still open, by their head-days in that bucket-season. Closed lots are never re-opened or adjusted | John's call. Closing before season end should be rare. **On the Later list:** revisit the Redwing distribution for closed lots, because the goal is to merge small leftover groups into other lots (lot transfers), which closes the source lot mid-season |
| D20 | How are capacity head-days set? | **Usable acres × a stocking rate.** One stocking rate (head per usable acre) per label and season, in the season-dates settings spot (D7). Capacity = `usable_acres` × rate × days in the season. Optional per-pasture override for odd ground. Next season's rate starts from last season's actual head-days per acre | Four or five numbers a year; acres already in `pastures`. Capacity must be what the land could carry, not what was used, or idle cost is zero by definition |
| D21 | Growyard and Other: capacity and idle cost? | **No capacity, no idle cost.** Cost coded to them spreads by actual head-days at a plain rate per FY (budget $ ÷ budget head-days), trued up to booked $ at FY end under D18/D19 | Growyard cost is mostly feed, already charged by PB. Other is the catch-all so head-days tie. A pen stocking rate adds input and tells little |
| D22 | How does the closeout show phases? | **A Phases table, reached as a drill-down from one simple label on the closeout.** Rows per bucket the lot used; columns head-days, feed $, pasture $, true-up $, total $, $/hd-day; total ties to the closeout. Same columns ranch-wide on a "Phase baselines" view. The closeout itself may move this month to **its own header and section** (an accounting page), still reachable from the lot | John: keep the lot screen simple; the detail is accounting |
| D23 | How does the head-day allocation get into the books? | **A Redwing report that allocates the WIP accounts to production centers (lots)**, built from the head-day charges. Same shape as the existing Redwing exports (Sales → Accounting Report, medicine usage, feed period-end usage): Redwing's twelve columns, Production Center = the lot, Account / Profit Center / Production Year remembered, Copy rows, PDF, a tie-out line | John: "The allocated cost from hd day's calculation will need a redwing report to allocate wips to production center in redwing." Closes the loop: Redwing → app (D14 ledger CSV) → head-day allocation → Redwing |
| D24 | How often is the WIP allocation report run? | **Date-ranged, run monthly.** One row per (WIP account, lot) = capacity rate × the lot's head-days in that bucket in the period. True-up rows appear only in the period in which the season is closed (Q25). Same date picker as the medicine report | Lot cost in Redwing keeps pace with the monthly ledger CSV and the closeouts. Season-end-only would leave WIP unallocated up to 8½ months |
| D25 | When is a season's true-up final? | **The office closes the season with one click** once the books are in. Until then the true-up shows as "provisional" (booked to date − charged to date). The app nudges when a season has been over 30 days and is still open. A Redwing row coded to an already-closed season goes to the next season of the same bucket, flagged on the import | Only the office knows when a season's books are in. A fixed date closes too early or waits too long; never-final keeps posting corrections into Redwing. Closed seasons stay fixed, like closed lots |
| D26 | Gain and CoG per phase without a day-75 weighing? | **Real weight when there is one, projection when not, and say which.** A phase boundary uses a whole-lot weighing within ±7 days if one exists, else `lot_projected_weight_detail()` that day. Phase gain = end − start; phase CoG = phase cost ÷ phase gain. Figures resting on a projected end are marked "projected"; the baseline view can filter to phases with real weights at both ends. The day-75 notice (D5) adds an optional "weigh within 7 days to measure precon gain" | No new input; real weighings sharpen it. A projected CoG is mostly the target ADG echoed back, hence the mark. Cost-only would give up the precon gain D1 asked for |
| D27 | What does the pasture report look like? | **One table per season, one row per pasture, grouped by label, worst $/hd-day first.** Columns: usable acres, capacity head-days, actual head-days, utilization %, head-days per acre, booked $ (budget $ while open), $/acre, $/hd-day used, idle $, budget miss $, plus the same pasture's same-season figures last year. Season picker; a total row per label ties to the bucket's booked $. In the accounting section (D22), linked from Pastures. Crew sees head-days and utilization only, with an on-screen note that dollars are hidden for their role | Worst-first puts the draggers on top (D16). Last year in the row = baseline without a second report. Head-days per acre seeds next season's stocking rate (D20) |
| D28 | Transferred head: whose 75-day clock? | **The clock travels with the cattle.** Transferred head keep their source arrival date (source lot's weighted arrival; per load where the source had one load). Head-days before the transfer stay with the source lot | Same rule as D4 and as the withdrawal clock. Restarting or adopting the destination's clock would give calves more or fewer than 75 precon days |
| D29 | Deaths and found strays | **Deaths** leave head-days on the death date (already true in `lot_daily_head`); no clock effect. **Found strays** return to the feed pen at $0 (existing rule); feed-pen head-days count in pasture head-days so pastures tie; the feed pen is left out of phase baselines | Proposed defaults, accepted by John |
| D30 | How is the day-75 notice delivered? | **A row on the office app's Needs Attention list**, e.g. "Corner 1: last calves reach day 75 on 10/28 (lot 36-27) — weigh within 7 days to measure precon gain (optional)". Appears 7 days before, clears itself when the date passes; no acknowledging. The D25 season-still-open nudge uses the same list | The office works Needs Attention daily; no new place to look, no extra click |
| D31 | Repair history first? | **No. Build going forward.** Closed and nearly closed lots are not gone back to. Head-days, charges and phases start from a go-live date (date: open) | John. The FY 2027 gap (lot head-days 134,749 vs assignment head-days 84,800 on 2026-10-04; 37X, 60X, 47-26 the biggest) is history and stays as is |
| D32 | Source of head-days by pasture | **Pasture assignments**, from go-live. John: "A calf can't be here now without a pasture assignment." A daily tie-out (sum of open assignments = `head_current`, the D8 rule) goes on Anomalies so a gap shows the day it starts | One source. Assignments are the only data that know the pasture |
| D33 | Lots that are not preconditioned | **Precon still applies to most cattle, even when started on oats.** The 75-day clock overrides the pasture label (as D2) | John |

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
- **Closed lots and the true-up (D19):** revisit how Redwing distributes cost for lots closed before
  season end. Merging small leftover groups into other lots closes the source mid-season, so this
  will come up.
- Feed rows do not keep the pasture once posted to a lot; PB knows it at plan time (pb_posting_plan)
  and `post_feed_usage` takes `p_pasture_id`, so per-pasture feed could be recorded going forward
  if a later question needs it.

## Data already in place

- **Name clash to avoid when building:** `lot_adg_phases` already exists. It is the ADG curve
  (e.g. a 10-day receiving phase, measured from the weighted arrival date) used by
  `lot_projected_weight_detail()`. The precon/grower "phases" in this design are a different
  thing; name the new tables and views so the two cannot be confused (e.g. "bucket").

- `lot_pasture_assignments` (moves, with moved_in / moved_out) → head per pasture per day.
- `lot_daily_head`, arrival-date weighting, invoices/receipts by date → each load's arrival.
- `lot_feed_daily` spreads lot feed over head-days; `lot_transfers` freeze basis.
- `pastures` has acres, total_acres, usable_acres, is_crop_ground, current_crop, planting_date,
  expected_termination.

## Critique round (2026-10-04)

John asked for a harsh critique before building. Checked against the live database (read-only). Items, with status:

| # | Problem | Status |
|---|---|---|
| C1 | History: 37% of FY 2027 head-days have no pasture assignment; closed lots 31-26 / 32-26 have assignments left open | **Settled by D31** (going forward only) |
| C2 | Two sources of head-days (`lot_daily_head` vs assignments) | **Settled by D32** |
| C3 | The $0.50/hd-day non-feed placeholder already includes pasture (`cog-design-decisions.md`): pasture would be charged twice | Q31 |
| C4 | Charge rate defined twice (budget $ ÷ budget hd in D12; pasture $ ÷ capacity hd in D17/D20). Capacity > use, so lots are always under-charged and the true-up dominates | open |
| C5 | D19 undoes D17: open lots absorb idle cost and closed-lot shares, so lot baselines depend on timing | open |
| C6 | True-up gaps: "open" as of when; no home when every grazer is closed; true-up lump lands in the wrong FY for seasons crossing Jul 1 | open |
| C7 | Assignments hold head counts, not loads: which trap holds the precon calves of a two-load lot is unknown, so D5's per-trap notice cannot be computed | open |
| C8 | Production Year cannot name a season that crosses Jul 1; not confirmed the bookkeeper fills it | open (pending bookkeeper) |
| C9 | Redwing loop: the D23 allocation journals come back in the next ledger CSV as WIP credits | open |
| C10 | "Re-import replaces the month": no transaction ID, back-dated rows into closed seasons, reversals | open (pending sample) |
| C11 | Per-acre spread of one bucket lump sum gives every pasture the same $/acre; per-pasture budget miss impossible; D27 over-promises | open |
| C12 | Phase CoG = allocated feed ÷ projected gain; feed split by head share assumes precon and grower calves eat alike; whole-lot weights blend loads | open |
| C13 | Season-date change (D9) or label change (D8) mid-season: what happens to the budget line and capacity | open |
| C14 | No "not preconditioned" lot setting | **Partly settled by D33** ("most cattle"): whether an exception setting is needed is open |
| C15 | Test lots TEST_DOC1 / TEST_DOC2 carry head-days and assignments in production; they would take true-up | open |
| C16 | All 63 pastures have no acres; none has capacity; only 1 is marked crop ground | open (data entry) |
| C17 | Input load understated | open |
| C18 | Build order puts the import at step 4 though D12 wanted the CSV this month | open |

## Proposed build order (awaiting John's approval — nothing built)

Each step stands on the one before and is useful alone. Every step: migration file in `docs/sql/`, RLS and policies on new tables, `security_invoker` views, `rls_verify` after, crew never sees dollars.

1. **Labels, seasons, stocking rates (settings).** Dated label history per pasture (D6, D8); season dates with forward-only changes (D7, D9); stocking rate per label·season with per-pasture override (D20). Input: John labels each pasture once.
2. **Head-day buckets (no dollars).** One derived view: head-days per lot × pasture × day × bucket. Precon from each load's own 75-day clock (D2–D4), clock travels on transfers (D28), deaths and feed pen per D29. Gives utilization and head-days per acre at once (D11 "C" part). Day-75 Needs Attention row (D5, D30).
3. **Budget lines and lot charges.** Budget $ and budget head-days per bucket·season, per FY for Growyard/Other (D12, D13, D21). Capacity rate (D17, D20) × head-days charged to lots. Phases drill-down from the closeout with gain and CoG (D22, D26).
4. **Redwing ledger import.** Monthly transaction-detail CSV (D14), account → bucket map, Production Year → season, unmapped list (D15). Waits on John's sample export (week of 2026-10-05). Built once to also serve COG actuals (OPEN-ITEMS #21).
5. **True-up, season close, pasture report.** Provisional and final true-up spread over open lots (D18, D19); one-click season close and late-row roll-forward (D25); pasture report (D27).
6. **Redwing WIP allocation report.** Monthly date-ranged export, twelve Redwing columns, Production Center = lot (D23, D24).
7. **Later list items** (lease by acre, JD Operations Center passes, labor/overhead, closed-lot distribution).

The closeout's move to its own accounting section (D22) is separate work John expects this month; steps 3, 5 and 6 land in it.

## Open question (resume here)

Q30 (approve build order) is on hold until the critique items are settled.

**Q31 (C3). The $0.50/hd-day non-feed placeholder already covers "pasture, mineral, fuel and overhead". How do we avoid charging pasture twice?**
- A. **From go-live, a new non-feed rate that excludes pasture**, entered as a new dated rate (never an edit of the old one). Pasture reaches lots only through the head-day charge. John sets the new figure (e.g. $0.50 less the pasture share).
- B. Keep $0.50 all-in. The head-day pasture charge is shown as analysis only and is not added to lot cost.

Recommended: **A**. The head-day charge is the better pasture number (by bucket, by season, trued to the books). Keeping a flat guess beside it means two pasture figures that disagree. A dated new rate follows the never-edit-in-place rule, so closeouts before go-live do not move.
