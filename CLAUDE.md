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
  FROZEN per row at save time).
- Processing $/hd is per head IN; Treatment $/hd is per LIVE head current.

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
- **Cost of gain and labor are charged against head-days, never against
  today's head count × total days.** Cattle that shipped in June ate grass
  until June. On 37X-1 the old math charged 75 head × 231 days = 17,325
  head-days against a real 56,993 — about $39,700 of cost that appeared
  nowhere.
- A **per-head** (flat) COG or labor rate is charged once on `head_in` and
  never carried forward again. Only **per-day** rates accrue on head-days.
- **Interest** accrues on the cattle for the whole period and on operating
  cost at half the period, the usual convention for a cost that builds
  linearly. The old screen charged interest on the purchase price only.
- Treatment carries forward at the lot's own observed $/head-day, not at the
  budgeted med figure — once there is history, the lot's own burn rate beats
  an assumption.
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

| | crew | office | owner |
|---|---|---|---|
| Read operational data (lots, weights, tags, doctoring, pastures, movements) | ✅ | ✅ | ✅ |
| Write field data (doctoring, weights, tags, receipts, pasture assignments) | ✅ | ✅ | ✅ |
| Correct/update operational records | ❌ | ✅ | ✅ |
| Invoices, cost and margin data | ❌ | ✅ | ✅ |
| Delete lots, weights, medications, protocols, audit rows | ❌ | ❌ | ✅ |
| See the user roster | own row | own row | all |

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
  known.** While NULL the Closeout charges assumed COG unchanged, shows feed
  beside it, and says the two OVERLAP. Set it and that lot charges actual feed
  plus the non-feed rate. Nothing recomputes retroactively.
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

## Tally Book (built 2026-08-28)

A second PWA in this repo at `tally-book/`, alongside `field-app/`. Daily
bullet journal plus a project status register. Migration:
`docs/sql/2026-08-28_tally_book.sql`. It touches no ranch data.

- **`tally_entries` and `tally_projects` are scoped to `auth.uid()`, not to a
  role.** `user_id` defaults to `auth.uid()`; both policies are
  `USING (user_id = auth.uid())` with a matching `WITH CHECK`. Lauren is an
  owner and still cannot see John's book — a role is not a shared diary. The
  handed-over draft shipped with no RLS at all on the theory that it is a
  single-user app; in THIS database the `postgres` default ACL grants
  `authenticated` full DML on any new public table, so that would have handed
  every crew cowboy the journal through PostgREST.
- **Sign-in is shared across all three apps.** Office, field and tally book sit
  on one origin and all use Supabase's default storage key, so one sign-in
  covers all three — and signing out of any of them signs out of all of them.
  The tally book's sign-out button says so rather than surprising you.
- **`entry_date` is `public.ranch_today()` in the DB and an
  `America/Chicago` `Intl.DateTimeFormat` in the app**, never `CURRENT_DATE`
  and never `toISOString()`. Every read is keyed on the day boundary, so in
  UTC the whole book points at tomorrow from 7pm Central: today's log empties
  and everything just written jumps to "open loops". Same trap as
  `lot_daily_head`.
- **"→ today" keeps `status='open'`.** The draft set `'migrated'`, which took
  the entry out of the open-loops query while moving it to today, so a task
  pushed forward and left unfinished disappeared for good. `migrated`
  describes how a bullet arrived, not whether it is still owed.
- **Kill is a status, not a DELETE.** A mis-tap on a phone should not be
  unrecoverable. Killed rows drop out of the day's page and stay in the table.
- **Every write asserts on the returned rows** (`.select()` then check
  `data.length`) and both failure paths reach a visible banner. A refused
  write returns an empty result and no error — OPEN-ITEMS item 3 — and this
  app is the one place that does it from day one rather than relying on a
  `data-perm` gate.
- The Supabase client is **vendored** (`supabase.min.js`), not imported from
  `esm.sh`. A cross-origin ESM import is the one asset a service worker cannot
  cache, so offline would have meant a blank page.
- `sw.js` is a copy of `field-app/sw.js`'s network-first shell strategy.
  **Bump `CACHE_VERSION` and the `?v=` strings in both `index.html` and
  `APP_SHELL` together on every deploy**, or a fresh page pairs with old code.
- **No offline write queue.** Unlike the field app, an entry made with no
  signal is lost. Fine for the office; fix before relying on it out of range.

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
   CHECK constraint permits only those three. **Open decision:** whether a
   read-only `guest` role is still wanted; it does not exist today.
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
