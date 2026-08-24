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
   bypasses RLS. Deliberate today: `current_user_role` (it is the gate),
   `handle_new_user`, `cleanup_attachment_storage`, `lot_projected_weight`,
   `lot_weighted_arrival_date`. Default to INVOKER.
7. **Run `supabase/migrations/20260821000300_rls_verify.sql` after any
   migration that adds a table, view, or function.** It asserts 1–6.

### Offline/PWA consequences (matters for the field app in roadmap #3)

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
- Supabase PostgREST caps results at 1000 rows — PAGINATE lot_tags and any
  large fetch.
- When unsure of a column name, QUERY information_schema — do not guess.
  Schemas evolved inconsistently across tables.
  **Exception: do NOT trust information_schema for GRANTS or PRIVILEGES.**
  `role_table_grants` only shows roles the *querying* user belongs to, so on
  hosted Supabase it returns an empty set for `anon` while `anon` in fact holds
  full grants. Use `has_table_privilege()` / `pg_class.relacl` for privileges.
  Columns and types are fine.

## Data-integrity architecture (do not bypass)

- Deaths, sales, and receipt deletions go through atomic RPCs
  (`record_death_with_pasture`, `delete_death_event`,
  `delete_receipt_with_reversal`, etc.) that keep pasture assignments in
  sync. NEVER raw-delete a receipt/death/sale from the app.
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
   Lauren Yezak is provisioned as `crew` but has never signed in.
3. Field PWA for cowboys: pending_field_entries queue + office review screen,
   offline-first. `crew` is the role this targets — see the offline/PWA notes
   under Access control before building the queue.
4. Cost ledger (18 categories, monthly, per-head-day allocation; Redwing
   exports imported via Cowork). Note: cost data is office+owner only.
5. Daily buy/sell dashboard: breakevens vs market data
Also parked: breakeven budget-vs-actual, bottle inventory, lot comparison
report, weather integration.
