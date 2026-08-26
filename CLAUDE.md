# JFR Ranch Cattle Management App

Two apps, one repo, one Supabase project — the live books of JFR Ranch Co. Ltd.,
a stocker cattle operation in Kosse, TX. Owner: John Reagan. Stocker operation:
high-risk lightweight steers (275–350 lb in), ~11 ranches, ~60 pastures. Lots are
the core unit (e.g. 36-27, 37X, 47-26).

| | where | what it is |
|---|---|---|
| Office app | `index.html` at repo root (~800 KB, single file, no build step) | the books |
| Field PWA | `field-app/` (build v12) | cowboys' phones; writes only to staging |

Backend is Supabase (PostgreSQL + auth + PostgREST), project
`xpfmebdzcxorvwikfvtj`. Three roles — owner / office / crew — enforced by RLS.

**This file is the standing rules. The reasoning behind them, and the history of
what went wrong, lives in `docs/architecture.md` — read that before changing
anything structural.**

| doc | for |
|---|---|
| `docs/architecture.md` | how the system fits together, and why each rule below exists |
| `docs/roadmap.md` | what is next, in order, and what was ruled out |
| `docs/OPEN-ITEMS.md` | known gaps, deliberately not done yet |
| `docs/security-model.md` | RLS detail |
| `docs/processing-cost-and-protocol-versioning.md` | the full protocol-change procedure |
| `docs/handoff-spec-template.md` | how to write a handoff for in-flight work |
| `HANDOFF.md` | the field-app merge and the Part B build, as they happened |
| `docs/USER-ADMIN-GUIDE.md` | John's guide to adding and managing users |
| `docs/FIELD-APP-GUIDE.md` | the cowboys' guide to the field app |
| `docs/manuals/` | the same two guides as published HTML — **edit both or the published page goes stale** |
| `docs/sql/` | every migration and correction actually applied, dated |

## Deploy

- No build step. Deploy = commit + push to `main`; GitHub Pages publishes in
  1–3 min. Hard refresh (Cmd+Shift+R) after to bypass cache.
- The Supabase publishable key is embedded in both apps. That is expected and
  fine. **Corollary: anything GRANTed to `anon` is public.** Embedding the key
  is fine; granting `anon` anything is not.
- The field app ships with the office app. Bump `CACHE_VERSION` in
  `field-app/sw.js` on every field-app change, and `DATA_SCHEMA_VERSION` in
  `field-app/app.js` (currently 4) whenever the *shape* of cached data changes.

## The invariants (get these wrong and the books are wrong)

- **Fiscal year runs July 1 – June 30, named for the ENDING year.** Aug 2026
  arrival → FY 2027. The `derive_fiscal_year` trigger enforces it.
- **Head math:** `head_in − head_dead − head_sold = head_current`, and
  `head_current` must equal the sum of open `lot_pasture_assignments`.
  Divergence is "drift" and shows on the Anomalies report. **Never create drift.**
- **Processing is not treatment.** Processing (receiving meds) is captured on
  delivery receipts via `receiving_protocol_id`, never as doctoring events, and
  its cost is **derived live from current prices**. Treatment cost comes from
  `doctoring_events` + `doctoring_event_meds` and is **frozen per row at save
  time**. The two behave oppositely.
- Processing $/hd is per head **IN**; treatment $/hd is per **live head current**.
- **Editing a protocol's meds, or a medication's price or rounding, retroactively
  rewrites processing cost for every lot that ever used it** — closed lots and
  prior fiscal years included, silently, with no audit trail.
  `protocols.effective_from` is decorative; nothing enforces it. To change
  processing from a date: create a NEW protocol row (`parent_protocol_id` → old,
  new `version_label`, set `effective_from`), then `UPDATE
  delivery_receipts.receiving_protocol_id` on exactly the receipts on/after that
  date. Never edit the old protocol in place — the earlier loads genuinely got
  the old product and their books must keep saying so.
- **Keep `round_up_to` consistent between generic and brand of the same drug.**
  It models the syringe setting including waste, not drug consumed.
- **An unpriced medication prices as NULL, and `SUM()` ignores NULL** — the line
  silently vanishes instead of erroring. Price a med BEFORE pointing a protocol
  at it or approving anything that uses it, and check `unpriced_line_count`
  after any protocol change.
- **The database runs UTC; the ranch does not.** `CURRENT_DATE` becomes tomorrow
  at 7pm Central. Anything counting days uses `public.ranch_today()` in SQL and
  `ranchToday()` (pinned to `America/Chicago`) in the app — never
  `CURRENT_DATE`, never `toISOString()`.
- **Use `lot_head_days_by_month` (the view), not `lot_head_days()` (the
  function), for anything involving cost.** They disagree: the function anchors
  on invoice dates, the view on receipt dates. Cattle eat from the day they hit
  the ground.
- **Closeout is computed in total dollars and divided at the end** — never
  per-head math, which double-counts death loss. Cost of gain and labor charge
  against **head-days**, never today's head count × total days. A per-head
  (flat) rate is charged once on `head_in`; only per-day rates accrue on
  head-days. Closeout is office+owner only.
- **`lots.target_sale_cwt` is $/lb despite the name**, and
  `lot_budgets.budget_cost_per_cwt` follows it. Both multiply a weight in
  pounds. Do not "fix" one without the other.
- **`lot_budgets` is frozen by a trigger, not by a missing policy.** Office and
  owner deliberately PASS the RLS check on UPDATE so `lot_budgets_frozen()`
  fires and raises a real error. Owner-only DELETE is the escape hatch.
  Assumptions that change over the life of the lot stay on `lots.*`.
- Doctoring eligibility: pulls start 8–9 days after Draxxin at receiving; the
  fresh-cattle report window is 17 days.
- Tag numbers recycle across fiscal years. "Current animal for a tag" = the tag
  on an OPEN lot. Doctoring search scopes to open lots by default.

## Field → books approval path

Nothing a cowboy records reaches the books directly.

```
field PWA → pending_field_entries → office Approvals tab → RPC → books
         ↑ localStorage queue keeps this offline-first
```

- **`(entry_type, client_id)` is an UPSERT key, not a duplicate check.** The
  field app re-sends an edited record under the same client id and the second
  send must overwrite the first. Do not add a reject-duplicates constraint.
- **Statuses:** `pending → approved | rejected | withdrawn`; `withdrawn → pending`
  and `rejected → pending` (office reinstates/reopens); **`approved` is
  terminal.** `pfe_guard_settled()` enforces this in the DB.
- **There is no `'dead'` entry_type.** A death arrives as
  `entry_type='doctoring'` and is identified by `field_actions.is_dead` on its
  resolved action. Classify on `is_dead`, never on entry type.
- **Approval is all-or-nothing per batch.** If any row fails, `rollbackPosted()`
  unwinds what was already written. Deaths and moves post through their atomic
  RPCs so head math stays intact.
- **Order matters within a batch:** doctoring first, then deaths and moves
  sorted by `event_datetime`. Head-math entries must replay in the order they
  happened or a move can outrun the death that freed the head.
- **Cost freezes at approval, not at field entry.** The approvals screen flags
  unpriced meds — do not approve past that flag.
- **Never auto-create** ranches, pastures, lots, or medications from field text.
  An unresolved name is a review item, not a new row.
- Correcting a date on the approvals row shifts `event_datetime` by whole days
  and rewrites only the date half of `raw.dateTime`, preserving time of day.
  Guarded `.eq('status','pending')`.
- Deaths approve **without a cause** — cause is filled in later on the lot.
  Carcass disposal is flagged when the animal was **NOT** hauled off. (`drug_off`
  means removed to the proper location for dead animals; nothing to do with drug
  withdrawal.)

## Access control (RLS — read before touching auth, policies, or views)

The gate is `public.current_user_role()`. It reads `user_profiles.role` for
`auth.uid()` **and requires `is_active = true`**. Returns NULL for anyone
inactive or unknown; every policy is written so NULL denies. The
`user_profiles.role` CHECK permits exactly `owner`, `office`, `crew`.

| | crew | office | owner |
|---|---|---|---|
| Read operational data (lots, weights, tags, doctoring, pastures, movements) | ✅ | ✅ | ✅ |
| Write field data (via `pending_field_entries` only) | ✅ | ✅ | ✅ |
| Correct/update operational records | ❌ | ✅ | ✅ |
| Invoices, cost and margin data | ❌ | ✅ | ✅ |
| Delete lots, weights, medications, protocols, audit rows | ❌ | ❌ | ✅ |
| See the user roster | own row | own row | all |

Deletes are the narrowest privilege on purpose: `lot_movements`, `lot_events`
and `lot_pasture_assignments` are audit trails, and an accidental delete there
is unrecoverable in a way an accidental insert is not.

### Rules — each was a live hole in Aug 2026, not a style preference

1. **Never read a role, permission, or tenant from `raw_user_meta_data`.** That
   field is written by the client at signup. `handle_new_user()` trusted it and
   `signUp({data:{role:'owner'}})` minted a working owner account. The trigger
   is `AFTER INSERT ON auth.users FOR EACH ROW`, so this applies to
   `inviteUserByEmail` and `admin.createUser` too — never pass `data:{...}` with
   a role to either. Roles are set by an owner in `user_profiles`.
2. **New users land inactive** (`role='crew'`, `is_active=false`). A new account
   seeing zero rows is correct, not a bug. An owner activates it. Public signups
   are also disabled in the dashboard; both locks stay on.
3. **Every view must be created `WITH (security_invoker = true)`.** Without it a
   view runs as its owner and bypasses RLS entirely regardless of base-table
   policies. Ten views were exposed this way and readable by `anon` with no
   login at all. No exceptions.
4. **Never GRANT anything to `anon`.** `authenticated` + RLS is the only path.
   Revoke from `PUBLIC`, not just `anon` — Postgres grants function EXECUTE to
   PUBLIC by default, so `revoke ... from anon` alone silently does nothing.
5. **New tables need RLS *and* policies.** `ENABLE ROW LEVEL SECURITY` with no
   policy is a total lockout; policies without `ENABLE` are decoration.
6. **`SECURITY DEFINER` needs a reason and a pinned `search_path`.** Each one
   bypasses RLS. Seven are deliberate: `current_user_role` (the gate),
   `admin_list_users`, `guard_last_owner`, `handle_new_user`,
   `cleanup_attachment_storage`, `lot_projected_weight`,
   `lot_weighted_arrival_date`. Default to INVOKER — the head-math RPCs
   (`record_death_with_pasture`, `record_move_with_pasture`, the delete
   reversals) are all INVOKER and must stay that way.
7. **Assert 1–6 after any migration that adds a table, view, or function.**
   There is no standing verify script — `supabase/` does not exist in this repo
   (see `docs/OPEN-ITEMS.md` item 8). Until one is written, **every migration
   carries its own inline assertions**, as
   `docs/sql/2026-08-25_budget_and_head_days.sql` does.

**Last full sweep — 2026-08-26, all clean:** 28 tables, all RLS-enabled and all
carrying policies; 12 views, all `security_invoker = true`; zero objects in
`public` readable by `anon`; seven `SECURITY DEFINER` functions, all with a
pinned `search_path`.

### Offline/PWA consequences (the live field app depends on all three)

- An RLS denial on SELECT returns **zero rows, not an error**. "No lots" is
  ambiguous between not-authorized, offline, and genuinely empty. Call
  `current_user_role()` on load and distinguish all three, or every access
  problem looks like a sync bug.
- A write queued offline replays under **later** authorization. Queued Tuesday,
  synced Thursday, user deactivated Wednesday → `42501`. Needs a dead-letter
  path. Never a silent drop (this is animal health data), never infinite retry.
- Purge local stores on sign-out and on user change; IndexedDB knows nothing
  about RLS. Persist the write queue outside the auth session, keyed by user id
  — days offline can outlive the refresh token.

## Schema landmines (verified by painful trial and error — trust these)

- `doctoring_events.tag_number` is TEXT. `lot_tags.tag_number` is INTEGER.
- `doctoring_events` uses `recorded_by_user_id`; has NO updated_at.
- `lot_events` uses `created_by`; has NO updated_at.
- `lot_pasture_assignments` uses `recorded_by`, and `moved_in` / `moved_out` —
  NOT date_in/date_out. An OPEN assignment is `moved_out is null`.
- Meds junction table is `doctoring_event_meds` (NOT doctoring_medications).
- `load_out_destinations` FK to receipts is `receipt_id`.
- `sales` has BOTH gross_weight_lb and net_weight_lb — realized ADG and pay
  weights use **net**.
- `field_protocols` has default_med_1/2/3_id but NO dose columns.
- `pastures.name` — NOT pasture_name. `lots` has no `status` column; open means
  `closed_at is null`. Head counts live on the `lot_status` VIEW, not on `lots`.
- `pending_field_entries` has `reviewed_at`/`reviewed_by` and an `approved_ref`
  jsonb (`{kind, id}`) — there is no `approved_at`.
- `lots.start_tag` / `end_tag` describe the FIRST receipt only, not the lot's
  whole tag range. To resolve a tag to a lot: lot_tags → receipt ranges → and
  only then fall back to lots.start_tag/end_tag.
- Head-day math must NOT be built on `lot_pasture_assignments`: 37X's assignment
  history starts 2026-04-27 against a first invoice of 2025-12-04, so it would
  silently drop 144 days. `lot_daily_head` reconciles to `lot_status.head_current`
  by construction and is verified to do so on every lot.
- Supabase PostgREST caps results at 1000 rows — PAGINATE `lot_tags` and any
  large fetch. **PostgREST query builders are single-use** — a pager must take a
  builder *function* and call it fresh per page, not reuse one object.
- **The Supabase SQL editor swallows `begin;`/`commit;`** — a wrapped script can
  report "Success. No rows returned" without applying anything. Omit the wrapper
  when pasting into the editor; keep it in files meant for the CLI.
- **The MCP Supabase connector is READ-ONLY.** DDL and DML fail with
  `25006: cannot execute ... in a read-only transaction`. Every schema change
  reaches the database by John pasting it into the SQL editor — see
  "Handing over SQL" below.
- When unsure of a column name, QUERY information_schema — do not guess.
  **Exception: do NOT trust information_schema for GRANTS or PRIVILEGES.**
  `role_table_grants` only shows roles the *querying* user belongs to, so on
  hosted Supabase it returns an empty set for `anon` while `anon` in fact holds
  full grants. Use `has_table_privilege()` / `pg_class.relacl` for privileges.
  Columns and types are fine.

## Data-integrity architecture (do not bypass)

- Deaths, moves, sales, and receipt deletions go through atomic RPCs
  (`record_death_with_pasture`, `delete_death_event`, `record_move_with_pasture`,
  `delete_move_event`, `delete_receipt_with_reversal`, …) that keep pasture
  assignments in sync. NEVER raw-delete a receipt/death/sale/move from the app.
- **A reversal that reopens a closed assignment must not also add head back.**
  Reopening (`moved_out = null`) already restores the count; adding to
  `head_count` on top double-counts. This was a live bug in `delete_death_event`
  — 3 head, death of all 3, reversal, and the lot came back with 6. Fixed
  2026-08-25. Any new reversal RPC: test it against a lot whose assignment the
  event closed outright, not just a partial one.
- Load-out saves hard-block duplicates (same lot + date + head + tag range).
- Historical scar tissue exists from pre-hardening eras; old lots may carry
  reconciliation notes. Read row notes before "fixing" anything.

## Handing over SQL — copy/paste in chat, never a file

**John runs SQL by pasting it into the Supabase SQL editor. Give it to him in
the chat as a fenced code block he can copy straight out of.**

- **Never** hand him a file path, an attachment, or "see `docs/sql/foo.sql`".
  He should not have to go find a file, open it, or scroll a repo to run a
  migration. He has asked for this three times.
- Paste the **whole script in one block**, ready to run start to finish. If it
  is long, paste it whole anyway — do not split it into pieces he has to
  reassemble, and do not summarize it and offer the real thing on request.
- **Omit `begin;`/`commit;`** from the pasted version — the SQL editor swallows
  them and can report "Success. No rows returned" without applying anything.
- Say in one line what it does and what it should print when it works, so he
  can tell success from a silent no-op.
- **After** he confirms it ran, commit the same SQL to `docs/sql/` as
  `YYYY-MM-DD_what-it-does.sql`. That file is the record of what was applied —
  it is not the delivery mechanism.
- The MCP Supabase connector is READ-ONLY (DDL and DML fail with
  `25006: cannot execute ... in a read-only transaction`), so pasting is not a
  preference — it is the only path that works.

## SQL conventions and migrations

- ALL migration/correction SQL must be idempotent (IF NOT EXISTS, guarded DO
  blocks that RAISE EXCEPTION if state isn't as expected).
- Any direct data correction APPENDS an audit note to the row's notes column
  (what changed, why, date).
- In RAISE NOTICE strings avoid bare `%` collisions; never nest $$ in DO blocks.
- Watch PL/pgSQL name collisions between loop variables and table aliases (a FOR
  var named `r` once shadowed `ranches r` — use `row_rec`, `rn`).
- Errors must never be silently swallowed — surface them to the user.
- `to_regclass()` resolves views and sequences too, not just tables. Check
  `relkind` before `ALTER TABLE`, or a view in a table list aborts the whole
  migration and silently leaves everything after it unprotected.
- **The remote has NO CLI migration history** — this schema was built through
  the dashboard and SQL editor, and `supabase db push` would try to apply
  everything from scratch against tables that already exist. Apply migrations
  through the **SQL editor**, and keep the applied file in `docs/sql/`, named
  `YYYY-MM-DD_what-it-does.sql`. Adopting the CLI is in `docs/roadmap.md`.

## App code conventions

- Vanilla JS, no framework, one `<script>` block. Supabase JS v2 via CDN in the
  office app; **vendored pristine from npm (2.46.1) at
  `field-app/supabase.min.js`** in the field app — never concatenate it with
  anything. jsPDF + autotable via CDN for shareable PDFs.
- After ANY edit to `index.html`: validate the big script block parses
  (`new Function`) and that `<div>` open/close counts balance outside
  script/style. **Ship only if both pass.**
- Role-gate every new control with `data-perm="office"` or `data-perm="owner"`.
  A write path added without one will silently no-op for a role that cannot use
  it — see `docs/OPEN-ITEMS.md` item 3.
- Tiles on lot detail use `buildTileRows()` row-style (label left, value right).
- Modals: `showModal()` / `hideModal()`; alerts via `showAlert(id, msg, type)`.
- Print/share pattern: `window.open` + `document.write` for print; jsPDF +
  `navigator.share({files})` for textable PDFs, download fallback on desktop.
- `field-app/index.html` carries an inline boot-diagnostics block that runs
  first, catches `error`/`unhandledrejection`, and wires a `hardReset()` that
  does **not** depend on `app.js`. That independence is the point — keep it.

## Working style (owner preference)

- Terse, decisive. Offer A/B/C options with a recommendation ("my vote"); he
  often replies "all your votes."
- Ask before building anything significant; push back on scope creep.
- Investigate before correcting: for data issues, query first, show findings,
  propose the fix, wait for approval. Never delete data on your own initiative.
- Production DB is the live books of a real ranch. Schema changes and data
  corrections require explicit approval before execution.
