# Architecture: what each part of the app does and why

_Moved word for word from `CLAUDE.md` on 2026-09-27, when CLAUDE.md became a short index. Nothing here was rewritten; section dates are the dates the rules were written._

The app itself, as CLAUDE.md introduces it:

> # JFR Ranch Cattle Management App
>
> Single-file web app (index.html at repo root) for JFR Ranch Co. Ltd., a stocker
> cattle operation in Kosse, TX. Deployed via GitHub Pages. Backend is Supabase
> (PostgreSQL + auth + PostgREST). Owner: John Reagan.
>
> **Multi-user as of Aug 2026** — three roles (owner/office/crew) enforced by RLS.
> See "Access control" below and `docs/security-model.md`.
>

## Sales: the buyer's write-up (rebuilt 2026-08-26)

An order buyer settles on one sheet: a date, a destination, truckloads
grouped into weight classes, one $/cwt against one pay weight, and a draft
after checkoff. One sheet routinely spans several lots and many pastures.

```
shipments ──┬── shipment_weight_groups ── shipment_loads ── shipment_load_lines
            ├── shipment_deductions
            └── sales (one per lot PER DAY) ── sale_sources (per pasture+group)
```

- **`shipments` sits ABOVE `sales`; it does not replace it.** Each lot still
  gets an ordinary `sales` row, so closeout, realized ADG, the lot activity
  timeline and head math work unchanged and know nothing about shipments.
  Moving `lot_id` off `sales` would be truer to "one sale = one check" and
  would rewrite all of those against live books for no gain.
- **`net_amount` is the draft; `book_proceeds` is the revenue.** They differ
  only when `jfr_pays_freight` is on. `book_proceeds` is a GENERATED column
  (`net_amount − freight when ours`), it is what gets allocated to lots, and
  it is what lands in `sales.total_price`. Reconciling to the paper sheet uses
  `net_amount`; anything about margin uses `book_proceeds`.
- **A truck is weighed ONCE.** `shipment_loads` holds the date, the head and
  the single gross weight off the scale ticket; `shipment_load_lines` holds
  the lot/pasture split. Nobody weighs a pot twice, so asking for a gross per
  pasture (as the first cut did) is asking for a number that does not exist.
- **Allocation is two nested splits, then money.** Load gross → line gross
  (by head) → line pay weight (by gross, within the weight group) → dollars
  (by pay weight); per-head deductions and freight follow head. Every step is
  largest-remainder, so each share is exact at every level.
- **A load's lines must sum to the load's own head.** The buyer states head
  per truck; if the split does not add back to it the gross is divided over
  the wrong number of animals and every lot on that truck books wrong —
  silently, because the money still allocates. `shpValidate()` blocks it and
  `shipment_load_reconciliation` catches it after the fact.
- **A single-line load takes its head from the load**, so the common case
  (one pot, one pasture) is typed once. Adding a second line writes the
  implied head down first.
- **The lot and pasture pickers narrow each other, and either can go first.**
  Five pastures currently hold more than one lot (Garrett/Trap has three;
  Steele/Front Native has 416 head across two), so a load gathered off one
  pasture routinely draws on several lots — forcing the lot to be named first
  is backwards for exactly the case that is hardest to get right by hand.
  A still-valid choice on the far side is KEPT when the near side changes;
  clearing it unconditionally would make picking the pasture second wipe the
  lot just chosen. Two lines on one load may share a pasture and differ only
  by lot.
- **The pickers net out what the sheet has already drawn**, so entering load
  after load walks the counts down live: `Corner / 1 (23 of 85 left)`. The
  line being edited is EXCLUDED from its own count — otherwise its head would
  count against its own ceiling and the number would fight the person typing.
  Head fields deliberately do not re-render (it would eat the caret), so the
  option labels are refreshed from `recomputeShipment()` instead, skipping any
  select the user is currently in so an open dropdown is not shut.

### Multi-day sheets

- **`shipments.sale_date` is the settlement date; `shipment_loads.load_date`
  is when cattle actually left.** One sheet routinely spans days.
- **The app writes one `sales` row per (lot, DAY), not per lot.** Cattle that
  left on the 19th ate grass on the 19th and not the 21st, and head-days are
  what cost of gain and labor are charged against. Collapsing nine loads onto
  one date hands the ranch days of head-days on cattle already gone.
- **A pasture that empties closes on the date of the LAST load that drew on
  it**, not the sheet date.
- **Allocation uses largest-remainder, and the parts sum EXACTLY.** Not
  "round each and dump the residual on the last line" — that works too, but
  always parks the error on whichever lot was typed last. Verified against the
  2026-08-21 Thigpen sheet: 549 hd, 446,194 lb, $320.00/cwt, $1,427,820.80
  gross, $1,098 checkoff, $1,426,722.80 draft, all ties exact.
- **A saved shipment can be re-priced but not re-allocated.** "Edit money" on
  the shipment detail changes buyer, destination, sex class, $/cwt,
  deductions and freight, and recomputes the dollars over the head and pay
  weights ALREADY RECORDED. `lot_pasture_assignments` is never opened, so no
  cattle move and the worst outcome is a number still wrong, fixed by editing
  again. It allocates over `sale_sources` rather than the load lines the
  original save used — both sum exactly, and going through the rows that
  carry the money means the thing being rewritten is the thing being read.
  Deductions are rebuilt rather than diffed; there are two or three of them
  and a diff is more ways to be wrong.
- **What shipped, from where, on what day still cannot be edited.** That would
  unwind head math that already happened. Delete and re-enter — deleting now
  puts the cattle back.
- **Deleting a shipment goes through `delete_shipment_with_reversal`** and
  DOES put the cattle back. Owner-only, INVOKER like every other head-math
  RPC. The reason it is an RPC and not four browser statements: a sale either
  DECREMENTED an assignment or CLOSED it, and those reverse differently — a
  decrement gets head added back, a close is only reopened, because closing
  leaves `head_count` intact. Sources are aggregated per (lot, pasture) first,
  or a pasture feeding two weight groups reopens on the first row and then
  gets head added on the second. This is the `delete_death_event` trap.
- **Closing an assignment leaves `head_count` intact** — set `moved_out` only.
  The first cut of the shipment save also zeroed the count, which would have
  made the reversal restore nothing. It now matches the single-sale path.
- **Shrink is an input, not a display.** The buyer writes gross and a shrink
  %, and pay weight falls out. An explicit pay weight overrides. The old
  single-lot sale form takes gross and net and only shows shrink afterwards;
  it is unchanged and still works that way.
- **Crew cannot read `sales` or `sale_sources` at all** (2026-08-26, John:
  "crew can't see any dollars"). Because an RLS denial returns zero rows and
  not an error, two UI surfaces had to be told: the lot-detail Sales sub-tab
  carries `data-perm="office"`, and the lot activity timeline prints a line
  saying sale events are hidden for that role. Without those, a shipped lot
  looks like missing data instead of a permission boundary.
- **Crew CAN still see `medications.cost_per_unit` / `cost_per_head` /
  `bottle_cost` and `doctoring_event_meds.cost`.** Deliberately deferred, not
  missed. These cannot be closed with a policy: all three app roles share the
  `authenticated` DB role, so column grants cannot tell them apart, and
  revoking `medications` outright breaks doctoring entry in the field app.
  Closing them needs dollar-free views for crew to read instead, plus a
  field-app test pass.
- **`net_weight_lb` is the PAY WEIGHT and the only weight anything reads**
  (2026-09-11, from John: *"47-26 has a sale with weights entered but office
  app and Claude review says no sales weight entered? Where is missing
  link"*). `lot_realized_adg_internal()` filters `WHERE s.net_weight_lb > 0`
  with **no fallback to gross**, and the `per_lb` cost-of-gain true-up reads
  what it returns. The lot's Sales table meanwhile prints `net || gross`. So a
  sale typed with a gross and no net looks complete on the screen a person
  reads and weighs NOTHING to every number built on the scale ticket. Eight
  live rows were in that state — 47-26's only sale among them, which is why
  that lot alone read as total absence (`head_sold_with_weight = 0`).
  **No gross fallback was added**: gross is heavier than pay weight by the
  shrink, so a fallback books the shrink as gain on every lot, silently and in
  the flattering direction. Migration
  `docs/sql/2026-09-11_sale_pay_weight_backfill.sql` copies gross → net **only
  where the money proves the figure is a pay weight** —
  `round(total_price / gross_weight_lb * 100, 2) = price_per_cwt`, because a
  buyer settles on pay weight and never on the scale gross. Applied
  2026-09-11: 8 sales rows, 8 `sale_sources.pay_weight_lb`, no dollars moved
  (`total_price` untouched). 47-26 went from no realized ADG to 178 hd @ 1.541
  lb/day; 31-26 1.879 → 1.904, 37X 1.473 → 1.515, 37X-1 1.652 → 1.793.
  The one row with NO weight at all (37X-1, 2026-06-04, 2 hd, priced per head)
  is left alone — there is nothing to recover — and shows on Anomalies.
- **Close Lot refuses while any sale has no pay weight** (2026-09-11,
  `closeLotGuard()`, docs/cog-design-decisions.md §3), on all four close
  paths (the kebab button, the 0-head prompts after a death and a sale,
  and the shipment save's empty-lot offer). The dialog lists the sales and
  offers to mark them `[no scale ticket] YYYY-MM-DD` in `sales.notes` — a
  recorded decision that the estimate stands, the same note-marker
  convention as `[counted …]`. A marked sale drops out of the closeout's
  unweighed count and the `sale_no_pay_weight` anomaly.
- **Three guards now stop it recurring.** The sale form warns live under the
  weight boxes while Net is blank; on save it offers to book the gross as the
  pay weight when the money ties on it, and otherwise makes you confirm past a
  sentence saying the sale will count as no weight. The Anomalies report
  carries `sale_no_pay_weight` (medium open / low closed). And the Sales tab's
  Realized ADG card now leads with NET and says how many sold head carry no
  pay weight — it used to average on `gross || net`, so it could print a
  healthy ADG beside a lot tile showing a dash with nothing explaining why.
  **That contradiction is what the original question was.**
- Test lots (`TEST_` / `TEST-`) are excluded from the shipment entry
  inventory.
- The buyer's own lines are TRUCKLOADS. Mapping loads to lots and pastures is
  entirely our side; `shipment_loads` exists only so the app can catch a
  transposed weight at entry instead of in closeout six months later.
- `shipment_reconciliation` (view) answers "does this STILL tie", which is a
  different question from the save-time check — it catches later edits to an
  allocated sale. Non-zero variance shows as ⚠ on the Sales list.

### Accounting report (Sales → Accounting Report)

One shipment, one row per (lot, pasture), in Redwing's column order:
Account · Quantity 1 (head) · Quantity 2 (pay weight) · Quantity 1 Price ·
UOM 1 · Amount · Notation · Distribution · Profit Center · Production Center ·
Production Year · Production Center. Two columns really are both called
Production Center — the first is blank, the last carries the lot.

- **The report reads `sale_sources`, it does not recompute.** A report that
  re-derived the split could drift from the books it is meant to document.
  The tie-out line checks the rows against the shipment header on every
  render and refuses to look clean if they disagree.
- **Days collapse here, not in the books.** The app writes one `sales` row per
  lot PER DAY so head-days stay honest; accounting wants the shipment as a
  single posting, so the report rolls the days up.
- **Amount is `book_proceeds`** — the draft less any freight JFR paid — not
  the gross and not `net_amount`.
- Production Center prints the lot number as the app holds it (`37X-1`), not
  Redwing's collapsed code (`37-X`). John's call, 2026-08-26: better to print
  what we know than to guess a mapping.
- Account / Profit Center / Production Year are editable and remembered in
  `localStorage` (wrapped in try/catch — storage throws outright in a private
  window rather than returning empty).
- Print is landscape (twelve columns will not fit portrait), PDF goes through
  the existing `sharePdfFile()` share-or-download path, and "Copy rows" puts
  tab-separated text on the clipboard, which is what actually saves the typing.

Migrations, in order: `docs/sql/2026-08-26_shipments.sql`,
`..._phase2.sql`, `..._phase3.sql`.

## Doctoring & Deaths report: the comparison (rebuilt 2026-09-07)

Reports → Health → Doctoring & Deaths. Migration:
`docs/sql/2026-09-07_doctoring_report_dimensions.sql`, which adds
`receiving_protocol_id` / `receiving_protocol_name` / `med_ids` / `med_names`
to `get_doctoring_analytics` and the two protocol columns to
`get_lot_deaths_with_arrival`. Neither function's ARGUMENT list changed, so
PostgREST still resolves one function per name; the return type widened, so
both are DROP + CREATE rather than CREATE OR REPLACE.

- **Filters decide what is counted; `Compare by` decides how it is split.**
  One table answers "which processing protocol", "which drug" and "1st vs 2nd
  pull" — they are the same question asked three ways, not three screens.
  Changing the dimension repaints from cached rows; it does not re-query.
- **There are two table shapes, and confusing them is the trap.** A COHORT
  dimension (receiving protocol, lot) partitions the herd — every head is in
  exactly one group, so head in, pull rate and mortality mean something. An
  EVENT dimension (regimen, medication, action, pull number) groups
  TREATMENTS, an animal can land in several groups, and there is no herd
  denominator. Only cohort tables carry Head in / Pull % / Mortality %.
- **Head in for a protocol comes off the delivery receipts**, which is the
  only place a protocol is recorded — the same denominator the Receiving
  report prints "per head processed" against. Head in for a lot is the lot's
  own `head_in`. The two totals differ when receipts do not cover a lot: 37X
  has ONE 8-head receipt against 369 head in, and those 361 head appear under
  `— no load record for the tag —` with no head in at all.
- **`Avg DOF` is the honesty column, and it is suppressed rather than
  guessed.** Head-weighted days from arrival to today (or to the lot's
  close), computed off the receipts. A young cohort with a flattering pull
  rate is the whole reason it is there — Macrosyn read 7.2% pulled against
  Draxxin's 18.9%, but at 15 days on feed against 24. Below **80% receipt
  coverage of head in** it prints nothing: 37X's single receipt would
  otherwise have read "4 days on feed" for cattle that landed in January.
- **A pull with no protocol splits three ways, not one.** `— no receiving
  protocol —` (the load was entered, it carried no protocol: the coverage
  gap), `— no load record for the tag —` (paperwork missing), and
  `— untagged death —` (a bulk death, never traceable to a load). Lumping
  them made the paperwork gap look four times its real size — 118 rows where
  the honest number was 6.
- **Repull and failure are measured PER TREATMENT, not per animal.** "Did
  this treatment hold?" is a question about the treatment: a later pull means
  it did not (`!is_last_pull`), and `is_last_pull && animal_died` is the
  treatment that was the last thing tried. An animal treated twice is two
  data points, which is what it is.
- **Med regimen beats medication.** Enroflox and Excede are given together on
  850 of 1,148 pulls, so comparing them as separate drugs compares the same
  cattle to themselves. The regimen dimension is the de-facto pull protocol:
  `Enroflox(Baytril) + Excede` is 1st pull, `Resflor` is 2nd. `med_names` is
  aggregated **ordered by name** in SQL so the same two drugs entered in
  either order key to one regimen.
- **The `med` dimension deliberately has NO total row.** A pull counts under
  every drug it included, so its treatments sum exceeds the event count. A
  total there would read as a bug.
- **Confounding is real and the screen says so.** Resflor shows 15% fail
  against Enroflox+Excede's 2%, because Resflor is the salvage drug given to
  cattle that already failed once. Set **Pull position = 1st pull only**
  before reading regimens against each other; the note above the table says
  exactly that.
- **Total rows recompute every rate from the totals**, never by averaging the
  group rates — that would weight a 25-head load like a 500-head one.
- **Five stat cards became a KPI strip plus two.** The pull funnel and "death
  rate by treatment count" were the same axis split across two tables;
  "death summary" and "death timing" were both about deaths. Nothing was
  dropped, and the funnel gained *Stopped here* — animals whose LAST pull was
  that one, which is the denominator a death rate per pull actually needs.
- **Test lots are excluded from the default set, not just from the picker.**
  The picker already hid them; "nothing picked = all lots" did not, so
  TEST_DOC1 and TEST_DOC2 sat in the comparison.
- **`renderDoctoringTable` was declared TWICE at top level** — this report's
  and the lot-detail screen's, in the same scope. Hoisting meant the lot
  version won, so the report drew into the LOT's container while its own
  Event detail sat on "Loading…". The report's is now
  `renderDocEventTable`. A duplicate function declaration is legal JS and
  throws nothing; only a unique name catches it. `ceilTo` was the same shape
  — two identical top-level bodies, harmless only by luck — and the shadowed
  copy was deleted the same day. There are now **no duplicate top-level
  function names in index.html**; keep it that way.
- **The app degrades rather than breaking before the migration lands.** The
  new columns' absence is detected on the first row; the three dimensions
  that need them explain what to run, the two filters that need them warn
  that they were not applied, and everything else works.

## Head-count tie-out (D8, live 2026-09-27)

`lot_head_tieout` (view, `docs/sql/2026-09-27_lot_head_tieout.sql`): one row
per open non-test lot, feed pen included. `status` is TIES/OFF on
`lot_status.head_current` vs the sum of open `lot_pasture_assignments`, which
is the head-math invariant. `tag_flag` compares `count(lot_tags)` (any status)
to `head_in` and is informational only: 37X (tags on 72 of 369) and 37X-F
(+1) flag on day one and still TIE. Shown as the "Head count: X of Y lots
tie" tile above the Lots list (the app's landing screen; there is no separate
Home tab), green / red, opening a table with OFF first and tag-flagged lot
numbers bold. SELECT to authenticated only.

## Tag retirement on death and sale (live 2026-09-27)

`docs/sql/2026-09-27b_tag_retirement_death_sale.sql`. John's rule: retire a
tag when the animal dies or sells, if the tag is known. Two AFTER triggers,
SECURITY INVOKER with a pinned `search_path`, so every entry path is covered
(office app, approvals, RPCs, SQL):

- `lot_events` death with a numeric `tag_number` → that lot's `lot_tags` row
  goes `retired`, `retired_reason = 'Died <event_date>'`.
- `sales` with BOTH `tag_start` and `tag_end` → every tag in the range for
  the lot except `missing_tags`, `'Sold <sale_date>'`.
- Only `status = 'active'` rows are retired. Delete, or a change to the
  tag / lot / date / range, puts the old tags back to `active` — only those
  whose reason starts `Died` / `Sold`, and not one another death or sale in
  the same lot still accounts for. A lot-close or hand retirement is never
  undone.
- INVOKER is enough because only owner/office can write `lot_events` and
  `sales`, the same roles `lot_tags_update` allows.
- Backfill retired 27 active tags matching recorded deaths (marker
  `[tag retirement backfill 2026-09-27]` in `lot_tags.notes`). No sale
  carried a tag range. Two 37X deaths name tags with no `lot_tags` row
  (2025-12-18 tag 4331, 2026-01-05 tag 4379) — reported, not fixed.

## Withdrawal warning (live 2026-09-27)

`withdrawal_holds` (view, `docs/sql/2026-09-27d_withdrawal_holds.sql`,
security_invoker, no anon): one row per (lot, tag) still inside a slaughter
withdrawal from DOCTORING — treat day (Chicago) + `medications.withdrawal_days`,
kept while the clear date is after `ranch_today()`; several drugs → the latest
clear date. Meds with 0/NULL days and free-text meds are skipped. Processing
meds at receiving are NOT included (open question).

- The single-lot sale form (new sales) and the shipment save call
  `withdrawalConfirm()`: holds clearing AFTER the ship date are listed (tag,
  drug, treated, clears) and **Confirm saves anyway — it warns, never
  blocks.** A shipment lot is checked at its first load day. A failed read
  asks rather than passing as clear.
- **"Load out" in this app is the ARRIVAL receipt**, so the warning is on
  the two screens cattle LEAVE through, not on the load-out form.
- Approvals shows "clears <date>" beside every drug with a withdrawal.
- `doctoring_events.drug_off` is carcass disposal, not withdrawal. Never
  read it here.
- Harness: `scripts/withdrawal-harness/run.js`.

## Health curves: pull / re-pull / death baselines (live 2026-09-25)

Migration `docs/sql/2026-09-25_health_curves.sql`; every rule and the
verification in `docs/health-curves.md`. Reports → Health ▾ → **Health
Curves** and **Death Capture**; lot page → Animal Health → **Health vs
baseline** card. All arithmetic is in the views; the screens only lay out.

- **Class and season are per LOT** (head-weighted invoice weight, head-weighted
  arrival). Bands are half-open `[min_lb, max_lb)` — 650.73 lb is 551–650. A
  lot whose loads straddle a band or a season is flagged and sits where the
  rule puts it until John sets `lot_health_overrides` (owner, reason
  required). 60X and 36-27 were flagged on day one.
- **Day on ranch is per head** (event date in Chicago − that head's receipt
  date); an untagged death takes the lot's weighted arrival. First pull = a
  tag's first doctoring DAY; same-day repeats count once. Pulls join on
  `lot_id` + tag — tags recycle.
- **Incidence per head received**: a head counts toward day d once it has
  reached d; dead and sold head stay in the denominator.
- **A lot is never part of its own baseline.** `lot_health_status` subtracts
  the lot's own counts from its cell, and scores each head at the day IT has
  reached (a lot still receiving is not read at one average day). Deltas and
  flags subtract the ROUNDED figures so a row adds up as printed.
- **Estimates are stored at the checkpoints and interpolated.** Seeded from
  the nearest OTHER measured cell (never the cell itself), edited by John
  through `set_health_estimate()`, which supersedes rather than overwrites.
  **Estimate rows are never deleted** — no DELETE policy, no grant. Measured
  data replaces an estimate day by day.
- **Shorts are not deaths.** Cause `missing from shipping` or a `missing`
  adjustment: on no curve, counted on the capture line and in loss % of head
  at close only.
- **37X is on ESTIMATED loads** (`health_estimated_loads`, 361 hd assigned by
  tag order to its three invoices). Delete those rows and it drops out with
  its reason on `health_excluded_lots`. The general rule excludes a lot whose
  receipt head is under 80% of invoice head.
- Flag thresholds (`health_flag_thresholds`, points above baseline) are
  blank until John sets them; `health_exceptions` is the Position Desk hook
  and is empty until then.
- Reads go through `can_read_operational()` (crew included — no dollars);
  every write is owner only.
- **Time a new view as a real login, not as postgres.** The curves ran in
  0.4 s in the SQL editor and 21 s through the app, because every base
  table's SELECT policy calls its role check per row and the curves read the
  same tables several times. The base sets now come through four DEFINER
  functions that gate once per call (`docs/sql/2026-09-25b_health_curves_speed.sql`);
  a per-row LATERAL or sub-select into an RLS table is the same trap.
  Test with `set_config('request.jwt.claims', …)` + `set local role
  authenticated` — but the MCP session is `postgres`, so a gate that trusts a
  non-API `session_user` will pass there; check the gate itself on scratch
  as `authenticator`.

## The feed pen (built 2026-09-07)

Cripples, chronics and anything else with little value left. Migration
`docs/sql/2026-09-07_feed_pen.sql`; every decision and the rejected
alternatives in `docs/feed-pen-design.md`. Office+owner; the pen carries
dollars so it reads through `can_read_books()`.

```
lot (is_feed_pen) ← lot_transfers kind='feed_pen', basis $0 ← the source lot
      │                        │
      │                        └─▶ feed_pen_ledger (which lot each head came off)
      ├── feed + doctoring accrue on the pen like any lot
      └─▶ feed_pen_removals ── sold | butchered | died | missing
```

- **The pen is a LOT, not a cost centre and not a new object.** Head math,
  head-day feed spreading and doctoring are each implemented once and keyed
  on `lot_id`. A `cost_centers` row is deliberately the ABSENCE of a lot —
  `lot_feed_daily` and `feed_cost_unallocated` read `destination_type='lot'`
  only — so it can hold no head, no deaths and no sales.
- **Cattle enter at a $0 basis and the source lot keeps every dollar.** The
  two `lot_transfers` basis CHECKs relaxed from `> 0` to `>= 0`, and zero is
  still refused for `fold_in`/`sort`. `record_lot_transfer` also refuses a
  MISMATCH between the kind and the two lots: a pen move typed as a 'sort'
  would carry the source lot's whole at-cost basis in, silently, because
  both are valid transfers.
- **The source lot's cost per surviving head goes UP when a chronic leaves,
  and that is the honest read** — the money was spent on cattle that will not
  pay it back. Its closeout says so on the transferred-out row.
- **`lot_daily_head` gained a THIRD start-date term: the lot's first
  `transfer_in`.** A pen has no receipt and no invoice, so without it the pen
  has no rows at all — no head-days, so no feed can spread to it and every
  pound lands in `feed_cost_unallocated`. It is a no-op for every ordinary
  lot because `record_lot_transfer` already refuses a transfer dated before
  the destination's first arrival, and the migration PROVES that (one lot on
  the place carries a transfer_in; its bound does not move) rather than
  assuming it. `CREATE OR REPLACE`, never DROP CASCADE — a cascade takes
  `lot_feed_daily`, `lot_feed_costs`, `feed_cost_unallocated`,
  `lot_head_days_by_month`, `pasture_feed_allocation` and the feed truck
  tie-outs with it, and can silently drop `security_invoker` on the rebuild.
- **The pen keeps its OWN books** — salvage against feed and medicine —
  and that net posts to Redwing at year end. **Cost by source lot is
  TRACKED, never charged back.** John, 2026-09-07: *"the source lot might be
  closed by time feed pen calf is cleaned up."* Charging it would also
  double-charge the same head, which already took its whole loss at
  transfer.
- **One pen per fiscal year** (partial unique index on `fiscal_year WHERE
  is_feed_pen`). Date it **1 July** — `close_feed_pen_year` dates the
  rollover 1 July and refuses a destination pen that did not exist yet, for
  the same clamping reason as above. At year end the pen closes, the net
  posts, remaining head roll forward at $0 and **cost restarts at zero**.
- **The rollover writes the ledger rows itself, and that is why
  `feed_pen_ledger` is a table.** A rollover transfer's `source_lot_id` is
  the OLD PEN, so derived from `lot_transfers` alone every animal would read
  as having come off `FEEDPEN-26` and the lot it actually left would be
  lost. Ordinary pen transfers get their ledger row from a trigger, so a
  later caller cannot forget it.
- **Butchered and missing are negative `adjustment` events with a `cause`,
  not new event types.** `adjustment` is already signed and already summed
  by both `lot_status` and `lot_daily_head`; two new types would mean
  teaching the two views every dollar in the app is built on. And filing
  either as a death puts it in the mortality rate, the death-timing card and
  the pull-failure denominators of the Doctoring & Deaths report.
  **Butchered carries no value** (John's call): it is a disposal, not a sale.
- **`record_feed_pen_removal` freezes the pen cost BEFORE writing any head
  math.** The cost views read `lot_daily_head`, which reads the very
  `lot_events`/`sales` row the function is about to insert — compute after
  and the figure frozen against the source lot is short by the head's last
  day. Each source lot has a POOL (accrued to date less already frozen) and
  a removal draws its share by head, so the frozen figures can never exceed
  what the pen actually spent.
- **Removals cannot be edited, only deleted and re-entered.** The reversal
  reopens an assignment the removal closed outright rather than adding head
  on top of it — the `delete_death_event` trap.
- **A pen death does NOT count against the source lot's mortality**, because
  the animal left that lot as a `transfer_out` before it died. A lot that
  uses the pen therefore reads a better death rate than it earned. Nothing
  can fix that in the lot's own numbers without double-counting the head, so
  the pen report carries deaths by source lot and the closeout says so.
- **A pen exit recorded outside Record removal captures itself** (closed
  2026-09-07, `docs/sql/2026-09-07c_feed_pen_gaps.sql`). A **BEFORE INSERT**
  trigger on `lot_events` (deaths) and `sales` writes the removal, the
  pro-rata split and the ledger rows. BEFORE, not AFTER: the frozen cost has
  to be computed while the exit is still invisible to `lot_daily_head`, or it
  is short by the head's last day. The pool drawdown and salvage split live in
  `feed_pen_freeze_costs` / `feed_pen_allocate_proceeds` / `feed_pen_split_head`
  so the trigger and the RPC run ONE implementation. `record_feed_pen_removal`
  sets `jfr.feed_pen_capture = 'off'` (transaction-local) so its own head math
  is not captured twice. It never blocks an entry — no source lot standing
  raises a WARNING and lets the animal be recorded, and
  `feed_pen_reconciliation` still catches it. An auto-captured removal is
  flagged `captured_automatically` and `delete_feed_pen_removal` REFUSES it:
  it never touched the pasture assignment, so reversing the death or sale is
  what puts the head back, and an AFTER DELETE trigger drops the attribution.
  **The removals list must therefore NOT offer Delete on a captured row** — it
  says "captured automatically" and points at where the death or sale was
  entered instead. A Delete there is a button that can only ever produce an
  error.
- **Head found in the pen and carried nowhere go in through
  `record_feed_pen_opening`** — a positive `adjustment` (never a receipt or
  invoice, which would give the pen a `head_in` and a purchase cost it never
  had), a pasture assignment and an `opening` ledger row. `lot_daily_head`
  gained a FOURTH start-date term for it, the pen's own `arrival_date`, gated
  on `is_feed_pen`: an adjustment is not a start-date source, so a pen holding
  only found head would otherwise have no window and no head-days at all.
  **The source lot is OPTIONAL** (John, 2026-09-07: *"They literally don't
  come from a lot, I didn't enter them because there wasn't a feed pen lot at
  that time."*). `feed_pen_ledger.source_lot_id` and
  `feed_pen_removal_lines.source_lot_id` are nullable and NULL is its own
  group, `— no source lot —`, the way the Doctoring report separates its three
  kinds of missing paperwork instead of lumping them. Forcing a lot onto head
  with no origin would invent a fact. **Every join on `source_lot_id` uses
  `IS NOT DISTINCT FROM`, never `=`** — `NULL = NULL` is not true, so `=`
  drops the unattributed group silently out of a report that is supposed to
  add up. Line uniqueness is a `NULLS NOT DISTINCT` index (PG15+; this
  database runs 17.6) so one removal cannot collect several unattributed
  lines. Naming a lot when you DO know is still worth it and is cheap to be
  wrong: pen cost is tracked, not charged, so it touches that lot's books in
  no way. Entered from **+ Found in the pen** on the pen's own page; the lot
  picker keeps CLOSED lots on the list, because the lot found head came off is
  very often finished, and defaults to no source lot.
- **The year-end net posts through Redwing posting on the pen's page**
  (2026-09-10): two lines, equal and opposite, clearing the pen's production
  centre onto wherever the result is coded. **Feed, medicine and salvage are
  NOT lines on it** — those dollars already reached Redwing on their own
  invoices and cheques, and posting them again double-counts. It reuses
  `acctPostingCells` with the transfer posting rather than a third copy of
  the twelve columns, and its print sheet and PDF are scraped from what is on
  screen, so nothing can drift from what you are looking at.
- **Pens are NOT fixed and pen entry is office-only** (John, 2026-09-10:
  "Not set pens for feed pen cattle could be in various spots" / "Feed pen has
  to be done in office for now"). Nothing gets a default pasture; the pen
  routinely stands in several at once. Crew see the pen as an ordinary lot for
  doctoring and moves, but sending cattle to it, taking them out and entering
  found head are all office.
- The pen is excluded from the Active Lots report (no invoice, so cost in,
  weight in and break-even are all empty by design) and its lot page hides
  Purchases and Closeout, showing the Feed pen section instead.
  `is_feed_pen` is settable on a NEW lot only.

## Strays and missing head (built 2026-09-07, applied 2026-09-10)

**Live.** Applied through the MCP connector's `apply_migration`, verified
byte-exact against the file by `md5(prosrc)`, and smoke-tested on the live
schema inside a DO block that raised at the end so every write rolled back:
59X wrote off 2 head (pasture 3 → 1, `head_current` 3 → 1, **`head_dead`
unmoved at 4**), the reversal restored both exactly, and a closed lot refused
a stray return. Zero residue afterwards.

Migration `docs/sql/2026-09-07d_strays_and_missing.sql`; every decision and the
rejected alternatives in `docs/stray-cattle-design.md`. From John's question:
cattle come back that were killed off, or that have been gone so long the lot
has closed.

```
missing out   -> negative adjustment, cause 'missing'        (record_missing_head)
stray back in -> positive adjustment, cause 'stray_return'   (record_stray_return)
lot closed    -> the FEED PEN at $0, entry_kind 'stray'      (record_feed_pen_opening)
either one    -> delete_head_adjustment
```

- **Head you cannot find are NOT a death.** Lot 47-26 was closed 2026-09-03 by
  writing 2 head off as a death, cause `missing from shipping`. Nothing died,
  and that row sits in the lot's mortality rate (8/187 rather than 6/187), the
  death-timing card and the pull-failure denominators of the Doctoring & Deaths
  report — none of which read `cause`; they count `head_dead`. This is the feed
  pen's own butchered/missing ruling reaching ordinary lots. **No new
  `event_type`**: `adjustment` is already signed and already summed by
  `lot_status.head_current` and `lot_daily_head`.
- **A stray comes back on the day it was FOUND, at $0** — never by deleting the
  write-off, once any time has passed. `lot_daily_head` would hand the lot every
  head-day back to the write-off date and silently re-price feed, cost of gain,
  labor and treatment on every day since, for an animal nobody was feeding.
  Deleting is right only for an entry that was simply wrong and is fresh; the
  reversal's confirm text says which is which and names the other button.
- **A CLOSED lot is never re-opened for a stray.** `lot_daily_head` ends a lot
  at `LEAST(closed_at, ranch_today())`, so re-opening un-finalises a reported
  fiscal year. Both closed lots are FY 2026, which is the common case for a
  stray, not an edge case. It goes in the **feed pen at $0** naming the closed
  lot — pen cost is TRACKED, never charged back, so that lot's books are
  untouched. A `STRAY-27` lot per year was rejected as a second copy of the
  pen's machinery for a handful of head; hanging it on a current-year lot was
  rejected because it contaminates a real cohort's mortality and per-head cost.
- **`feed_pen_ledger.entry_kind` gained `'stray'`**, distinct from `'opening'`
  (found in the pen, never carried anywhere). Same lesson as the Doctoring
  report's three kinds of missing paperwork. `record_feed_pen_opening` gained
  `p_entry_kind` and was **DROPped and recreated, not overloaded**, and the
  migration drops BOTH signatures — dropping only the old one made the file fail
  its own idempotency test.
- **`feed_pen_ledger.opening_event_id` cascades from `lot_events`**, so
  reversing an opening cannot leave the attribution ledger holding head the head
  math no longer carries. The backfill links only where exactly one candidate
  event matches.
- **`delete_head_adjustment` is one reversal for all three**, and both
  directions carry a trap. Negative (head come back): reopen a closed assignment
  with EXACTLY the head returning, never adding to the stale stored count — the
  `delete_death_event` bug. Positive (head leave again): REFUSE when the
  assignment no longer holds them, rather than taking a count negative and
  creating drift that surfaces days later. A pen's butchered/missing rows are
  the tail of a removal and are not reversible from this card.
- **The closeout carries a `Missing` line, carved OUT of Cattle in** exactly as
  death loss is, so Cattle in + Death loss + Missing still sum to the invoices
  and total cost is unchanged. `survivingHead` drops the missing head. Strays
  back net the line down and flip it to **Strays back** when more come back than
  were written off. **Nothing projects forward** — nobody assumes a rate of
  going missing the way they assume a death rate.
- Two Anomalies findings: **head written off as missing on a lot still open**
  (medium inside 90 days), and **a death whose cause reads as unaccounted-for**
  (medium open / low closed — flagged on closed lots too, because it is
  inflating that lot's death rate now and is still a correction to approve).
- **Reclassifying 47-26 is offered, not run.** The `UPDATE` is commented at the
  foot of the migration; it rewrites a reported prior year and needs John's
  explicit say-so. `head_count` stays `-2` — `lot_status` subtracts a death's
  absolute value and ADDS an adjustment's signed value, so `head_current` lands
  in the same place.
- **The pen's entry form is "+ Found in the pen"**, built the same day by a
  parallel session (2026-09-10) and kept in the merge; a second copy of it
  written here was dropped, because two `fpoSave` declarations in one scope is
  the `renderDoctoringTable` bug exactly. **It does not yet pass
  `p_entry_kind`**, so a stray recovered off a closed lot currently records as
  `'opening'` rather than `'stray'`. The database tells them apart; the screen
  does not yet. Adding the selector is one field — see OPEN-ITEMS.

## Projected weight: the anchor (rebuilt 2026-09-10)

`lot_projected_weight()` used to ignore every weight taken after purchase —
invoice average plus days-since-arrival times `target_adg`, forever. It now
starts from an ANCHOR and walks forward. Migration:
`docs/sql/2026-09-10_lot_weight_anchor.sql`.

```
lot_weight_anchor (view)  ──▶ lot_projected_weight_detail()  ──▶ lot_projected_weight()
  newest whole-lot weight        the day-by-day walk               thin wrapper
  else the purchase weight       + provenance                      (scalar, unchanged signature)
```

- **`lot_projected_weight_detail()` is the implementation and the scalar
  function is a wrapper over it.** Two copies of this arithmetic would
  become the `lot_head_days` trap — a function and a view that disagree by
  29% and nobody notices for months. One body, two entry points.
- **Anchor precedence: newest whole-lot weighing, else the purchase
  weight.** A **sale weight is never an anchor** for the head still
  standing — those are the cattle that LEFT. A CHECK makes
  `coverage='whole_lot'` with `weight_type` of `sale` or `individual`
  unrepresentable, and the view's WHERE repeats the rule where it is relied
  on.
- **Several scale drafts sharing a `weigh_session_id` are ONE anchor.**
  Weighing 585 head in six drags is one weighing, so the drafts are summed
  back up before the newest is picked; otherwise the last drag off the
  trailer would become the lot's average weight.
- **Phase day-numbers are measured from the WEIGHTED ARRIVAL DATE, not from
  the anchor.** `lot_adg_phases` describes a lot's life from when the cattle
  landed — a receiving phase is the first ten days on the place. Measuring
  from the anchor would restart the receiving slump every time the lot was
  weighed. Days no phase covers fall back to `lots.target_adg`; a NULL
  `target_adg` is 0, as before.
- **`adg_used` is the BLENDED rate actually applied**, so
  `anchor_avg + adg_used × days_since_anchor` always reproduces the number.
  `adg_source` is `'phase'` if any day in the walk drew from a phase.
- **`lot_weight_anchor` returns one row per lot ALWAYS**, with NULL anchor
  columns where a lot has neither invoices nor a whole-lot weight
  (FEEDPEN-27 is the live case). A dashboard can then show "no anchor"
  rather than silently dropping the lot. The function returns NO ROW for
  those, which is what makes the scalar return NULL.
- **The anchor's own `head` is the INVOICE head, not `head_in`.** On 36-27
  that is 562 against a `head_in` of 585, because the receipts run ahead of
  the invoices. That is the old function's denominator unchanged; do not
  "fix" it here without moving `avg_weight_in` on `lot_status` with it.
- **`lot_weight_anchor` counts days on `ranch_today()`; `lot_status`
  counts them on `CURRENT_DATE`.** Deliberate, and the reason is worth
  keeping: `lot_status` is uniformly CURRENT_DATE already
  (`projected_current_weight`, `days_on_feed`,
  `days_since_weighted_arrival`), and a single ranch-day column dropped into
  a UTC-day view is worse than either — `days_since_anchor` would read one
  day behind the projection printed beside it every evening Central, so a
  dashboard dividing the gain by the days would read DOUBLE the real ADG for
  those hours, silently. Moving the whole view onto `ranch_today()` moves
  `projected_current_weight` with it and is its own migration.
- **Nothing in the books moved when this landed, and the migration proves
  it rather than claiming it.** It snapshots
  `lot_status.projected_current_weight` for every lot into a temp table
  before the rewrite and raises if any lot differs afterwards by so much as
  the last decimal place. With `weights` and `lot_adg_phases` empty the two
  formulas are arithmetically identical; all 12 lots verified 2026-09-10.

### The rate correction: the projection uses the lot's OWN realized ADG

Migration `docs/sql/2026-09-10_realized_adg_projection.sql`. Design record and
the unbuilt half: `docs/weight-estimation-design.md`.

John, 2026-09-10: *"we don't weigh a lot of cattle … since we shipped
yesterday I have good estimates on some cattle."* There are **two** corrections
and the anchor work only did one:

| | fixes | needs | how often |
|---|---|---|---|
| **Level** | "these weigh X today" | a scale | rare |
| **Rate** | "this lot gains Y, not what we assumed" | nothing | every sale |

- **The rate correction is free and the books were throwing it away.**
  `lot_realized_adg` has computed gain off real pay weights since the `per_lb`
  COG work; the projection never read it. **37X shipped 283 head at a realized
  1.473 while its remaining 32 head were carried at the assumed 1.80 — 910.7 lb
  against 822.6. Eighty-eight pounds a head**, straight into break-even.
- **Precedence is phases → realized → assumed.** A hand-entered
  `lot_adg_phases` curve is a deliberate statement and still wins the days it
  covers; the measured rate beats the guess; the guess is where every lot
  starts. `adg_source` reports which: `phase | realized | realized_thin |
  assumed`.
- **The gates are on the SAMPLE, never on the answer**
  (`lot_realized_adg_confidence`): at least 20 head with a real pay weight AND
  at least 10% of head in, or the assumption stands. Under 30% it is used and
  flagged `realized_thin` — 37X-1 sits there at 66 head of 274.
- **`lot_realized_adg_confidence` reads `lot_realized_adg_internal()` and the
  head-in tables DIRECTLY, never `lot_status` or the `lot_realized_adg` view.**
  `lot_status` calls `lot_projected_weight_detail()`, which calls this, so
  going through `lot_status` makes the three mutually recursive — Postgres
  blows the stack (`54001`) rather than erroring usefully. Caught on the first
  apply.
- **Nothing booked moved.** Projected weight is an estimate; no cost, no head
  count, no frozen number. `per_lb` COG reads `lot_realized_adg` and
  `lots.target_adg` directly and never went through this function.
  **But it does move two things worth knowing:** break-even displays, and the
  weight-based DOSE suggestion in doctoring (which reads
  `projected_current_weight`). Both move toward the truth — if cattle are
  lighter than assumed, the old dose was too high — but they do move.
- **The verify block proves the blast radius rather than asserting it**: a lot
  still on `assumed` that moved raises, a lot that moved without a realized
  rate raises, a lot with nothing sold claiming a realized rate raises, and
  `anchor + adg_used × days` must reproduce the projection to the cent.
  Live result: 37X −88.1, 37X-1 −34.8, 59X +7.3, 37X-F +5.2, 60X +4.8;
  36-27 (nothing shipped) and every test lot unmoved.
- **The lot tile says which basis it is on** — *Now (1.47 ADG, measured)* —
  and `realized_thin` shows amber. A projection that silently changed basis
  when the first load shipped would be worse than either basis alone.
- **Shipped head are not a random sample.** You generally ship the best first,
  so realized ADG tends to OVERSTATE what the remnant is doing. The source is
  on screen so it can be discounted. There is no per-lot override yet; add one
  if a lot's shipped head are known to be unrepresentative.
- **37X's 1.473 was NOT a projection miss — read this before "fixing" the
  assumptions.** John, 2026-09-10: *"the 37X adg missed because we waited too
  long to ship and the cattle backed up. Not a projection miss and mgt miss by
  me due to a falling market and holding too long."* The 1.80 assumption was
  sound; the cattle were held past their window in a falling market and the
  gain flattened at the end. **A realized ADG under the assumption is
  therefore not evidence the assumption was wrong** — it is a question, and
  "held too long" and "assumed too high" produce the identical number. Do not
  quietly walk `lots.target_adg` down to chase a realized figure without
  asking which one happened; that would bake a marketing decision into the
  standing assumption for every lot that follows.
- **A blended realized ADG hides the CURVE, and that is the real limitation
  here.** 37X did not gain 1.473 all year — it gained near the assumption and
  then went flat. One rate over the whole span understates it mid-life and is
  right only for the remnant, which happens to be what the projection needs.
  `lot_adg_phases` is the tool for saying so explicitly (it already outranks
  the realized rate), and a lot known to have backed up is exactly the case
  worth entering phases for.
- **A pasture weighing is now VISIBLE, as a note** (John, 2026-09-10: *"stand
  visible at least as a note … the time this matters is in the growyard phase
  and cattle when we get closer to shipping to have an accurate weight because
  different pastures perform differently some years"*). View
  `lot_pasture_weights`, migration
  `docs/sql/2026-09-10_lot_pasture_weights.sql`, shown as a **Last weighed**
  column on the lot's Currently in table.
  - **It is a NOTE, never an anchor.** It moves no projection, no cost and no
    head; `applies_to='pasture'` still anchors nothing. Proven in the
    migration and re-proven live: a 76-head weighing on 36-27's pasture 3 read
    465.6 lb booked, +38.0 against the lot's 427.6, and
    `projected_current_weight` stayed 427.55 on `assumed` throughout.
  - **John's answer is what makes this safe where a general per-pasture anchor
    was not.** The horizon is SHORT — a weighing a fortnight before shipping
    has no months in which to drift onto the wrong animals — and near shipping
    the PASTURE number is the one that gets used, because trucks load off
    pastures. The lot average is a closeout figure.
  - **`head_changed` and `moved_in_since` are the honesty of it.** A weighing
    describes the ANIMALS that were on the scale, so the moment head come or
    go it is describing a group that no longer stands there. The column goes
    amber and says which — *"weighed 60 hd, 76 here now"* or *"cattle moved in
    since"* — rather than letting a stale number read as current.
- **SUPERSEDED 2026-10-01: a pasture weighing is now that pasture's weight,
  and it moves with the cattle** (John: *"the weight in the new pasture is
  that weight"*). Function `lot_pasture_weight_detail(lot)`, migration
  `docs/sql/2026-10-01_pasture_weight_estimates.sql`; full record at the end
  of `docs/weight-estimation-design.md`. The *Last weighed* column above is
  replaced by a **Weight** column and a **Pasture weighings** table, and the
  lot tile gains a **Scaled** line under *Now*.
  - **25% of the head in the pasture qualifies a weighing.** Under that it is
    a note, as before.
  - **Display only.** `lot_projected_weight()` and `lot_status` are
    untouched, so cost of gain, the closeout, break-even, the PB feed plan
    and the dose suggestion stay on the book until John says otherwise.
  - **A read-only replay, nothing stored:** each head carries an offset from
    the book, a weighing sets its pasture's offset, a move carries it and
    blends by head. Pasture head is rebuilt backward from today through
    `lot_movements` (receipts never write it), so it is approximate where a
    death or sale happened since.

## Markets and hedge positions (built 2026-09-10)

The database held no price it had not paid itself. Migrations:
`docs/sql/2026-09-10_markets_and_positions.sql` and
`..._market_quotes_schedule.sql`. Edge function:
`supabase/functions/market-quotes-sync/`. Office+owner; it is all dollars,
so every SELECT reads through `can_read_books()`. Screen: **Sales →
Positions**.

```
market_quotes   ← market-quotes-sync (edge fn, daily 23:30 UTC)
positions ──┬── position_lot_links ── lots
            └─▶ hedge_coverage_by_month (view)
```

- **`positions` is ONE table for futures, options, LRP and forwards.** They
  all answer the same question — how many pounds, in which month, at what
  price — and the coverage view has to add them together. Four tables would
  be four joins and four chances to forget one. The cost is that most
  columns are nullable, so **the per-type CHECK constraints are the whole
  integrity story**: `positions_futures_fields`, `_option_fields`,
  `_lrp_fields`, `_forward_fields` each name what their kind cannot do
  without. The migration's verify block INSERTs a bad row of two kinds and
  raises if either is accepted — a constraint nobody has watched bite is
  decoration.
- **`option_type` is the one column added beyond the spec, and it had to
  be.** A long put and a long call are opposite exposures; without it an
  option cannot be scored as coverage at all.
- **`positions_quantified_check` closes the `SUM()`-ignores-NULL trap at
  the door.** An LRP or forward with no `total_lb` and no
  `head`+`lb_per_head` has no derivable pounds, so it would drop silently
  out of the coverage view and read as "not hedged" while the hedge sat
  right there. The app refuses it first with a sentence that says that,
  because a raw CHECK violation reads like a riddle.
- **Only protection counts as coverage: short futures, long puts, LRP,
  forward sales.** Long futures, short puts, calls and forward purchases do
  not put a floor under cattle we will sell. **Corn never counts** —
  `futures_contract_lb()` returns NULL for it (a corn contract is 5,000
  bushels, not pounds), so an input hedge cannot leak into cattle coverage
  even if someone files it wrong.
- **Futures and options bucket on `contract_month`; LRP and forwards on the
  month of `end_date`** — the month the protection actually covers.
- **`lb_expected` is NULL until a lot carries `target_ship_weight`, and no
  open lot carries one today.** Falling back to `projected_current_weight`
  was considered and refused: a projection of TODAY's weight is smaller
  than the sale weight, so it would OVERSTATE `pct_covered` — telling John
  he is better hedged than he is, which is the one direction that costs
  money. The view carries `lots_missing_ship_weight` instead and the screen
  prints *"no ship wt on 1 lot"* rather than a bare dash. Set the target
  ship weights and the percentage lights up with no code change.
- **`posPounds()` in the app mirrors the COALESCE in
  `hedge_coverage_by_month` exactly.** If those two ever disagree the screen
  is lying about coverage. Same for `POS_CONTRACT_LB` against
  `futures_contract_lb()`.
- **UNITS, and this is the `target_sale_cwt` trap again.** Every price —
  `settle`, `strike`, `entry_price`, `exit_price`, `coverage_price` — is
  stored AS QUOTED: cattle in US cents per pound, which is the same number
  as dollars per hundredweight. Corn is cents per bushel. **`premium` is
  the exception: dollars per HEAD**, because that is how an LRP endorsement
  is billed. Do not convert one without the other.

### Ingestion

- **The source is Yahoo's chart API, and what it gives is the session's
  CLOSE, not CME's official settlement** — settlements are a licensed
  product. The two are close enough for basis, and every row records
  `source` as `yahoo_chart:GFV26.CME` so nothing downstream can mistake one
  for the other. Swapping to true settlements later changes the fetcher and
  the source string; the row shape does not move.
- **Symbols are per LISTED contract month** (`GF`+month code+`yy`+`.CME`;
  live cattle `LE`, corn `ZC…CBT`). The month-code lists per product are
  not cosmetic — there is no December feeder contract and `GFZ26` 404s.
- **An expired contract 404s and is gone.** `GFH26` (March 2026) already
  does. So a backfill only reaches as far back as the contracts still on
  the board have traded — which is 2025-08 onward, comfortably before the
  first sale on the books (2026-04-20), but a contract that has rolled off
  cannot be recovered from this source.
- **A null close is skipped, never carried forward and never
  interpolated.** A guessed price would be indistinguishable from a real
  one three months later. If the whole source is unavailable the function
  writes NOTHING and returns 502 — a half-written curve is worse than
  yesterday's curve.
- **Idempotent by the unique key** `(quote_date, instrument,
  contract_month)`. Verified 2026-09-10: the backfill wrote 2,391 rows and
  an identical re-run left the count at 2,391. `settle` is updated rather
  than ignored, so a revised close corrects itself.
- **The daily job defaults to the last 8 DAYS, not just today.** It costs
  the same number of requests and it closes any gap a failed run or a
  holiday left, which a today-only job would leave open forever.
- **pg_cron and pg_net are now ENABLED** (they had been the blocker on the
  feed module's wave-3 7am email — that is unblocked as a side effect).
  The cron job authenticates to the edge function with the PUBLISHABLE key,
  the one already embedded in index.html. So the endpoint is not open, but
  anyone with that public key could trigger a run; the blast radius is a
  Yahoo fetch and an upsert of quotes, and nothing else is reachable.
  Tightening it means a shared secret set as an edge-function secret in the
  dashboard, which needs John.

### The screen

Sales gained a third sub-tab. ~15 rows a year, so it is deliberately a list
and a form — no bulk import, no wizard, no inline-edit grid.

- **`POS_FIELDS` decides what is on screen AND what is nulled on save**, so
  a position switched from futures to LRP cannot keep a stale
  `contract_month`. It mirrors the per-type CHECKs; the DB is the
  enforcement.
- **Lot links are rebuilt on save, not diffed** — there are two or three
  and a diff is more ways to be wrong. Same call the shipment deductions
  make.
- **The lot picker hides test lots but KEEPS closed ones**: a position can
  outlive the lot it covered.
- Three verification rows (a short futures, an LRP, a forward sale, all
  against 36-27 for March 2027) are in `positions` with
  `[VERIFICATION ROW 2026-09-10 …]` at the front of their notes. **They are
  not real hedges** — delete them once the screen has been looked at.


## Data-integrity architecture (do not bypass)

- Deaths, moves, sales, and receipt deletions go through atomic RPCs
  (`record_death_with_pasture`, `delete_death_event`,
  `record_move_with_pasture`, `delete_move_event`,
  `delete_receipt_with_reversal`, etc.) that keep pasture assignments in
  sync. NEVER raw-delete a receipt/death/sale/move from the app.
- **A reversal that reopens a closed assignment must not also add head back.**
  Reopening (`moved_out = null`) already restores the count; adding to
  `head_count` on top double-counts. This was a live bug in
  `delete_death_event` — 3 head, death of all 3, reversal, and the lot came
  back with 6. Fixed 2026-08-25. Any new reversal RPC: test it against a lot
  whose assignment the event closed outright, not just a partial one.
- Load-out saves hard-block duplicates (same lot + date + head + tag range).
- **Deleting a move REVERSES it** through `delete_move_event` (fixed
  2026-08-26). It used to raw-delete the `lot_movements` row and warn that
  pasture counts would not change, which left the audit trail and the actual
  inventory disagreeing — and is exactly what the rule above forbids. The RPC
  had existed the whole time and was only being called by the approvals
  rollback. It removes the destination row when the move created it (rather
  than decrementing to zero) and reopens the source when the move closed it.
- **Bulk doctoring entry carries a pasture PER TAG** (`doctoring_events.
  pasture_id`, which already existed). The batch picker now seeds every row
  rather than being the stored value; a row changed afterwards wins. A row's
  list leads with the pastures its own lot actually occupies, then offers the
  rest — cattle do get worked in pens they do not live in, so it narrows
  without blocking.
- Medication deactivation already works: `medications.is_active`, a "Show
  inactive" toggle on the list, and every doctoring picker filters to active.
  Deactivating hides a med everywhere without losing it or its history.
- **Med costs are HIDDEN from crew, not blocked** (2026-08-26). `$/Unit`,
  `$/Head` and `Bottle cost` carry `data-perm="office"` in the medications
  list and edit modal. `$/unit` goes with them because it is bottle cost
  divided by bottle size — hiding two of the three would be theatre. This is
  a display gate: crew still holds SELECT on `medications`, so the figures
  are reachable through the API by someone who goes looking. John's call
  (2026-08-26) after weighing the real fix — dollar-free views plus a
  field-app test pass — as not worth the effort.

### Mixed pastures: the pro-rata split and what it costs (2026-08-31)

Cattle from several lots run together, so a move off a mixed pasture is split
**pro-rata on what the books show standing there**, largest-remainder so the
parts sum exactly. John's call, and the right one: nobody can tell by eye which
animal belongs to which lot.

- **The split touches no money.** `lot_daily_head` — which every head-day, cost
  of gain, feed, treatment and closeout figure is built on — comes from
  invoices, receipts, deaths and sales. It never reads a pasture or a movement.
  A move also leaves every lot's total head unchanged, so the head-math
  invariant holds whichever way the split falls.
- **What it does decide is which pasture each lot's head sit in, and that bites
  at the SALE.** `sale_sources` is per (lot, pasture): a draw off a pasture
  allocates real dollars to whatever lot the books claim is standing there. A
  split that drifted wrong quietly bills the wrong lot.
- **The error is self-correcting only if caught before the pasture empties.**
  John's rule: "we generally can't get a handle on what lots are left until we
  get to 20-30 head left and we can then leave the appropriate head in lot."
  The Anomalies report fires at exactly that point — see below.
- **A pasture-level re-split is NOT a free edit.** Moving 3 head from lot A to
  lot B inside one pasture breaks A's invariant (its assignments would no
  longer sum to its `head_current`) unless the offsetting 3 head are moved the
  other way somewhere else. The honest correction is a PAIRED move between the
  two pastures the mix-up spans.

### Settling a pasture against a count (pasture detail → Settle counts)

`openSettlePasture()` turns a physical count into those paired moves. Every
change goes through `record_move_with_pasture`, so nothing reimplements head
math and each lot's assignments keep summing to its `head_current`.

- **The pasture TOTAL is not up for negotiation.** A count that does not tie to
  the books is a death, sale or move that was never recorded — a different
  problem — so it is refused rather than absorbed into the split.
- **A lot short of head here, with none standing in any other pasture, is
  refused by name.** Those head are dead or sold, so the error is in an
  allocation already made and no move can reach it. This is the one case the
  screen cannot fix, and it says so instead of fudging.
- A failure part-way unwinds with `delete_move_event`, so a half-corrected
  pasture never survives.
- **`[counted YYYY-MM-DD]` in `lot_pasture_assignments.notes` is the verified
  marker**, written on every open assignment in the pasture after a successful
  settle. The Anomalies check reads it and goes quiet for 45 days. Deliberately
  a note rather than a new column: it needs no migration against a live schema
  and reads as audit text on its own. It must be present on EVERY assignment in
  the pasture — a partial marker does not suppress.
- The freshness test tolerates a NEGATIVE age. A count dated ahead of
  `ranchToday()` is timezone skew between whoever typed it and the ranch day,
  not a reason to keep nagging.

### Anomalies: pastures that will not go to zero

Three checks, all in `loadAnomaliesReport()`:

1. **Mixed pasture small enough to count** (medium) — 2+ lots and ≤ 30 head.
   The moment John's rule says the tags can be read and the split settled.
2. **Stranded head left in a pasture** (medium/low) — ≤ 3 head of a lot that is
   ≥ 50% sold. The one- and two-head slivers that never leave. Suppressed when
   the pasture already flagged as countable, or it repeats the same instruction
   once per lot.
3. **Last head scattered across pastures** (low, on the lot) — a lot at ≤ 30
   head spread over 2+ pastures.

4. **Assumption drift** (low, 2026-09-11, `docs/cog-design-decisions.md`
   §8) — COG $/lb or target ADG more than 25% off the median of the open
   lots (needs 3+ open lots), and a frozen budget more than 25% off the
   lot's working COG or ADG. Test lots, the feed pen and closed lots are
   excluded. Quiet as soon as the number is deliberate.

`severityBadge` is declared ABOVE the pasture block on purpose: the block
renders first, and a `const` used before its declaration throws at runtime with
nothing in a parse check to catch it.

### Moves tab (multi-lot moves)

- The lot-detail "+ Move" moves one lot; the **Moves** tab records a whole
  batch across lots and pastures in one pass, shaped like the shipment load
  tickets and for the same reason: counts must walk down as you type or a
  pasture drawn on twice is only caught at save.
- **Availability is netted across the WHOLE batch.** Two tickets can each look
  fine against a pasture and together overdraw it; `mvValidate()` checks the
  sum, not the ticket.
- **Tickets post in DATE order.** A batch moving A→B then B→C must replay in
  the order it happened or the second move draws on a pasture the first has
  not filled yet.
- Every ticket goes through `record_move_with_pasture` — nothing here
  reimplements head math — and a failure part-way reverses what already
  posted with `delete_move_event`.
- `loadOpenPastureInventory()` is shared with the shipment screen. Both need
  the same answer to "what is standing where"; two copies would drift.
- Historical scar tissue exists from pre-hardening eras; old lots may carry
  reconciliation notes. Read row notes before "fixing" anything.

## Tally Book (built 2026-08-28, ported the same day)

A second PWA in this repo at `tally-book/`, alongside `field-app/`. A daily
bullet journal. Migration: `docs/sql/2026-08-28_tally_book_v2.sql`, which
supersedes `..._tally_book.sql`. Touches no ranch data.

**The app is John's "JFR Tally Book" artifact, ported.** The first cut was a
from-scratch three-section journal; the artifact was a far more complete book
- day page, migration ritual, delegation, sub-steps, collections, repeats,
trackers, natural-language dates, voice capture, 114 functions - and it is
what he actually uses. The port swapped its persistence and changed nothing
else. Do not "simplify" it back.

- **The artifact stored the book in its own published page**, rebuilding its
  HTML with the state baked in and republishing. That sync had never once
  succeeded: the published copy read `days:{}` and `updatedAt:
  1970-01-01`, so the entire book lived in one browser's `localStorage` with
  no copy anywhere. That is what the port exists to fix.
- **`localStorage` is now the CACHE, Supabase is the record.** The book
  paints from the cache instantly and stays usable with no signal;
  `tally_days` and `tally_book` are what reach the other device.
- **Storage follows the app's shape, not the other way round.**
  `tally_days` is one row per day (`{entries, reflect}`); `tally_book` is one
  row per long-tail key (colls, months, rules, people, inbox, trackers,
  track, settings, lots). Flattening to one-row-per-bullet would have meant
  rewriting all 114 functions to read flat rows - a rewrite of the working
  part.
- **Per day, not one document, for conflict granularity.** One blob is
  last-writer-wins over the whole book: a phone out of signal all day syncs
  on the way home and silently overwrites the laptop. Per day, only the days
  that changed move.
- **What to push is found by DIFFING against a synced snapshot**, never by
  having `touch()`'s ~50 call sites declare what they changed. A call site
  that forgot would be an entry that silently never leaves the phone, and
  that is invisible until you go looking for it somewhere else. A diff
  cannot forget.
- **A locally dirty day is never overwritten by the remote copy.** The person
  is typing on THIS device; discarding that to honour a row written elsewhere
  is the one outcome that loses work someone can see. Local wins and is
  pushed immediately after, so both ends agree within the same sync.
- **Every sync write checks the rows it got back.** A refused write returns
  an empty result and no error, so without the check an RLS refusal reports
  success and the dot goes green on a book going nowhere.
- **Both local stores are purged on sign-out AND on user change.**
  `localStorage` knows nothing about RLS; a cache left by one account is
  readable by whoever signs in next on that device.
- **`#syncDot` had to be ADDED to the markup.** `paintDot()` always looked
  for it and the artifact never had one, so the sync indicator - and
  `syncNote` with it - was dead code the whole time.
- **`#bookView` carries `height:100%`.** `.app` is `height:100%` against a
  `100dvh` body; wrapping it in the auth gate put a zero-height block in
  between and the whole grid collapsed - capture and tabs rode up under the
  header and the day log had nowhere to render.
- Sign-in is shared across all three apps: one origin, Supabase's default
  storage key. Signing out of any signs out of all, and the button says so.
- `doExport()` still falls back to a copy-paste panel when the artifact
  `downloads` capability is absent, so **Export and Restore both work
  outside the artifact** - which is how John's existing book moves across.
- `sw.js` is `field-app/sw.js`'s network-first shell. **Bump `CACHE_VERSION`
  and the `?v=` strings in both `index.html` and `APP_SHELL` together.**

## Roadmap (agreed, in order)

1. ✅ Claude Code + CLAUDE.md + Supabase MCP connector
2. ✅ Multi-user auth + RLS — **implemented as owner/office/crew**, not the
   originally planned admin/manager/cowboy/guest. The `user_profiles.role`
   CHECK constraint permitted only those three until `accountant` was added
   2026-09-01 (read everything, write nothing — see Access control above).
   **Open decision:** a `consultant` layer was scoped 2026-09-01 and
   deferred — John's call, accountant was the concrete need. It is now one
   line in `can_read_operational()` / `can_read_books()` plus the CHECK
   constraint. Same for the long-parked read-only `guest`.
   Lauren Yezak signed in 2026-08-25 and works the books as `owner`.
3. ✅ Field PWA for cowboys — live 2026-08-25. The field app writes to
   `pending_field_entries`; the office **Approvals** tab reviews and posts them
   into the books. See "Field → books approval path" above.
4. Cost ledger (18 categories, monthly, per-head-day allocation; Redwing
   exports imported via Cowork). Note: cost data is office+owner only.
5. Daily buy/sell dashboard: breakevens vs market data
6. Commodity feed & mineral inventory — **phases 1-2 built 2026-08-27**
   (catalog, bays, FIFO layers, on-hand, the usage ledger with atomic
   consumption and reversal RPCs, and physical counts). See the section above
   and `docs/commodity-feed-inventory-plan.md`. **Phase 4 (cost of gain) and
   premix batches added the same day** —
   `docs/sql/2026-08-27_feed_phase4_premix.sql`. Remaining: phase 3 PB
   import, phase 5 Redwing export.
Also parked: breakeven budget-vs-actual, bottle inventory, lot comparison
report, weather integration.
