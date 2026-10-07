# Handoff: charge medicine directly to a lot or a cost centre

Build spec for Claude Code. Written 2026-10-07 from a Cowork session. Everything
below is John's decision or read off the live database / repo at `395e5eb` — no
inference. Line numbers are as of that commit; re-find them before editing.

## John's decisions (2026-10-07)

- "We need to add the ability to charge medicine directly to a production center
  detail or WIP account. Similar to feed."
- The charge is for **all three**: non-lot production center details (cows, bulls,
  horses, feeder month buckets), **lots with no doctoring event** (pour-on, water med
  on a whole lot), and **WIP accounts**.
- Cost centres are **shared with feed** (one `cost_centers` list). A medicine
  cost-centre charge always books to **130000 Vet & Medicine – WIP**; the cost centre
  supplies only Profit Center / Production Center. The cost centre's own
  `redwing_account` (feed's account) is NOT used for medicine.
- Entry is **Inventory > Medicine, office only**. Not the field app.
- He approved the build ("Give me prompt for code to build it"). The schema change
  below is part of that approval — still show him the migration file before applying.

## What exists (read off live DB 2026-10-07)

- `cost_centers(id, name, redwing_account, redwing_production_center, profit_center,
  notes, is_active, …)`. One row: **Cow/Calf Wip**, no Redwing coding filled in.
  Managed in the app (feed's Cost centres modal, ~index.html 32259–32335).
- Feed's pattern: `feed_usage.destination_type` `lot | cost_center | …`, shape CHECK
  pins `cost_center_id` NULL on other destinations; `post_feed_usage(... p_cost_center_id)`;
  hand-entry usage UI ~33590–34000; Redwing report cost-centre section ~35405–35425,
  orphan guard `KNOWN` list ~35489. Read `docs/OPEN-ITEMS.md` §19 for the reasoning.
- Medicine leaves the shelf only through `med_consume(p_medication_id, p_location_id,
  p_qty_units, p_txn_type 'usage'|'adjustment', p_reason, p_ref_kind, p_ref_id,
  p_txn_date, p_notes, p_crew_member_id)` — FIFO per (med, location), period-lock
  bump to the first open day, uncovered usage allowed. `med_reverse_txn(txn_id)`
  restores layers and deletes the txn. Live `med_txns` kinds today:
  `usage/processing/delivery_receipt`, `usage/treatment/doctoring_event`, counts,
  opening, purchase, transfers.
- **Lot medicine cost does NOT come from `med_txns`.** `lot_med_costs_by_category`
  sums `doctoring_event_meds.cost` by `field_actions.category` (default `treatment`);
  processing also comes from `lot_processing_costs` (receipt × protocol). The lot page
  (~7276, ~7361–7401) reads `catTotal('processing' | 'treatment' | 'other')`.
  **`other` already flows into the closeout (~8603) and the lot tile (~9294) and
  nothing feeds it today.**
- `med_usage_by_lot` (view) resolves lot from `delivery_receipt` / `doctoring_event`
  refs; category = processing | treatment | `coalesce(reason,'other')`. Feeds the
  **Medication Application — Redwing (weekly)** report (~38552–38700,
  `renderInvApplication`). Rows with no lot render under "— no lot —".
- `med_roll_forward` counts every `txn_type='usage'` as Used — direct charges need no
  change there.

## Build

### 1. Migration `docs/sql/2026-10-07_med_direct_charge.sql` (idempotent, begin/commit)

- Table `med_charges`:
  `id uuid pk, charge_date date not null, medication_id → medications, location_id →
  med_stock_locations, qty_units numeric > 0, destination text check in ('lot',
  'cost_center'), lot_id → lots, cost_center_id → cost_centers, category text
  (processing|treatment|other, lot only), txn_id uuid → med_txns on delete restrict?
  (see undo), notes, created_by, created_at`.
  Shape CHECK like feed: lot ⇒ lot_id + category not null, cost_center_id null;
  cost_center ⇒ cost_center_id not null, lot_id null, category null.
- `post_med_charge(p_date, p_medication_id, p_location_id, p_qty_units, p_destination,
  p_lot_id, p_cost_center_id, p_category, p_notes) returns jsonb`: insert the charge,
  call `med_consume(..., 'usage', reason = 'lot_charge' | 'cost_center',
  ref_kind = 'med_charge', ref_id = charge id, ...)`, store `txn_id`, return
  `{charge_id, txn_id, total_cost, shortfall_units, cost_provisional, posted_date}`
  (posted_date differs when the period lock bumped it — say so on screen).
  Refuse an inactive cost centre and a closed/non-existent lot.
- `delete_med_charge(p_charge_id)`: `med_reverse_txn(txn_id)` then delete the charge.
  This is the entry-mistake undo, same role gate as other med deletes (owner/office —
  match `med_purchases_delete` style; check what doctoring delete allows).
- `lot_med_costs_by_category`: `CREATE OR REPLACE VIEW` with the **same columns in the
  same order**, `UNION ALL` lot charges grouped by `(lot_id, category)` with
  `total_cost = sum(med_txns.total_cost)`, `event_count = count(charges)`,
  `med_row_count = count(charges)`, `unpriced_row_count = count(*) filter (where
  txn.cost_provisional)`. Then re-aggregate so one row per (lot, category) — the app
  does `find(r => r.category === cat)` and would miss a second row.
  `security_invoker = true`.
- `med_usage_by_lot`: `CREATE OR REPLACE VIEW`, existing columns unchanged and in order;
  lot also resolves from `med_charges.lot_id` when `ref_kind = 'med_charge'`;
  category = the charge's category for lot charges, `'cost_center'` for cost-centre
  charges; **append** `cost_center_id, cost_center_name, profit_center,
  redwing_production_center` at the end. `security_invoker = true`.
- RLS on `med_charges`: select `can_read_books()`, insert/update owner+office, delete
  owner+office or owner — match the med tables. REVOKE from PUBLIC, anon on table and
  functions; GRANT to authenticated.
- **Connector warning (docs/feed-pb-import.md, 2026-10-03):** `apply_migration` /
  `execute_sql` stall and apply nothing when the SQL contains `DROP` or `DELETE`.
  `delete_med_charge`'s body contains DELETE. If it stalls, John applies the file in
  the Supabase SQL editor. Avoid `DROP VIEW` — the column-preserving `CREATE OR
  REPLACE` above is why.
- Prove transcription (md5 of prosrc vs file). Run rls_verify assertions (as separate
  selects if the DELETE in that script stalls).

### 2. App — Inventory > Medicine > **Charge out** (office only, `data-perm="office"`)

- Fields: date (default `ranchToday()`), medication, shelf (`invFillLocationSelect`),
  quantity in the med's unit (show bottles ↔ units using `bottle_size`), **Charge to**:
  Lot | Cost centre.
  - Lot: lot picker (open lots), **category** Processing / Treatment / Other (no
    default — must choose), optional note.
  - Cost centre: active `cost_centers`, plus a link to add/edit one (reuse feed's
    Cost centres modal; don't build a second manager).
- **Withdrawal:** if the med has `withdrawal_days > 0` and destination is a lot, warn
  "Whole lot in withdrawal until <date>" — never block.
- Post → `post_med_charge`. Show FIFO cost, any shortfall (uncovered) and any date bump.
- A list of recent charges (date, med, qty, to, $) with **Undo** → `delete_med_charge`.
- Crew never sees dollars.

### 3. Medication Application report

- Lot charges show inside each lot's block under the chosen category (they arrive via
  `med_usage_by_lot`). Category order: Processing, Treatment, Other.
- New **Cost centres** section after the lots: one block per cost centre, a line per
  medication. Account column = **130000 Vet & Medicine – WIP** (fixed), Profit Center
  and Production Center from the cost centre. Copy rows / Print / PDF include it.
  Total line: lots + cost centres = all usage in the range.
- Orphan guard: any usage row with no lot and no cost centre is listed loudly, never
  dropped (same promise as feed's `KNOWN` list).
- A cost centre with no Profit Center / Production Center filled in: show it with a
  "coding missing" flag, don't hide it.

### 4. Tests (before deploy)

Prefer the repo's local harness (`run-local.js`, `docs/sql/tests`) on a scratch copy.
If testing on live, do it inside a transaction that ends in ROLLBACK — **never leave
test charges on the books.**
- Lot charge: layer qty drops, `lot_med_costs_by_category` gains the amount under the
  chosen category, closeout "Other" (or chosen) line moves by exactly that.
- Cost-centre charge: lot views unchanged; Application report cost-centre section shows
  it at 130000.
- Undo restores layers to the unit and removes the row from every view.
- Charge into a counted/closed month posts to the first open day with the note.
- Shortfall (more than on the shelf) posts uncovered, flagged.
- Existing lots' processing/treatment totals unchanged after the view replace
  (compare a before/after select of `lot_med_costs_by_category` for all lots).
- `node scripts/validate.js index.html` passes; no duplicate top-level functions.

### 5. Deploy and document

- Update `docs/medicine-inventory-fifo-plan.md` (new "Direct charges" section),
  `docs/costs.md` (lot "Other" med now fed by direct charges), CLAUDE.md index row.
- Commit, push main, hard refresh, confirm live.
- Tell John: what's live, the test results, and that cost centres (Cows, Bulls,
  Horses …) need Profit Center / Production Center filled in before the Redwing rows
  are complete — Cow/Calf Wip has none today.

## Do not

- Do not add the charge to the field app.
- Do not change feed's cost-centre behaviour or its account.
- Do not create cost centres or fill in Redwing coding — John does.
- Do not leave any test charge on the live books.
