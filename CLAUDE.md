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
shipments ──┬── shipment_weight_groups ── shipment_loads
            ├── shipment_deductions
            └── sales (one per lot) ── sale_sources (one per lot+pasture)
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
- **Allocation order is weight-then-money, and it is load-bearing.** Weight is
  allocated by head *inside the line's own weight group*; dollars are then
  allocated by the resulting weight. That ordering is what makes the eventual
  per-pasture weight override a small change — override the weight and the
  money re-follows on its own.
- **Per-GROUP head must tie, not just the shipment total.** A group's pay
  weight is divided across the head assigned to it, so 298 head of sheet
  against 250 head of allocation makes those 250 each absorb the missing
  animals' weight, and every lot in that group books heavy. The shipment
  total can look perfect while this is wrong. `shpValidate()` blocks it.
- **Allocation uses largest-remainder, and the parts sum EXACTLY.** Not
  "round each and dump the residual on the last line" — that works too, but
  always parks the error on whichever lot was typed last. Verified against the
  2026-08-21 Thigpen sheet: 549 hd, 446,194 lb, $320.00/cwt, $1,427,820.80
  gross, $1,098 checkoff, $1,426,722.80 draft, all ties exact.
- **A saved shipment cannot be re-allocated in place.** Changing who shipped
  what would unwind head math that already happened. Delete and re-enter.
- **Deleting a shipment does NOT return cattle to their pastures** — same wart
  as deleting a single sale. A `delete_shipment_with_reversal` RPC is the
  right fix and does not exist yet. Note the CLAUDE.md warning about reversals
  that reopen a closed assignment: reopening already restores the count, so
  adding head back on top double-counts.
- **Shrink is an input, not a display.** The buyer writes gross and a shrink
  %, and pay weight falls out. An explicit pay weight overrides. The old
  single-lot sale form takes gross and net and only shows shrink afterwards;
  it is unchanged and still works that way.
- **`shipments` and its children are office+owner on SELECT too**, unlike
  `sales`/`sale_sources`, whose SELECT policies include crew. That existing
  inconsistency was left alone rather than widened or silently changed.
- The buyer's own lines are TRUCKLOADS. Mapping loads to lots and pastures is
  entirely our side; `shipment_loads` exists only so the app can catch a
  transposed weight at entry instead of in closeout six months later.
- `shipment_reconciliation` (view) answers "does this STILL tie", which is a
  different question from the save-time check — it catches later edits to an
  allocated sale. Non-zero variance shows as ⚠ on the Sales list.

Migration: `docs/sql/2026-08-26_shipments.sql`.

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
- Historical scar tissue exists from pre-hardening eras; old lots may carry
  reconciliation notes. Read row notes before "fixing" anything.

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
Also parked: breakeven budget-vs-actual, bottle inventory, lot comparison
report, weather integration.
