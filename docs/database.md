# Database: access control (RLS), rls_verify, migrations

_Moved word for word from `CLAUDE.md` on 2026-09-27, when CLAUDE.md became a short index. Nothing here was rewritten; section dates are the dates the rules were written._

Older migration files cite "CLAUDE.md rule N" (rules 1-7). Those are the numbered rules under **Rules** below. Schema landmines are in `docs/gotchas.md`; the security contract in `docs/security-model.md`.

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
   **`CREATE OR REPLACE VIEW` CLEARS the reloptions when `WITH` is omitted** —
   it does not carry the existing ones forward. So replacing a live view
   without repeating the clause silently strips `security_invoker` off a view
   that had it, which is worse than never setting it: nothing changed in the
   view's definition, nothing errors, and the RLS bypass is invisible. Caught
   2026-09-07 by the feed pen migration's own verify block on `lot_daily_head`,
   before it applied. Repeat the clause on every replace, and assert it
   afterwards.
4. **Never GRANT anything to `anon`.** `authenticated` + RLS is the only path.
   Revoke from `PUBLIC`, not just `anon` — Postgres grants function EXECUTE to
   PUBLIC by default, so `revoke ... from anon` alone silently does nothing.
5. **New tables need RLS *and* policies.** `ENABLE ROW LEVEL SECURITY` with no
   policy is a total lockout; policies without `ENABLE` are decoration.
6. **`SECURITY DEFINER` needs a reason and a pinned `search_path`.** Each one
   bypasses RLS. Deliberate today (all eight verified 2026-09-10 to carry a
   pinned `search_path`): `current_user_role` (it is the gate),
   `admin_list_users`, `guard_last_owner`, `handle_new_user`,
   `cleanup_attachment_storage`, `lot_projected_weight`,
   `lot_projected_weight_detail`, `lot_weighted_arrival_date`, and since
   2026-09-25 the four health-curve readers `health_lot_basis_rows`,
   `health_head_rows`, `health_pull_rows`, `health_death_rows` (they check
   the role gate ONCE per call instead of once per row — under a real login
   the per-row policies pushed the lot card past PostgREST's 8 s timeout —
   and return no dollar column; see docs/health-curves.md). Since
   2026-10-09 three medicine reversals: `med_void_doctoring`,
   `med_processing_reverse` and `delete_med_charge`. Each checks
   owner-or-office itself, and each does the PAIRED operation (units back on
   the FIFO layers and the `med_txns` row deleted, asserted gone) in one
   transaction. That pairing is the reason: the `med_txns` delete policy
   stays owner only, so an office login can remove a ledger row only in a
   form that cannot leave the shelf and the books disagreeing
   (`docs/sql/2026-10-09c_med_office_reversal.sql`). The eighth
   was added 2026-09-10 and inherits its reason from the function it backs:
   `lot_projected_weight` has been DEFINER since it was written, which is
   the only reason crew — who cannot read `invoices` — see a projected
   weight at all. An INVOKER detail function would have handed crew the
   number with a blank provenance beside it. Default to INVOKER — the
   head-math RPCs
   (`record_death_with_pasture`, `record_move_with_pasture`, the delete
   reversals) are all INVOKER and must stay that way.
7. **Run `supabase/migrations/20260821000300_rls_verify.sql` after any
   migration that adds a table, view, or function.** It asserts 1–6.

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
