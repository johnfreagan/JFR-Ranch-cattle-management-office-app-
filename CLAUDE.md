# JFR Ranch Cattle Management App

Single-file web app (index.html at repo root) for JFR Ranch Co. Ltd., a stocker
cattle operation in Kosse, TX. Deployed via GitHub Pages. Backend is Supabase
(PostgreSQL + auth + PostgREST). Owner: John Reagan.

**Multi-user as of Aug 2026** — three roles (owner/office/crew) enforced by RLS.
See "Access control" below and `docs/security-model.md`.

## Deploy

- The ONLY app file is `index.html` at repo root (~650KB). There is no build step.
- Deploy = commit + push to main. GitHub Pages auto-deploys in 1-3 min.
- After deploy, hard refresh (Cmd+Shift+R) to bypass cache.
- Supabase URL: https://xpfmebdzcxorvwikfvtj.supabase.co (publishable key is
  embedded in index.html — this is expected for this app).
  **Corollary: the key is public, so anything GRANTed to `anon` is public.**
  Embedding the key is fine; granting `anon` access to anything is not.

## Business rules (get these wrong and the books are wrong)

- Fiscal year runs **July 1 – June 30, named for the ENDING year**.
  Aug 2026 arrival → FY 2027. A DB trigger (`derive_fiscal_year`) enforces this.
- Stocker operation: high-risk lightweight steers (275–350 lb in). ~11 ranches,
  ~60 pastures. Lots are the core unit (e.g. 36-27, 37X, 47-26).
- Head math invariant: head_in − head_dead − head_sold = head_current, and
  head_current must equal the sum of open lot_pasture_assignments. Divergence
  = "drift" and shows on the Anomalies report. Never create drift.
- Processing (receiving meds) is captured on **delivery receipts via
  receiving_protocol_id** — NOT as doctoring events. Cost views derive from
  receipts × protocol_meds × medication pricing.
- Treatment cost comes from doctoring_events + doctoring_event_meds (cost is
  FROZEN per row at save time). **A NULL cost is a hole, not a frozen
  number**, and may be back-filled from the current price list with a
  `WHERE cost IS NULL` guard — done 2026-09-04 on the X lots (682 rows,
  $8,873.41, `docs/sql/2026-09-04_backfill_x_lot_med_costs.sql`). The
  non-X lots still carry ~1,178 unpriced rows.
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
  A lot still stored `per_day` opens with per-day ÷ target ADG in the box
  and a "converted … save to keep" hint; the books do not change until
  saved, and the transfer basis keeps reading the stored mode until then.
  `closeoutActual`/`closeoutBudget` still handle all three modes because
  frozen budgets and unsaved lots carry them. Labor keeps its selector,
  per head-day.
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
- **No locks or edit buttons on the closeout inputs.** Every assumption
  is prefilled from the lot; click and type. (A readonly lock with an
  "edit" button was built and removed the same day at John's request.)
- **`lots.target_sale_cwt` is $/lb despite the name**, and the new
  `lot_budgets.budget_cost_per_cwt` follows it for consistency. Both are
  multiplied by a weight in pounds. Do not "fix" one without the other.

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

## Access control (RLS — read before touching auth, policies, or views)

The gate is `public.current_user_role()`. It reads `user_profiles.role` for
`auth.uid()` **and requires `is_active = true`**. Returns NULL for anyone
inactive or unknown; every policy is written so NULL denies.

| | crew | accountant | office | owner |
|---|---|---|---|---|
| Read operational data (lots, weights, tags, doctoring, pastures, movements) | ✅ | ✅ | ✅ | ✅ |
| Write field data (doctoring, weights, tags, receipts, pasture assignments) | ✅ | ❌ | ✅ | ✅ |
| Correct/update operational records | ❌ | ❌ | ✅ | ✅ |
| Invoices, cost and margin data | ❌ | ✅ read | ✅ | ✅ |
| Delete lots, weights, medications, protocols, audit rows | ❌ | ❌ | ❌ | ✅ |
| See the user roster | own row | own row | own row | all |

### `accountant` — read everything, write nothing (added 2026-09-01)

Migration: `docs/sql/2026-09-01_accountant_role.sql`. Verified against the
live DB the same day: 22 / 26 / 0 / yes / yes.

- **A read-only role is a second AXIS, not another rung.** The ladder is
  owner > office > crew and every write policy is a positive allow-list
  naming owner and office explicitly — so `accountant` writes nothing by
  simply not being named. **The write policies were deliberately not
  touched**; rewriting the dangerous half of the security layer to add a
  role that cannot write buys nothing. Audited 2026-09-01: there is not one
  negative test ("anyone who isn't crew") anywhere in the schema, which is
  the only reason this is safe.
- **The 48 SELECT policies go through `can_read_operational()` (22) and
  `can_read_books()` (26).** The next read-only role — the deferred
  `consultant`, or a `guest` — is one line in one function, not another
  48-policy migration. Two SELECT policies are deliberately excluded:
  `user_profiles` (own row or owner) and `ranch_settings` (any active role,
  the only `IS NOT NULL` test in the schema).
- **`storage.objects.lot_attachments_read` is part of the read set.** Miss it
  and an accountant reads every invoice row while every attached scan 404s —
  the worst possible failure for the one role that exists to read invoices.
- **The migration matches policies on their EXPRESSION, not on a typed list
  of names.** Policy naming is inconsistent (`dra_select`, `lpa_select`,
  `load_out_dests_select`) and a typo in a name list silently skips a table.
  It asserts 22/26/2 and raises if the count is off.
- **App-side, the refusal lives in ONE client wrapper, not on ~140 call
  sites.** `supabase.from().insert/update/upsert/delete`, `supabase.rpc()`
  and `supabase.storage.from().upload/update/remove` return a PostgREST-
  shaped `{data:null, error:{code:'READONLY'}}`, so every existing
  `if (error)` path surfaces it. RPCs are an **allow-list** (three read-only
  ones) so a mutating RPC added later is refused by default.
- **`supabase.storage` is a getter returning a NEW StorageClient on every
  access** (verified in supabase-js 2.46.1: `get storage(){ return new
  StorageClient(...) }`). Wrapping `supabase.storage.from` directly mutates a
  throwaway and silently does nothing — capture one instance, wrap it, pin it
  with `defineProperty`.
- **Write controls are marked `data-write`, its own attribute — NOT
  `data-perm="write"`.** Half the tagged buttons already carry
  `data-perm="office"`, and an element holds only one `data-perm`; reusing it
  would have dropped the office gate and shown those buttons to crew.
- **Tagging is cosmetic; the wrapper is the enforcement.** So a missed button
  is survivable (it shows, the click returns a clean refusal) but a FALSE
  positive is a real bug — an id-keyword sweep caught `forageEditCancelBtn`
  on the "Edit" substring and three filter/render "Apply" buttons. Hiding a
  Cancel traps the user in a modal. Check what a button's handler actually
  does before tagging it.

Deletes are the narrowest privilege on purpose: `lot_movements`, `lot_events`
and `lot_pasture_assignments` are audit trails, and an accidental delete there
is unrecoverable in a way an accidental insert is not.

### Rules — each of these was a live hole in Aug 2026, not a style preference

1. **Never read a role, permission, or tenant from `raw_user_meta_data`.**
   That field is written by the client at signup. `handle_new_user()` trusted
   it and `signUp({data:{role:'owner'}})` minted a working owner account.
   Roles are set by an owner in `user_profiles`, never at account creation.
   The trigger is `AFTER INSERT ON auth.users FOR EACH ROW`, so this applies
   to `inviteUserByEmail` and `admin.createUser` too — never pass `data:{...}`
   with a role to either.
2. **New users land inactive** (`role='crew'`, `is_active=false`). A new
   account seeing zero rows is correct, not a bug. An owner activates it.
   Public signups are also disabled in the dashboard; both locks stay on.
3. **Every view must be created `WITH (security_invoker = true)`.** Without it
   a view runs as its owner and bypasses RLS entirely regardless of base-table
   policies. Ten views were exposed this way and readable by `anon` with no
   login at all. No exceptions.
4. **Never GRANT anything to `anon`.** `authenticated` + RLS is the only path.
   Revoke from `PUBLIC`, not just `anon` — Postgres grants function EXECUTE to
   PUBLIC by default, so `revoke ... from anon` alone silently does nothing.
5. **New tables need RLS *and* policies.** `ENABLE ROW LEVEL SECURITY` with no
   policy is a total lockout; policies without `ENABLE` are decoration.
6. **`SECURITY DEFINER` needs a reason and a pinned `search_path`.** Each one
   bypasses RLS. Deliberate today (all seven verified 2026-08-25 to carry a
   pinned `search_path`): `current_user_role` (it is the gate),
   `admin_list_users`, `guard_last_owner`, `handle_new_user`,
   `cleanup_attachment_storage`, `lot_projected_weight`,
   `lot_weighted_arrival_date`. Default to INVOKER — the head-math RPCs
   (`record_death_with_pasture`, `record_move_with_pasture`, the delete
   reversals) are all INVOKER and must stay that way.
7. **Run `supabase/migrations/20260821000300_rls_verify.sql` after any
   migration that adds a table, view, or function.** It asserts 1–6.

### Offline/PWA consequences (the live field app depends on all three)

- An RLS denial on SELECT returns **zero rows, not an error**. "No lots" is
  ambiguous between not-authorized, offline, and genuinely empty. Call
  `current_user_role()` on load and distinguish all three, or every access
  problem looks like a sync bug.
- A write queued offline replays under **later** authorization. Queued Tuesday,
  synced Thursday, user deactivated Wednesday → `42501`. Needs a dead-letter
  path. Never a silent drop (this is animal health data), never infinite retry.
- Purge local stores on sign-out and on user change; IndexedDB knows nothing
  about RLS. Persist the write queue outside the auth session, keyed by user
  id — days offline can outlive the refresh token.

## Field → books approval path (live 2026-08-25)

Nothing a cowboy records reaches the books directly. The field app's only write
surface is `pending_field_entries`; the office **Approvals** tab posts from
there. Read this before touching either side.

```
field PWA → pending_field_entries → office Approvals tab → RPC → books
         ↑ localStorage queue keeps this offline-first
```

- **`(entry_type, client_id)` is an UPSERT key, not a duplicate check.** The
  field app re-sends an edited record under the same client id, and the second
  send must overwrite the first. Do not add a reject-duplicates constraint.
- **Statuses:** `pending → approved | rejected | withdrawn`; `withdrawn → pending`
  (office reinstates); `rejected → pending` (office reopens); **`approved` is
  terminal.** `pfe_guard_settled()` enforces this in the DB — the app is not the
  only guard. `withdrawn` exists because the field app can delete a record.
- **Approval is all-or-nothing per batch** (John's call, 2026-08-25). If any row
  in a selection fails, `rollbackPosted()` unwinds the ones already written.
  Deaths and moves post through their atomic RPCs so head math stays intact.
- **Order matters within a batch.** Doctoring first, then deaths and moves
  sorted by `event_datetime` — head-math entries must replay in the order they
  happened or a move can outrun the death that freed the head.
- **Cost freezes at approval, not at field entry.** Price a medication BEFORE
  approving anything that uses it; an unpriced med writes a NULL cost line that
  `SUM()` then ignores. The approvals screen flags unpriced meds — do not
  approve past that flag.
- **Correcting a date** is done on the approvals row, which shifts
  `event_datetime` by whole days and rewrites only the date half of
  `raw.dateTime`, preserving time of day. It is guarded `.eq('status','pending')`
  so an already-posted entry can never be rewritten.
- Deaths approve **without a cause** — cause is filled in later on the lot.
  Carcass disposal is flagged when the animal was **NOT** hauled off.
  (`drug_off` means removed to the proper location for dead animals; it has
  nothing to do with drug withdrawal.)

## Schema landmines (verified by painful trial and error — trust these)

- `doctoring_events.tag_number` is TEXT. `lot_tags.tag_number` is INTEGER.
- `doctoring_events` uses `recorded_by_user_id`; has NO updated_at.
- `lot_events` uses `created_by`; has NO updated_at.
- `lot_pasture_assignments` uses `recorded_by`.
- Meds junction table is `doctoring_event_meds` (NOT doctoring_medications).
- `load_out_destinations` FK to receipts is `receipt_id`.
- `sales` has BOTH gross_weight_lb and net_weight_lb — realized ADG and pay
  weights use **net**.
- `field_protocols` has default_med_1/2/3_id but NO dose columns.
- `lot_pasture_assignments` uses `moved_in` / `moved_out` — NOT date_in/date_out.
  An OPEN assignment is `moved_out is null`.
- `pastures.name` — NOT pasture_name. `lots` has no `status` column; open means
  `closed_at is null`. Head counts live on the `lot_status` VIEW, not on `lots`.
- **`lot_status` is keyed on `lot_id`, NOT `id`.** Getting this wrong does not
  throw in the app: PostgREST returns an error, the destructured `data` comes
  back undefined, and the code quietly does nothing. Two live instances were
  found 2026-08-26 — one in the shipment save and one that had been sitting in
  the single-lot sale form, which is why its "this lot is empty, close it?"
  prompt had apparently never fired. In SQL it throws honestly
  (`column ls.id does not exist`), which is how the shipment reversal's
  version was caught. Always check `error` on a `lot_status` read.
- **The database runs UTC; the ranch does not.** `CURRENT_DATE` becomes
  tomorrow at 7pm Central (6pm in CST), so anything that counts days must use
  `public.ranch_today()` instead. `lot_daily_head` shipped with `CURRENT_DATE`
  and gained a whole extra day of head-days each evening — 441 on 36-27,
  $882 at its rate, for a day Texas had not had. The app matches it with
  `ranchToday()`, pinned to `America/Chicago` rather than the viewer's clock.
  Same trap as `toISOString()` in the field app.
- **There are TWO head-day implementations and they disagree.** The FUNCTION
  `lot_head_days(uuid, date)` anchors on `lot_weighted_arrival_date()`, which
  is built from INVOICE dates. The VIEW `lot_head_days_by_month` (over
  `lot_daily_head`) walks arrivals by RECEIPT date. Where invoices follow
  receipts closely they agree within ~1%; on 36-27 the function read 2,646
  against the view's 3,424, 29% low, because the cattle landed Aug 11 and the
  invoices weighted to Aug 19. **Use the view for anything involving cost** —
  cattle eat from the day they hit the ground.
- `lot_daily_head` reconciles to `lot_status.head_current` by construction and
  is verified to do so on every lot. Head-day math must NOT be built on
  `lot_pasture_assignments`: 37X's assignment history starts 2026-04-27
  against a first invoice of 2025-12-04, so it would silently drop 144 days.
- `pending_field_entries` has `reviewed_at`/`reviewed_by` and an `approved_ref`
  jsonb (`{kind, id}`) — there is no `approved_at`.
- Supabase PostgREST caps results at 1000 rows — PAGINATE lot_tags and any
  large fetch. **PostgREST query builders are single-use** — a pager must take
  a builder *function* and call it fresh per page, not reuse one object.
- `lots.start_tag` / `end_tag` describe the FIRST receipt only, not the lot's
  whole tag range. To resolve a tag to a lot, go lot_tags → receipt ranges →
  and only then fall back to lots.start_tag/end_tag.
- **The Supabase SQL editor swallows `begin;`/`commit;`** — a wrapped script
  can report "Success. No rows returned" without applying anything. Omit the
  wrapper when pasting into the editor; keep it in files meant for the CLI.
- **The MCP Supabase connector is READ-ONLY.** DDL and DML fail with
  `25006: cannot execute ... in a read-only transaction`. Give John pasteable
  SQL in chat — not a file attachment, not a path. He has said so twice.
- When unsure of a column name, QUERY information_schema — do not guess.
  Schemas evolved inconsistently across tables.
  **Exception: do NOT trust information_schema for GRANTS or PRIVILEGES.**
  `role_table_grants` only shows roles the *querying* user belongs to, so on
  hosted Supabase it returns an empty set for `anon` while `anon` in fact holds
  full grants. Use `has_table_privilege()` / `pg_class.relacl` for privileges.
  Columns and types are fine.

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

## Commodity feed & mineral inventory (phases 1-2 live 2026-08-27)

Migration: `docs/sql/2026-08-27_feed_inventory.sql`. Plan and the reasoning
behind every choice: `docs/commodity-feed-inventory-plan.md`. Office+owner
only; the whole tab carries `data-perm="office"`.

```
feed_receipts (= the FIFO layer)  ──▶ feed_usage ──▶ feed_usage_costs (frozen $)
feed_items · feed_storage_locations       │              ▲
feed_counts · feed_count_lines ───────────┘   physical count → variance → ledger
```

- **`feed_items` has NO price column, and that is the point.** Price lives on
  the receipt that brought the load in and FREEZES into `feed_usage_costs`
  when the pounds are consumed. This is treatment cost's behaviour, chosen
  deliberately against processing cost's — where editing a drug price silently
  rewrites closed lots and prior fiscal years. Do not add `cost_per_lb` to
  `feed_items`; the migration's verify block raises if anyone does.
- **The one sanctioned after-the-fact write is `recost_pending_usage()`.**
  Feed gets delivered, fed, and only then invoiced. Those cost rows are
  written NULL and flagged; the RPC fills them in and is guarded
  `WHERE cost IS NULL`, so it can fill a hole but never move a frozen number.
  The receipt modal calls it automatically when an unpriced load gets a price.
- **A blank cost is not allowed to be an accident.** `cost_pending` is an
  explicit checkbox. Without it the unpriced-medication trap repeats exactly:
  NULL cost, `SUM()` ignores it, feed silently becomes free.
- **FIFO runs per (item, location).** Corn in Bay 2 and Bay 5 are one item in
  two places. Global FIFO would let a count on one bay eat a layer sitting in
  another and on-hand-by-bay would stop reconciling.
- **Going short is allowed, flagged, never blocked.** A bulk bay is an
  estimate; if the layers run out, the remainder costs at the item's last
  known price and sets `is_short`. Refusing does not un-feed the cattle.
- **`feed_usage` carries `period_start`/`period_end`, not just a date.** Feed
  is entered weekly and PB invoices a date RANGE. Phase 4 spreads dollars over
  the head-days inside the window — same reason the app writes one `sales` row
  per lot per DAY.
- **`delete_feed_usage` puts pounds back on the exact layers, with no branch
  for a layer consumed to zero.** That branch is the `delete_death_event` trap
  in feed form. Verified against a layer emptied outright, not just a partial.
- `delete_feed_receipt` REFUSES once any pounds are consumed — orphaning
  frozen costs is the disaster this module exists to prevent.
- A transfer between bays lays a new layer at the cost it left at, linked by
  `feed_receipts.from_usage_id`. The reversal refuses if the far bay has
  already fed any of it.
- **Bulk feeders in pastures are NOT locations** (John, 2026-08-27). A
  location is where feed is stored and counted. Feed leaving a bay for a
  feeder is just usage.
- Bays are added and edited in the app — there is no seed list.
- **PB supplies pounds, we own the cost.** The 2026-08-27 invoice is commodity
  level (no rations), its group IS the lot number, it has no per-pen split,
  and its head count and head-days tie to our books exactly. Import
  `Amount Fed` only: never `Cost Per Ton`/`Feed Cost` (may go stale or blank),
  never `Dry Matter Fed` (12.4% low — it would leave a phantom bay balance).
- **Phase 3's real hazard is an OVERLAPPING import, not a duplicate one.**
  `pb_row_key` upserts a re-run of the same invoice; running Aug 17-26 then
  Aug 20-31 double-feeds four days under different keys.

### Design decisions taken 2026-08-28 — read `docs/feed-design-decisions.md`

Twenty-five decisions, DECIDED NOT YET BUILT. The full record with the reasoning
for each is in `docs/feed-design-decisions.md`. The ones that change existing
rules:

- **The app is the system of record for feed on hand.** Counts are truth. PB
  supplies usage pounds; Redwing receives our dollars. PB carries four negative
  balances and Redwing carries Salt at −5,457 lb with +$1,999.18 of value —
  neither can be trusted for custody.
- **Cut-over is 2026-09-01, BARN ONLY.** August and prior stay on the cost
  allocation; from 9/1 every lot charges actual feed. Silage is not being fed and
  is carried as a named reconciling item ($225,155). No backdating.
- **`feed_direct_from` must be a RANCH-LEVEL DATE, not the per-lot flag phase 4
  shipped.** (It only bites on lots that HAVE a non-feed rate — see the
  one-number rule under phase 4.) That flag has no date and rewrites a lot's whole life: setting it on
  36-27 on 9/1 would re-price August from $2.00 to ~$1.00/hd/day with no actual
  feed to replace it — about $6,400 evaporating. The closeout must SPLIT
  head-days on the date.
- **Several app items may map to ONE Redwing template box.** Do NOT merge "Corn"
  and "Corn hopper bin" — PB encodes the bay in the commodity name, and that is
  the only signal telling an import which pile was fed. This reverses earlier
  advice in OPEN-ITEMS.
- **Silage shrink is haircut at ENTRY** (gross × (1 − allowance), full harvest
  cost held), so no revaluation mechanic is needed. Store gross, allowance and
  booked separately — actual shrink calibrates on GROSS, never on booked, or each
  year's estimate error compounds into the next.
- **Barn shrink goes to a two-sided variance account, never to a lot.** Its
  balance is the accuracy of the allowances, so found feed must credit the same
  account. Do not build allowance machinery for purchased commodities yet —
  haircutting a scale-ticketed load breaks the invoice and Redwing tie.
- **A count variance means different things per item.** Barn commodities: we know
  what was fed, so it is SHRINK. Mineral: no feeding record exists, so it is
  CONSUMPTION, allocated by head-days across every open lot. One per-item setting.
- **The observed cost-per-pound-of-gain read-out stays on REALIZED ADG only.**
  John's assumed ADG is deliberately biased low; converting a $/lb cost rate
  through it makes the cost projection optimistic ($94/head in the worked
  example) while the revenue side is already conservative. **Superseded in
  part 2026-09-04:** the `per_lb` COG mode (Closeout section) does charge a
  $/lb rate on assumed-ADG gain, by John's decision, and mitigates this by
  truing up to real pay weights as head ship and warning when the shipped
  head ran ahead of the assumption.
- **A premix short is not an ordinary short.** It means the ingredients are still
  on the books — two errors, and the feed still allocates cleanly so nothing looks
  broken. That is how PB reached −1,109,171 lb. It needs its own anomaly wording.
- **Shrink surfaces as a bay that will not go to zero, not as going short.**
  Physical < book = book balance survives on an empty bay. Going short is the
  opposite signal: a delivery was never entered.

### Cost of gain and premixes (phase 4, live 2026-08-27)

- **Feed cost spreads over head-days INSIDE each usage's period**, never onto
  one date. `lot_feed_daily` divides a usage across the days in
  `[period_start, period_end]` in proportion to `lot_daily_head.head_on_hand`.
  Verified on 36-27's real curve: 31,630 lb over Aug 17-26 spreads to the
  penny and sums back to $2,501.14.
- **`feed_cost_unallocated` exists because a JOIN would drop it silently.** A
  usage whose period holds no head-days for its lot cannot spread; rather than
  vanish, it surfaces there and on `lot_feed_costs.unallocated_usd`, and the
  Closeout warns.
- **`lots.assumed_nonfeed_cog_per_day` is the COG split, per lot, NULL until
  known — and NULL means COG IS ONE NUMBER.** John, 2026-09-04: "I consider
  COG to be feed and non-feed cost of gain … for now I think in terms of one
  number." While NULL the assumed COG rate is charged on every head-day, the
  feed cut-over date is ignored for that lot, and actual feed shows as a
  **memo row, never added** — the rate already contains it. There is no
  overlap warning and no Anomalies finding for a missing non-feed rate any
  more. Set the rate (Closeout → working assumptions, saved with the rest)
  and that lot switches to actual feed plus the non-feed rate from the
  cut-over. Nothing recomputes retroactively.
- **Forward feed rate is dollars-since-cut-over over head-days-since-cut-over**
  (`currentFeedAfterBoundary / hdAfter`), not the view's `cost_per_head_day`,
  which divides by the lot's whole life. On 36-27 that view read five cents a
  head-day off one day of mineral over 8,931 head-days and carried ~$4,000
  to March. Whole-life is the fallback only when the split is not loaded.
- Feed carries forward in the Projection at the lot's own observed $/hd/day,
  the same treatment cost already gets.
- **A premix is many-in-one-out**: `make_feed_batch` consumes N commodities
  FIFO, sums the frozen dollars, and creates ONE layer for the premix in its
  own bay. No second costing path — the premix is then an ordinary item.
  `delete_feed_batch` refuses once any of it has been fed.
- **Recipes only PRE-FILL.** Actual weights freeze onto the batch. A recipe
  read at cost time would rewrite what every past batch was made of.
- **Feed the premix, never the premix AND its ingredients** — the ingredients
  were consumed when the batch was mixed. Double-counting still allocates
  cleanly, so nothing looks wrong.
- Yield: output pounds = sum of inputs (John's call). `output_qty_lb` is
  stored, not derived, so weighing a batch later is a form field.
- **`post_feed_usage` gained `p_batch_id` and was DROPped and recreated**, not
  overloaded — PostgREST resolves an RPC by argument names and two overloads
  make that ambiguous. The verify block asserts exactly one exists.

## Inventory flow: order → delivery → invoice (wave 1 live 2026-08-31)

Migration: `docs/sql/2026-08-31_inventory_flow.sql`. All 23 decisions with the
reasoning and the rejected alternatives: `docs/inventory-flow-design.md`.
Office+owner only. **The `Feed` tab is now `Inventory`.**

```
reorder signal ─▶ supply_orders ─▶ supply_order_lines ─┐ (one line, many loads)
                                                        ▼
vendors                                          feed_receipts  ← THE FIFO LAYER
                                                        │  costed at the ORDERED price
                                                        ▼
                                supply_invoices ─▶ supply_invoice_receipts
                                                        │  difference only
                                                        ▼
                                                feed_price_variance
```

- **One spine, two ledgers.** `supply_order_lines` carries `item_kind` plus
  `feed_item_id` / `medication_id` with a CHECK that exactly one is set. Meds
  join as a receiving handler, not a second set of screens. Ordering,
  invoicing and the worklist are shared; consumption and costing are not.
- **A delivered load is costed at the ORDERED price**, so feed stops reading
  free until the bill arrives — which was the status quo and is the same
  `SUM()`-ignores-NULL failure the feed module was built to avoid.
  `cost_pending` is now the flagged exception, not the normal path.
- **When the invoice differs, the layer is corrected GOING FORWARD and the
  already-consumed difference is booked to `feed_price_variance`.**
  `feed_usage_costs` is never rewritten. Restating frozen costs would reopen
  closed lots and prior fiscal years exactly the way editing a drug price
  does — processing cost with a slower fuse.
- **The invoice adjustment rides on `feed_receipts.other_cost`**, whose `>= 0`
  check is relaxed because a bill can come in low. `total_cost` and
  `unit_cost_per_lb` are generated from the three cost columns and FIFO reads
  `unit_cost_per_lb`, so one of them has to move; `product_cost` and
  `freight_cost` keep saying what was agreed. The audit trail lives on
  `supply_invoice_receipts` (what the bill said) and `feed_price_variance`
  (what it cost us), not on that column.
- **A load that arrived UNPRICED takes the other path.** Its usage costs are
  NULL holes, not frozen numbers, so matching an invoice fills them through
  the existing `recost_pending_usage()` and writes NO variance row.
- **Orders are optional in the schema and leading in the screen.**
  `feed_receipts.order_line_id` is nullable. Requiring it would have people
  typing fake orders to record a load that turned up unannounced — into the
  very table the reorder alerts read from. An unordered load shows as an
  exception instead.
- **A line with `qty_lb` NULL is a REMINDER-ONLY line** — "Mark ordered" with
  nothing else typed. That is the whole med workflow John described. Any
  receipt for that item auto-closes it, so there is nothing to tidy.
- **`record_feed_delivery()` is the only way a new layer is created from the
  app.** The insert, the order-line close and the reminder close are one
  atomic step, and a field-app caller later is a caller, not a second
  implementation. Editing a delivery is still an ordinary UPDATE — it moves
  no order state.
- **Deleting a delivery reopens the line it closed** (`fdReopenOrderLineIfEmpty`),
  but only when nothing else is left on the line AND the app closed it on
  delivery. A line closed by hand — "that's all they're bringing" — was a
  decision, not a side effect. **This lives in the app, not in
  `delete_feed_receipt`; move it into the RPC next time that RPC is touched.**
- **An invoice can be created and deleted, not re-allocated.** Same posture as
  a saved shipment. `delete_supply_invoice` refuses once variance has been
  booked, because unwinding it would leave frozen usage costs at the invoice
  price while the layer went back to the ordered one.
- **Tie out first, allocate only on a difference.** If the bill matches the
  sum of what those loads expected to cost, every load keeps exactly its own
  number and nothing is booked. Otherwise the difference spreads pro-rata by
  pounds (largest-remainder, sums EXACTLY) or is typed per load.
- **This is NOT accounts payable.** Redwing owns the payable. No due dates, no
  payment status, no aging, no check numbers.

### The one list

`inventory_needs_attention` (view) is the single definition behind the
Needs Attention sub-tab, the count badge on the Inventory tab, and the 7am
email in wave 3. Ten row kinds; four of them (`bay_short`, `premix_short`,
`count_overdue`, `feed_unallocated`) already existed and were merely
ungathered.

- **A row appears because a FIELD IS EMPTY, not because someone wrote a note.**
  A reminder you must remember to set is a reminder for the days you did not
  need one, and it never clears itself. `paperwork_done` is the one deliberate
  "stop asking", recording who decided and when.
- `source` auto-exempts: `count_adjustment`, `transfer_in`, `batch_out` and
  `opening_balance` never expect a ticket or a bill.
- **Rows age visibly.** *Awaiting invoice — 34 days* is a phone call;
  *— 3 days* is the post.

### Inventory tab layout

**Sub-tabs are the ACTIVITY; the material chip is what you are doing it to.**
Feed shows eleven sub-tabs, Meds shows the four material-agnostic ones.
Adding fuel or parts later is a chip and a `data-material` attribute, not
another screen. Materials-as-sub-tabs was rejected: Orders under Feed and
Orders under Meds are two screens, and a vendor billing both on one invoice
would have nowhere to file it.

- `Loads In` became **Deliveries**; the old `Inventory` sub-tab became **On Hand**.
- **The group menu (`.sub-group` / `.group-menu`) is shared, not Inventory's.**
  `subGroupToggle()`, `subGroupsClose()` and `subGroupsRelabel()` sit with the
  sub-tab wiring; one document-level click closes any open menu. The Reports
  bar uses the same shape (2026-09-03): Active Lots · Daily Report ·
  Anomalies stay flat, **Pastures ▾** holds Yard Sheet and Pasture
  Utilization, **Health ▾** holds Receiving, Doctoring & Deaths and Death
  Analysis. Settings is the LAST top-level tab. Do not write a third copy of
  the menu logic for the next bar that grows.
- **The medications catalog stays under Animal Health.** Dose, `round_up_to`,
  price and protocol membership are a doctoring tool read by the field app's
  pickers. Inventory → Meds will hold the *stock*. One drug, two screens.

### Day-one data lesson (worth keeping)

The vendor seed crashed on `vendors_name_uniq` because it deduped with
`DISTINCT btrim(vendor)` against a unique index on `lower(name)` — three
capitalisations of "Beginning Inventory" survived and collided. **A seed
feeding a case-insensitive index must dedupe the way the index does.**

The quieter half mattered more: the marker exclusion list had been written
from a snapshot taken an hour earlier, and five hand-entered opening balances
had appeared since. They would not have crashed anything — they would have
nagged for a weight ticket forever. The verify block now asserts that no
bookkeeping marker became a vendor.

### Wave 2 and 3 — decided, not built

- **Wave 2, reorder.** `on_hand ≤ greatest(floor_qty, daily_burn × (lead_time +
  safety))`; blank means silent, so silage never alerts. Burn comes off
  `lot_feed_daily`'s spread — never off `usage_date`, or a weekly ticket reads
  as a Friday spike — over `least(21, days since first usage)`, suppressed
  below 7 days. The alert is DERIVED; only `was_low_at_last_check`,
  `last_notified_at` and `snoozed_until` are stored. Notify on the transition
  into low, re-notify every 7 days, zero-on-hand breaks a snooze.
  It goes second because **it cannot be tested before there is a week of real
  feed-out to sanity-check the computed lb/day against.**
- **Wave 3, the 7am email.** The app writes to a `notification_outbox`; a
  sender decides how it travels, so a failed send is a visible row rather than
  a silent nothing. Same machinery OPEN-ITEMS #7 needs for the daily report.
  Blocked on John: a Resend account with a verified domain, and `pg_cron` +
  `pg_net` enabled. 7:00am pinned to `America/Chicago`.

## Feed truck (phase 1 built 2026-09-04; phases 2-3 designed)

Design record with all 21 of John's decisions: `docs/feed-truck-integration-scope.md`.
Migration: `docs/sql/2026-09-04_feed_truck.sql` (tested locally on PG16 against
a stub schema, idempotent). Office+owner screens under Inventory → **Truck ▾**:
Loads · Tie-out vs PB · Rations · Pastures & route · Trucks · Settings.

```
bunk_reads ─▶ feed_loads ── feed_load_lines (item, bay, scale_lb, lb)   ← the feed app (phase 2)
                  └──────── feed_drops ── feed_drop_lots (lot, head, lb)
                                 │  post_feed_load()  (prior-day, on/after cut-over)
                                 ▼
                            feed_usage (source='truck')  ← feed_load_usage links them for unpost
```

- **Parallel first (D1).** Truck pounds live in their own tables and never
  touch `feed_usage` until `ranch_settings.feed_truck_post_from` is set. PB's
  Monday entry keeps posting meanwhile. The tie-out views
  (`feed_truck_tieout`, `feed_truck_tieout_headdays`) compare lb per lot per
  commodity per PB week (Mon–Sun) and the split head vs `lot_daily_head` on
  the same days. Set the date only when the tie-out has held; from then the
  Monday PB entry must STOP for those weeks or feed is charged twice.
- **Hard rules from John:** scale is the only source of pounds, nothing
  advances without a tap, **no feed until the mix timer hits zero (no
  override)**, no deleting a drop or cancelling a load.
- **A load posts what left the bays, over the lots it dropped to.** Each
  line's `lb` splits across lots pro-rata by dropped pounds (`lr_split`,
  largest-remainder, sums exactly) and goes through `post_feed_usage` one row
  per (line, lot), dated the load date. Left-in-box is therefore charged to
  that load's lots and the NEXT load draws less (Distribute cut its targets
  by the leftover). Nothing is stored per drop per commodity. Composition is
  frozen on `feed_load_lines`; `scale_lb` is never overwritten, `lb` is what
  the books use, `edited_*` says who overrode and why.
- **Editable until posted, one-day grace, unpost to fix.** `post_due_feed_loads()`
  runs when the Inventory tab opens (office/owner, throttled 10 min) and posts
  closed loads dated BEFORE ranch today. `feed_load_guard()` freezes lines,
  drops and splits of a posted/void load; `unpost_feed_load()` reverses via
  `delete_feed_usage`, reopens the load with rows intact. `void_feed_load()`
  needs a reason and refuses a posted load. Status cannot be set to
  posted/void by hand (`feed_loads_status_guard`, bypassed only inside the
  RPCs via `set_config('feed_truck.rpc','on',true)`).
- **A bunk read frozen into a load cannot change its call**
  (`bunk_reads.frozen_load_id`, guard trigger); route order and notes may.
  Void clears the freeze.
- **`split_drop_to_lots()` is the fallback**, not the rule: the feed app
  writes the head split from what it cached at the barn; posting fills any
  it missed from open assignments on the load date (`moved_out >= date`
  counts, cattle that left that day ate that morning).
- **Ration cap on the ration (`max_load_lb`), optional `feed_trucks.capacity_lb`,
  smaller wins.** `pasture_feed_setup.one_pass` = never split across loads.
  `ration_since` is stamped by trigger on every ration change (a step-up).
- **RLS:** setup tables read operational / write office+owner (ration_lines
  DELETE includes office because the screen rewrites lines whole); truck
  tables insert/update owner+office+crew, crew only while the load is open,
  DELETE owner only; `feed_load_usage` books-readers. All three views
  `security_invoker`. **`ranch_settings` UPDATE widened to office** (was
  owner) so office can set the four truck settings; that row also carries
  `feed_direct_from`.
- **Posting refuses** a load with no dropped pounds ("void it and let the
  next load carry the pounds"): the bays are then over-stated by that
  leftover until a count. Rare; documented, not solved.
- **Phase 2, `feed-app/` (built 2026-09-04).** Third PWA beside
  `field-app/` and `tally-book/`, same sign-in and boot-error pattern.
  Tabs: Bunks · Plan · Truck · History · More. `planner.js` is a pure
  module (`node feed-app/planner.test.js`, 300 random plans fuzzed for
  conservation of pounds); `app.js` holds the rest. Verified end to end in
  headless Chromium against a stubbed client (`/tmp/smoke` harness, 36
  assertions: prefill, stepper, save, plan, start, countdown bands, Done
  per ingredient, mix gate, two drops with the head split, an edit with a
  reason, close with leftover, queue drained, leftover carried forward).
  - **Every truck row carries a client uuid and syncs by `upsert(onConflict:
    'id')`** from a localStorage queue, load row first then lines, drops,
    lot splits. NOT by `client_id`: the partial unique indexes on it do not
    satisfy `ON CONFLICT (client_id)` without the predicate PostgREST
    cannot send. Rows queued while a sync is in flight go on the next round
    (`queueGen`), not the 45 s timer.
  - **Bunk calls save straight to the ranch and need signal** (D15); the
    screen says so. Every pasture on the route is saved, so an untouched
    bunk still carries yesterday's lb/hd (D4). Saved via
    `upsert(onConflict:'read_date,pasture_id')`. A read the truck has
    loaded is locked on screen and by the DB guard.
  - **Scale bridge:** the shell calls `window.FeedScale.onWeight({lb,
    stable, deviceId})` / `.onStatus({connected, deviceId, name})`; the
    page posts `{cmd:'zero'|'scan'}` to the `FeedShell` JavaScript channel.
    A reading older than 5 s is "no link" and every Done disables. Contract
    in `feed-app/README.md`. **The head stays in gross**; each ingredient
    and drop is a difference in gross since its tile was selected / Start
    was tapped, so the cab indicator and the iPad always agree.
  - **Simulated scale** (More › Simulated scale): slider + Auto
    filling/emptying at 400 lb/s. It is how everything is tested in Safari.
  - `_ui` on a local load (current tile, start gross) is device state and
    is stripped before sync (`loadRow`).
  - **Two orders (2026-09-05/06, John):** `pasture_feed_setup.route_order`
    is the feed route the truck drives, `read_order` the bunk-reading walk.
    Migration `docs/sql/2026-09-05_feed_truck_read_order.sql` adds the
    column, lets crew UPDATE the table and a trigger refuses a crew update
    that touches anything but the two orders. Both apps reorder by
    **drag with a lock** (pointer-event sortable, because iPad Safari has no
    touch drag-and-drop): office Pastures & route has an "order by" select;
    the feed app drags the reading order beside the bunk page and the route
    under Plan. Order changes from the cab go as UPDATEs keyed on
    `pasture_id` (`queueOrder`), never upserts - an upsert is an INSERT
    first and crew may not insert a setup row.
  - **Bunk calling is SDSU slick-bunk with John's fast/slow rule (2026-09-06).**
    Scores 0 / ½ / 1 / 2 / 3 (`bunk_reads.bunk_score` is numeric(2,1));
    clean = 0 or ½. Migration `docs/sql/2026-09-06_bunk_scoring.sql` adds
    `rations.dry_matter_pct` + `expected_dmi_lb` and six bump rules on
    `ranch_settings` (defaults: below expected DMI bump +0.75 lb DM after 2
    clean days; at/above +0.5 after 3; score 1 holds).
    **Cuts are PERCENTAGES, bumps are pounds of DM** (John, 2026-09-06: "I
    want to cut percentages, 3 usually means a big cut"). Migration
    `docs/sql/2026-09-06_bunk_cut_pct.sql` adds `bunk_cut2_pct` (10) and
    `bunk_cut3_pct` (25); the old `bunk_cut*_lb_dm` columns stay as the
    audit of the previous rule and are no longer read. A cut is a
    proportional pull-back, so it has to scale: half a pound off a pen
    eating 16 lb DM is a 3% trim nobody notices, and the same half pound
    off starter cattle eating 7 is twice the cut. A bump is closing a gap
    to a target intake that is itself in pounds, so it stays in lb DM.
    `suggestCall()` in the feed app turns the tapped score into
    today's lb/hd (as-fed, quarter-pound), writes `suggested_lb_per_head`,
    `clean_days` and `suggest_note` beside the call so a hand adjustment is
    visible later. `cleanStreak()` walks the read history back from
    yesterday and stops at a bump (lb/hd rose that day) or a missing day.
    No DM % on the ration → the bump is taken as-fed and the screen says so.
  - **Expected intake is a PERCENT OF BODY WEIGHT, not a fixed lb/hd**
    (2026-09-06, John). Migration `docs/sql/2026-09-06_bunk_weather.sql` adds
    `rations.expected_dmi_pct_bw`; `expectedDmi()` multiplies it by the
    pasture's head-weighted `lot_status.projected_current_weight`, so the
    target climbs as the cattle grow. `expected_dmi_lb` survives as the
    fallback when no weight is known, and the screen names the basis it used.
    The read stores `est_weight_lb` and `expected_dmi_lb` so a call can be
    read back against what it was working from.
  - **Weather is STORED, not just shown** (`daily_weather`, one row per ranch
    day from Open-Meteo — free, no key). The feed app refreshes the last week
    plus two days at the barn where there is signal; consumption gets read
    against it. `ranch_settings.ranch_lat/ranch_lon` (default Kosse) set the
    location. Silent on failure — the trend matrix just shows a dash.
  - **The trend matrix shows what was DELIVERED, not what was called.**
    `deliveredOn()` sums the done drops for that pasture that day; a day that
    was called but never dropped prints the call in grey with an asterisk, so
    a skipped pasture is visible instead of looking fed.
  - **Quick adjust is a percent of YESTERDAY'S call**, never of today's
    edited number — tapping −5% twice must not compound. The **10% shock
    guardrail** asks once at save, naming each pasture more than a tenth off
    its own three-day average; it catches an extra zero and does not block.
    Flags (mud, sick pull, waterer, storm) and a note ride on the read.
  - **Bunk page is one pasture per screen** with prev/next and the reading
    order down the side (PB's shape, John's ask). **Plan is PB's Delivery
    overview**: one card per load, pens with Target/Fed and a Total, then
    feed with Target/Loaded; today's run loads show actuals in the same
    cards. Ration lines carry no bay on the office screen (John: not
    needed); `default_location_id` is filled from the item's usual bay and
    the loader can change it per load.
- **Not built yet:** phase 3 Flutter shell (Scale-Tec template + WebView +
  bridge; iPad build needs a Mac with Xcode and John's individual Apple
  developer account, started 2026-09-04 week), the two charts on the bunk
  page, Anomalies rows for over-tolerance / skipped mix / overrides.

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

## SQL conventions

- ALL migration/correction SQL must be idempotent (IF NOT EXISTS, guarded DO
  blocks that RAISE EXCEPTION if state isn't as expected).
- Any direct data correction APPENDS an audit note to the row's notes column
  (what changed, why, date).
- In RAISE NOTICE strings avoid bare `%` collisions; never nest $$ in DO blocks.
- Watch PL/pgSQL name collisions between loop variables and table aliases
  (use row_rec, rn — a FOR var named `r` once shadowed `ranches r`).
- Errors must never be silently swallowed — surface them to the user.
- `to_regclass()` resolves views and sequences too, not just tables. Check
  `relkind` before `ALTER TABLE`, or a view in a table list aborts the whole
  migration and silently leaves everything after it unprotected.

## Migrations (CLI not yet adopted)

**The remote has NO CLI migration history** — this schema was built through the
dashboard and SQL editor. `supabase db push` would try to apply every local
migration from scratch against tables that already exist.

Until that is reconciled, apply migrations through the **SQL editor**. To adopt
the CLI: `supabase link --project-ref xpfmebdzcxorvwikfvtj` → `supabase db pull`
for a baseline → mark it applied → verify with `supabase migration list`.

Migration files here carry explicit `begin;`/`commit;` so they are
all-or-nothing in the SQL editor. **Strip those two lines if applying via the
CLI** — it wraps migrations in its own transaction and the inner `commit;`
closes it early.

## App code conventions

- Vanilla JS, no framework, one <script> block. Supabase JS v2 via CDN.
  jsPDF + autotable via CDN for shareable PDFs.
- After ANY edit: validate the big script block parses (new Function) and
  that <div> open/close counts balance outside script/style. Ship only if both pass.
  There is no node on this machine — run `osascript -l JavaScript
  scripts/validate.jxa.js index.html`, which does both checks on JavaScriptCore.
- Tiles on lot detail use buildTileRows() row-style (label left, value right).
  **Every tile row is a drill-down** (2026-09-04): a row carries `drill`
  (a lot section name, `deaths`, or `receiving`) and `lotDrill()` routes
  one delegated click. `receiving` leaves the lot for Reports → Health →
  Receiving with the lot pre-picked via `processingReportPendingLot`.
  Closeout table rows and the remnant / gain tiles drill the same way
  (`.co-drill`); `input:calc_cog` style targets land on that assumption
  input, focused. A drill into Sales or Closeout is refused when the role's
  CSS hides that tab, so crew never opens a dollar section from a head tile.
  A drill that LEAVES the lot (Receiving report, feed cost) shows
  `#drillBackBar`, "← Back to lot 60X", which reopens the lot in the section
  you left. It is set AFTER the navigation because `clearAllNavActive()`
  clears it: leaving by the main nav means done with that lot.
- **Fresh Cattle is its own report** under Reports → Health (2026-09-04),
  `reportFreshView` / `initFreshCattleReport()`. It used to sit above
  Processing Cost on the Receiving page.
- **The lot page is one section per PROCESS** (John's sketch, 2026-09-04):
  Currently in · Purchases (invoices, unlinked load outs, tags) · Animal
  Health (doctoring, deaths) · Moves (moves, transfers, merge) · Sales ·
  Closeout · Audit log. `showLotSubtab()` switches; `LOT_SECTIONS` is the
  list; `'activity'` still maps to `current` for old call sites. **The
  section and scroll position survive a re-render of the SAME lot** — every
  action calls `showLotDetail(currentLot.id)`, and before this that threw
  you to the top of one long page after each death or invoice. Only opening
  a different lot starts at Currently in. **The audit log loads only when
  its section is opened** (`auditLogLoadedFor`); it is the heaviest read
  on the page and John's note says "only open if selected". Tab counts are
  read off the card counts the loaders already write (`refreshLotTabCounts`)
  rather than taught to ten loaders.
- **Break-even tiles divide by head SOLD, never by head still here.** The
  lot-header floor tile did `total_cost / (head_now × weight)` and read
  $27.16/lb on 60X's last 29 of 251 head; the closeout row and remnant
  block had the same shape. All three now use surviving head (`head_in −
  head_dead`, or `headSoldAtClose` in the projection).
- Modals: showModal()/hideModal(); alerts via showAlert(id, msg, type).
- Print/share pattern: window.open + document.write for print; jsPDF +
  navigator.share({files}) for textable PDFs, download fallback on desktop.

## Working style (owner preference)

- Terse, decisive. Offer A/B/C options with a recommendation ("my vote");
  he often replies "all your votes."
- Ask before building anything significant; push back on scope creep.
- Investigate before correcting: for data issues, query first, show findings,
  propose the fix, wait for approval. Never delete data on your own initiative.
- Production DB is the live books of a real ranch. Schema changes and data
  corrections require explicit approval before execution.

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
