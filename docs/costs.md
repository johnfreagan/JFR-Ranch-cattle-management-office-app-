# Costs: business rules, processing cost and protocol versioning, closeout

_Moved word for word from `CLAUDE.md` on 2026-09-27, when CLAUDE.md became a short index. Nothing here was rewritten; section dates are the dates the rules were written._

Longer reasoning on processing cost: `docs/processing-cost-and-protocol-versioning.md`. Cost of gain decisions: `docs/cog-design-decisions.md`.

## Business rules (get these wrong and the books are wrong)

- Fiscal year runs **July 1 – June 30, named for the ENDING year**.
  Aug 2026 arrival → FY 2027. A DB trigger (`derive_fiscal_year`) enforces this.
- Stocker operation: high-risk lightweight steers (275–350 lb in). ~11 ranches,
  ~60 pastures. Lots are the core unit (e.g. 36-27, 37X, 47-26).
- Head math invariant: head_in − head_dead − head_sold − transfer_out +
  transfer_in + adjustment = head_current, and head_current must equal the sum
  of open lot_pasture_assignments. Divergence = "drift" and shows on the
  Anomalies report. Never create drift. (`lot_status` has always carried the
  transfer and adjustment terms; missing head and strays back — see "Strays
  and missing head" — are the first time an ordinary lot uses one.)
- Processing (receiving meds) is captured on **delivery receipts via
  receiving_protocol_id** — NOT as doctoring events. Cost views derive from
  receipts × protocol_meds × medication pricing.
- Treatment cost comes from doctoring_events + doctoring_event_meds (cost is
  FROZEN per row at save time). **A NULL cost is a hole, not a frozen
  number**, and may be back-filled from the current price list with a
  `WHERE cost IS NULL` guard — done 2026-09-04 on the X lots (682 rows,
  $8,873.41, `docs/sql/2026-09-04_backfill_x_lot_med_costs.sql`) and
  2026-09-10 on everything else (1,159 rows, $10,095: 31-26 and 47-26,
  both closed FY2026, John: "some data is better than no data",
  `docs/sql/2026-09-10_backfill_med_costs_all_lots.sql`). Two rows remain
  NULL because nothing can price them: one Dexamethasone on 59X (no price
  on the list) and one free-text Bloat-Pac on 31-26 (no medication row).
  Price Dexamethasone and the same guarded UPDATE fills the 59X row.
- **`invoices.receiving_protocol_id` is a FALLBACK, not a label** (2026-09-10,
  `docs/sql/2026-09-10_processing_invoice_protocol.sql`). The invoice form
  had carried a protocol picker that no view read, so 37X / 37X-1 / 37X-F
  showed $0 processing with the protocol sitting on every invoice. Now:
  a load out's own protocol, or its absence, decides the head it covers;
  invoice head that NO load out covers is priced at the invoice's protocol
  (37X: 361 of 369 head have no receipt rows at all). The migration also
  copied the invoice protocol onto receipts that had none, open lots first
  and 31-26 (closed, FY2026, 1,766 hd, $28,586.51 on "25 Fall Light Steer
  Processing") the same day on John's call: "processing cost on all lots".
  47-26 had a protocol nowhere; John picked "26 Summer X Steers/Bulls
  Receiving v1" for it (2 invoices, 10 receipts, 187 hd). Every real lot
  now prices processing; the only holes left are Protivity lines on the
  26 Summer X protocol until it is priced. `procCoverage` counts head, not loads, and carries
  `headOnInvoiceProtocol`; the tile reads "N of M hd".
- **A receipt with no `receiving_protocol_id` has NO processing cost**, and
  the lot's $/hd reads diluted (dollars from the covered loads over every
  head in). The lot tile shows "5 of 10 loads" in amber when coverage is
  partial and "no protocol" when it is zero; the Receiving report prints
  per head processed AND per head in, and lists the loads without one.
  Found 2026-09-04: 59X had 5 of 10 loads covered; 37X, 37X-1 and 37X-F
  had none, and their cattle pre-date every protocol in the system.
- Processing $/hd is per head IN; Treatment $/hd is per SURVIVING head
  (`head_in − head_dead`, shipped or not). It was per head current until
  2026-09-04, which loaded 60X's whole treatment bill onto its last 29 head.

### Changing a protocol or a drug price — read before editing either

- **Processing cost is DERIVED LIVE, not frozen.** `lot_processing_costs` and
  `lot_processing_cost_detail` join
  `delivery_receipts.receiving_protocol_id → protocol_meds → medications` and
  read **current** prices, dose config and `round_up_to`. Editing a protocol's
  meds, or a medication's price or rounding, retroactively rewrites processing
  cost for **every lot that ever used it** — closed lots and prior fiscal years
  included — silently and with no audit trail. Contrast treatment cost, which
  is frozen per row at save time; the two behave oppositely.
- **`protocols.effective_from` is decorative. Nothing enforces it.** The cost
  views never reference a date. Creating a new version with an effective date
  changes nothing on its own.
- **To change processing from a date:** create a NEW protocol row
  (`parent_protocol_id` → old, new `version_label`, set `effective_from`), then
  `UPDATE delivery_receipts.receiving_protocol_id` on exactly the receipts
  on/after that date. Never edit the old protocol in place — the earlier loads
  genuinely got the old product and their books must keep saying so.
- **An unpriced medication prices as NULL, and `SUM()` ignores NULL** — the
  line silently vanishes from processing cost instead of erroring. Price a med
  BEFORE pointing a protocol at it, and check `unpriced_line_count` after any
  protocol change. Guard repoint scripts with a pre-check that raises if any
  med on the target protocol has both `cost_per_unit` and `cost_per_head` null.
- **Keep `round_up_to` consistent between generic and brand of the same drug.**
  It models the syringe setting including waste, not drug consumed. A generic
  entered at 0.1 against a brand at 1.0 is a math change disguised as a price
  change.
- Worked example (2026-08-24): lot 36-27, Draxxin → Macrosyn effective Wed
  2026-08-19. New protocol version created, 5 of 11 receipts (197 of 441 head)
  repointed. Lot processing went $9,109.06 → $8,901.48, $20.66 → $20.18/hd in.
  The six Aug 11–18 loads stayed on branded Draxxin.
- Doctoring eligibility: pulls start 8–9 days after Draxxin at receiving;
  fresh-cattle report window is 17 days.
- Tag numbers recycle across fiscal years. "Current animal for a tag" =
  the tag on an OPEN lot. Doctoring search scopes to open lots by default.

## Closeout: budget, actual, projection (rebuilt 2026-08-25)

The Closeout tab shows one set of economics in three columns. It is
**office+owner only** — the sub-tab carries `data-perm="office"`.

| | where it comes from |
|---|---|
| **Budget** | `lot_budgets`, frozen when the lot starts, immutable |
| **Actual** | the books: invoices, processing, treatment, real head-days |
| **Projection** | actual to date, carried forward to the ship date |

- **`lot_budgets` is frozen by a trigger, not by a missing policy.** Office
  and owner deliberately PASS the RLS check on UPDATE so `lot_budgets_frozen()`
  fires and raises a real error. Denying at the policy layer would make
  PostgREST return zero rows and the app would report a save that changed
  nothing. Owner-only DELETE is the escape hatch for a budget typed wrong.
  Working assumptions that change over the life of the lot stay on `lots.*`.
- **Everything is computed in total dollars and divided at the end.** This is
  what fixes the death-loss double count: the old per-head math added a death
  loss line on top of a cattle cost that already contained the dead animals,
  and applied the full assumed percentage to a head count already reduced by
  the deaths that happened — 6% budgeted plus 5% already buried came out near
  11%. In total dollars death loss needs no line; it falls out of the
  division. The projection estimates only **deaths still to come**:
  `clamp(0, head_current, head_in × pct − head_dead)`.
  **Since 2026-09-10 the deaths still to come are weighted by exposure**:
  `deathsToCome = clamp(0, head_current, (head_in × pct − head_dead) ×
  remainingDays / (daysToDate + remainingDays))`. The assumed % is a
  whole-life rate; the head still here have survived most of that life.
  Before this the whole unspent allowance dropped on the remnant — 60X
  projected 2 of its last 6 head dying ($852/hd) after its ship date.
  Past the ship date nothing more is assumed. With NO ship date the
  exposure is unknown and the whole allowance stands, as before.
  **Since 2026-09-04 death loss IS shown as its own line** (John: "very
  important line item") — but CARVED OUT of Cattle in, never added on
  top: `deathLossUsd = head_dead × avgCostIn`, `cattleLive = cattleCost −
  deathLossUsd`, projection adds `deathsToCome × avgCostIn` and takes it
  out of cattle in again. The two lines sum to the invoices, total cost
  is unchanged, and Cattle in per head lands on the same figure as the
  lot tile. Death loss is valued at cost IN only; the dead animals'
  processing, feed and doctoring stay in those lines.
- **Cost of gain and labor are charged against head-days, never against
  today's head count × total days.** Cattle that shipped in June ate grass
  until June. On 37X-1 the old math charged 75 head × 231 days = 17,325
  head-days against a real 56,993 — about $39,700 of cost that appeared
  nowhere.
- A **per-head** (flat) COG or labor rate is charged once on `head_in` and
  never carried forward again. Only **per-day** rates accrue on head-days.
- **COG mode `per_lb` (2026-09-04, John's call) charges the rate on POUNDS
  GAINED, trued up to the scale.** Migration
  `docs/sql/2026-09-04_cog_per_lb.sql` adds `lots.assumed_cog_per_lb` and
  widens both `cog_mode` CHECKs. Gain to date = `lot_realized_adg.
  total_gain_lb` (real pay weight less weight in, on head already shipped)
  + target ADG × the head-days NOT covered by `sold_head_days`. The
  projection adds target ADG × forward head-days. Each sale with a pay
  weight moves its slice from estimate to fact, so a fully shipped lot has
  no estimate left. The budget column uses its own frozen `target_adg`.
  Before the feed boundary the gain is pro-rated onto `hdBefore` by
  head-days. This deliberately reverses the older "per-pound is display
  only" rule below: the assumed ADG is biased low, so the estimated slice
  reads LIGHT until the cattle ship — the screen warns when realized ADG on
  shipped head runs more than 5% over the assumption, with both dollar
  figures. The transfer basis (`ltStoredRates`) feeds `lots.target_adg` in
  for this mode only. **The Closeout input is LOCKED to `per_lb`** (John, later
  2026-09-04: "lock on the closeout input screen $ per pound as the
  default COG metric"). There is no COG mode selector; `closeoutRates()`
  always returns `per_lb` and Save writes `cog_mode='per_lb'` +
  `assumed_cog_per_lb`, leaving the old per-day / flat columns as audit.
  **Since 2026-09-11 per_lb is the ONLY mode anywhere**
  (`docs/sql/2026-09-11_cog_per_lb_only.sql`): every lot and budget was
  migrated (31-26 and 37X-1 from $1.00/hd/day at 1.80 ADG = $0.5556/lb,
  with audit notes), both `cog_mode` CHECKs now accept only `'per_lb'`,
  and the per_day / per_head branches are gone from `closeoutActual`,
  `closeoutProjection`, `closeoutBudget`, `ltStoredRates` and the
  conversion hint. The feed boundary's non-feed charge, which used to
  borrow the per_day path, is its own explicit step (`nonFeedRate`,
  $/head-day, beside `cogLbRate`). The old `assumed_cog_per_day` /
  `_per_head` columns stay as audit and are no longer copied to a new lot.
  Labor keeps its selector, per head-day.
- **Finish weight comes off the anchored projection** (2026-09-11,
  `docs/cog-design-decisions.md` §5): `lot_projected_weight_detail()`
  walked to today, plus days-to-ship × the same ADG the cost estimate uses
  (`actual.estAdg`: realized / whole-lot weighing / target). A ship date
  already past holds the head at today's weight — the function walks
  BACKWARD to a past date (37X read 747 lb at its July ship date against
  835 today), which is not what the head still standing weigh. Typed by
  hand the box stands (`closeoutFinishTouched`) with a reset link in the
  hint. Weight in + days × target ADG survives only as the fallback when
  the RPC cannot be read; it used to be the only formula and disagreed
  with the lot tile the first time a lot was weighed.
- **Interest** accrues on the cattle for the whole period and on operating
  cost at half the period, the usual convention for a cost that builds
  linearly. The old screen charged interest on the purchase price only.
- Treatment carries forward at the lot's own observed $/head-day, not at the
  budgeted med figure — once there is history, the lot's own burn rate beats
  an assumption.
- **Break-even is the LOT AVERAGE per head sold, never "what the last head
  must bring".** (2026-09-04) The first cut of the remnant block, and the
  table's break-even row since the rebuild, took whole-lot cost less banked
  revenue over the pounds still on feed — so on 60X the last 29 of 251 head
  carried the entire lot's margin and read $6-10/lb. John: "a $10 pound
  breakeven can't be correct." Now `costPerHeadSold = totalCost /
  headSoldAtClose`, break-even is that over finish weight, and the
  **Cattle still on feed** block prices the remnant at its equal share
  (`remnantCost`). The lot-shortfall figure survives only as a footnote
  labelled as the lot's margin landing on its last head.
- **Processing and doctoring are two lines with two assumptions**
  (2026-09-04; John "historically combined both on projections"). Migration
  `docs/sql/2026-09-04_processing_doctoring_split.sql` adds
  `lots.assumed_processing_per_head` / `assumed_doctoring_per_head` and
  `lot_budgets.processing_per_head` / `doctoring_per_head`;
  `med_per_head` stays for budgets frozen before, shown combined on the
  Processing row. **Processing projection = actual from the receipts + the
  assumption × head on loads with NO protocol** — once every load carries
  a protocol the derived actual IS the projection and the assumption is
  unused ("as soon as processing is set … that number can become the
  projection number, adjusted for actual"). **Doctoring projection =
  actual + observed burn, floored at the assumption × head_in while the lot
  is on feed**, so a young lot with two pulls does not project nothing.
- **Processing and doctoring show as ONE `Medicine` row on the closeout
  table** (John, 2026-09-06: "combine processing and doctoring medicine on
  closeout"). The two assumptions, the two projections and the two budget
  columns are unchanged underneath; only the table line is combined
  (`actual.medicine`, `proj.medicineFwd`). The row drills `toggle:med`,
  which opens two indented child rows in place, Processing (drills to the
  Receiving report) and Doctoring (drills to Animal Health), remembered in
  `closeoutMedOpen` / localStorage like the view toggle. The `other` med
  category, which was inside `operating` but on no row, is now in Medicine
  and shows as a third child only when non-zero, so the rows sum to Total
  cost. A budget frozen before the split shows its one figure on the
  Medicine row and blanks on the children.
- **A throw anywhere in `showLotDetail()` before `renderCloseoutCalculator()`
  leaves the Closeout tab at "Loading…" with no error shown** — that is
  what "37X has no closeout" looked like on 2026-09-09. The cause was
  `penOutHead`, computed in `closeoutProjection()` but read as a free
  variable in `recalculate()`, so a ReferenceError fired only on a lot
  with a transfer (37X, the one open lot with one). It now rides on
  `proj.penOutHead`. The harness that caught it loads the real
  `index.html` in headless Chromium with a fake supabase client fed the
  lot's live rows (`scripts/` has no copy; it lived in the session
  scratchpad) — a lot-specific blank tab is a data-shaped code path, so
  test with that lot's rows, not a generic fixture.
- **Once any head have shipped the whole table SPLITS** (John, 2026-09-04:
  "on the actual you include total cost not the proportion that goes with
  sold hd count"). `split = soldHead > 0`; every cost line goes through
  `sp(actual, fwd)` → Actual = sold share of the line to date, Projection =
  left share + forward, and a fourth column **Lot at close** = the two
  added back, which is what the budget variance compares to. Shares are per
  head over `headSoldAtClose`. Before any sale there are three columns,
  whole-lot to date and whole-lot at close, as always.
- **Net: Actual is on the head SOLD, Projection is on the head LEFT**
  (John, 2026-09-04). The sold head carry their share of cost TO DATE
  (`actualCostPerHd = actual.totalCost / headSoldAtClose`) against the
  checks banked — nothing projected touches them ("use actual sales for
  the sold head, not the projected price for the remainder"). The head
  left carry that share PLUS every forward dollar against forward revenue
  (`leftCost`, `leftBreakEvenPerLb`). Sold + left = lot net exactly; a
  "Net, whole lot" row shows the sum once anything has shipped. Before any
  sale the Actual net is blank and the Projection net is the whole lot.
- **Totals / Per head toggle** above the table (`closeoutView`, remembered
  in localStorage). Per head divides each column by ITS OWN head: budget
  survivors, head sold (or surviving head before any sale), head left (or
  head sold at close), head sold at close. Rows marked `unit:'count'` or
  `unit:'ratio'` are never divided.
- **Assumption changes are logged on SAVE only** (2026-09-11,
  `lot_assumption_history`, `docs/sql/2026-09-11_lot_assumption_history.sql`,
  decision in `docs/cog-design-decisions.md` §7). The inputs are John's
  scratch pad: typing recalculates live and is a what-if — the screen says
  so in amber and offers **Reset to saved** — and nothing lands until Save.
  An AFTER UPDATE trigger on `lots` writes `{column: [old, new]}` for each
  assumption that moved, nothing on a no-op; RLS read through
  `can_read_books()`, insert for owner/office (the trigger runs as the
  invoker), no update or delete. Shown as "Assumption changes" on the
  lot's Audit log tab.
- **No locks or edit buttons on the closeout inputs.** Every assumption
  is prefilled from the lot; click and type. (A readonly lock with an
  "edit" button was built and removed the same day at John's request.)
- **`lots.target_sale_cwt` is $/lb despite the name**, and the new
  `lot_budgets.budget_cost_per_cwt` follows it for consistency. Both are
  multiplied by a weight in pounds. Do not "fix" one without the other.
