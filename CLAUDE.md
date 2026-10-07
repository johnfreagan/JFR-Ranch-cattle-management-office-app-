# JFR Ranch Cattle Management App

Single-file web app (index.html at repo root) for JFR Ranch Co. Ltd., a stocker
cattle operation in Kosse, TX. Deployed via GitHub Pages. Backend is Supabase
(PostgreSQL + auth + PostgREST). Owner: John Reagan.

**Multi-user as of Aug 2026** — three roles (owner/office/crew) enforced by RLS.
See "Access control" below and `docs/security-model.md`.

This file is the index. The detail moved word for word into `docs/` on
2026-09-27; the table at the bottom says which file to read for which job.
"Access control" is in `docs/database.md`. Older files that cite "CLAUDE.md
rule N" mean the numbered RLS rules there.

## Must-follow rules

- **Production DB is the live books of a real ranch.** Investigate before
  correcting: query, show findings, propose, wait. Schema changes and data
  corrections need John's explicit approval. Never delete data on your own.
- **Deploy** = commit + push to main; `index.html` is the whole office app.
  After ANY edit run `node scripts/validate.js index.html` (JXA copy on the
  Mac): the script must parse and `<div>`s balance. No duplicate top-level
  function names. Field app: bump `CACHE_VERSION` and the `?v=` strings together.
- **Stocker (fiscal) year is Jul 1 – Jun 30, named for the year it ends**
  (FY 2027 = Jul 2026 – Jun 2027). Tax year is the calendar year. Every
  report says which year it uses.
- **Head math never drifts.** head_in − dead − sold − transfer_out +
  transfer_in + adjustment = head_current = sum of open pasture assignments
  (D8 tie-out). Deaths, moves, sales and receipt deletions go through the
  atomic RPCs; never raw-delete them. A reversal that reopens an assignment
  must not also add head back.
- **Days use `ranch_today()` / `ranchToday()`**, never `CURRENT_DATE` or the
  viewer's clock: the database runs UTC.
- **Processing cost is derived live.** Never edit a protocol or a drug price
  in place to change cost from a date; make a new protocol version. A NULL
  cost is a hole and `SUM()` ignores it: price a med before using it.
- **RLS:** never GRANT to `anon`; revoke from `PUBLIC`. Every view
  `security_invoker = true`, repeated on every `CREATE OR REPLACE VIEW`. New
  tables need RLS and policies. SECURITY DEFINER needs a reason and a pinned
  `search_path`. Never read a role from `raw_user_meta_data`. Run
  `supabase/migrations/20260821000300_rls_verify.sql` after any migration.
- **Migrations** are idempotent files in `docs/sql/` with `begin;`/`commit;`.
  Strip those for `apply_migration` or the CLI, and prove the transcription
  afterwards (`md5(prosrc)` against the file).
- **Tags** are plain digits (no leading zero) or `NT<n>` per lot for an
  untagged animal (`no_tag = true`). Match a text tag to `lot_tags` only
  through `tag_to_int()` / `tagToInt()`. Retire a tag on death or sale.
- **Withdrawal warns and lists the tags; it never blocks.** `drug_off` means
  the carcass was dragged out of the field; it is not withdrawal.
- **Crew never sees dollars.** A denied SELECT returns zero rows, not an
  error, so say so on screen.
- Errors are never swallowed. Data corrections append an audit note.

## Response style

Caveman is the default in chat (level **full**, ruleset
`.claude/skills/caveman/SKILL.md`, why and how to turn off in `SOURCE.md`).
Read the skill and apply it without being asked. It does NOT apply to
anything that leaves the chat — commit messages, PR bodies, `docs/`, SQL
comments, `notes` audit text — and its Auto-Clarity carve-out drops
compression for security warnings, irreversible actions and multi-step
migrations. Terse is not a shortcut past investigate-first. "normal mode"
turns it off. Full text in `docs/conventions.md`.

## Where the detail lives

| Read | When you are |
|---|---|
| `docs/conventions.md` | writing any code or SQL; the short rules; working style and response style |
| `docs/deploy.md` | deploying or touching the Supabase URL / key |
| `docs/database.md` | touching auth, roles, RLS, policies, views, grants; running rls_verify; applying a migration |
| `docs/gotchas.md` | writing any query: schema landmines (column names, UTC, head-day traps, PostgREST limits) |
| `docs/costs.md` | touching processing, treatment, protocols, drug prices, fiscal year, closeout, budgets, COG |
| `docs/architecture.md` | working on sales and shipments, doctoring/health reports, D8 tie-out, tag retirement, withdrawal, feed pen, strays, projected weight, markets, pastures and moves, Tally Book, roadmap |
| `docs/field-entries.md` | working on the field app, its queue and Failed list, Approvals, counts, test weights |
| `docs/feed-pb-import.md` | working on feed inventory, cost of gain, orders and invoices, the PB daily import |
| `docs/medicine-inventory-fifo-plan.md` | working on medicine inventory: FIFO layers, counts and shrink, checkouts, the buyer reconciliation, the Redwing usage report, the Bar J emailed-invoice intake (Approvals > Meds), direct charges of medicine to a lot or a cost centre (Meds > Charge out) |
| `docs/security-model.md` | changing the role model itself |
| `docs/processing-cost-and-protocol-versioning.md` | changing a protocol from a date (the full worked reasoning) |
| `docs/cog-design-decisions.md` | changing cost of gain, non-feed rate, assumption history |
| `docs/feed-design-decisions.md`, `docs/commodity-feed-inventory-plan.md`, `docs/inventory-flow-design.md` | changing feed design |
| `docs/feed-pen-design.md`, `docs/stray-cattle-design.md`, `docs/lot-transfers-design.md` | feed pen, strays, transfers |
| `docs/health-curves.md` | health baselines and curves |
| `docs/OPEN-ITEMS.md` | picking up open work |
| `docs/FIELD-APP-GUIDE.md`, `docs/USER-ADMIN-GUIDE.md` | writing for crew or for whoever manages users |
| `docs/sql/` | the migrations, in date order |
