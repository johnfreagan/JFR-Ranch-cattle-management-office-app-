# Security model

How access control works in this database, what was wrong with it before
2026-08-23, and how to verify it still holds.

Operational rules live in `CLAUDE.md` at the repo root. This file is the
reasoning behind them.

---

## 1. The model

**Single tenant, three roles.** One outfit (JFR Ranch), a handful of people,
graduated permissions. There is a `ranches` table but it is unused — multi-tenancy
was scaffolded and never adopted. Nothing keys off `ranch_id`.

### The gate

```sql
create or replace function public.current_user_role()
returns text
language sql stable security definer
set search_path to 'public'
as $$
  select role from public.user_profiles
  where id = auth.uid() and is_active = true;
$$;
```

Three properties matter:

- **`SECURITY DEFINER` is required, not lazy.** Policies on `user_profiles`
  call this function. As `SECURITY INVOKER` it would re-enter `user_profiles`'
  own RLS and Postgres would raise `infinite recursion detected in policy`.
- **`is_active` is in the predicate, not just the row.** Revocation is
  therefore immediate. Set `is_active = false` and the user's *next statement*
  returns nothing — no waiting for a token to expire, because the check is a
  table lookup rather than a claim baked into the JWT.
- **`STABLE`** lets the planner evaluate it once per statement instead of once
  per row. On `doctoring_event_meds` (1,893 rows) that is the difference
  between a fast query and a table scan of function calls.

It returns NULL for anyone unknown or inactive, and every policy is written so
NULL denies.

### Role capabilities

| | crew | office | owner |
|---|---|---|---|
| Read operational data | ✅ | ✅ | ✅ |
| Write field data (doctoring, weights, tags, receipts, movements) | ✅ | ✅ | ✅ |
| Update/correct operational records | ❌ | ✅ | ✅ |
| Invoices, costs, margins | ❌ | ✅ | ✅ |
| Delete lots, weights, medications, protocols, audit rows | ❌ | ❌ | ✅ |
| See the full user roster | ❌ | ❌ | ✅ |

The shape: **crew can record what happened in the field but not rewrite
history, and cannot see money.** Office can correct records and handle
financials. Owner can destroy things.

Deletes are deliberately the narrowest privilege. `lot_movements`,
`lot_events`, and `lot_pasture_assignments` are audit trails — an accidental
delete there is unrecoverable in a way an accidental insert is not.

### Onboarding

`handle_new_user()` fires `AFTER INSERT ON auth.users FOR EACH ROW` and creates
an **inactive crew** profile. Role and active state are hardcoded. An owner
activates the account by hand.

This is why public signups being disabled is a second lock, not the only one:
the trigger fires on invites and `admin.createUser` too, and those paths remain
open by design.

---

## 2. What was wrong (found 2026-08-23)

Found by reading the live database through the Supabase MCP connector, after
two earlier sessions had designed a replacement access model without being able
to see that a better one already existed.

### P0-1 — Privilege escalation via signup metadata

`handle_new_user()` contained:

```sql
COALESCE(NEW.raw_user_meta_data->>'role', 'crew')
```

`raw_user_meta_data` is written directly by the client:

```js
supabase.auth.signUp({ email, password, options: { data: { role: 'owner' } } })
```

The CHECK constraint on `user_profiles.role` permits `'owner'`, and `is_active`
defaulted to `true`. Anyone who could reach the signup endpoint could mint
themselves an owner account and read invoices, sales, and the user roster.

Reproduced against a local replica of the schema: the signup produced
`role=owner, is_active=true`, which then read the invoice table.

Even without the metadata trick, the `'crew'` fallback meant **every signup got
immediate read access to all cattle data** plus insert rights on doctoring and
weights.

*Fixed:* role and `is_active` hardcoded; client metadata ignored except for
`full_name`.

### P0-2 — Ten views bypassed RLS and were readable by `anon`

Every view in `public` was owned by `postgres`, had `security_invoker` unset,
and granted `SELECT` to `anon`.

A view without `security_invoker` executes with its **owner's** privileges. RLS
on the base tables does not apply. And the `anon` key ships inside the PWA
bundle, so these were readable **with no account at all** — no signup, no email
confirmation, no password:

`lot_processing_costs`, `lot_processing_cost_detail`, `lot_med_costs_by_category`,
`lot_realized_adg`, `lot_status`, `pasture_status`, `tag_registry`,
`tag_history` (which also exposed `auth.users` emails), `doctoring_event_analytics`,
`lot_current_pastures`.

The more serious of the two findings: it required no interaction with the auth
flow at all, so disabling signups did nothing for it.

*Fixed:* `security_invoker = true` on all ten, `anon` revoked, `SELECT` granted
to `authenticated` only.

### P1 — Policies that bypassed the role system

`lot_movements`, `invoice_attachments`, and `delivery_receipt_attachments`
carried `USING (true)` policies granted to `authenticated`. They ignored
owner/office/crew entirely: any active signed-in user at any role could read,
write, and delete them. `lot_movements` is the pasture-move audit log.

`storage.objects` policies checked only `bucket_id = 'lot-attachments'`, so any
authenticated user could delete every scale ticket and invoice scan. (The
bucket itself was private, so there was no public URL exposure.)

Five `SECURITY DEFINER` functions were callable by `anon` over
`/rest/v1/rpc/`, including the mutating `cleanup_attachment_storage()`.

*Fixed:* all rewritten to match the role model of the tables they belong to.

### P2

13 functions with mutable `search_path` (an escalation vector when combined
with `SECURITY DEFINER`). Most policies target `PUBLIC` rather than
`authenticated` — harmless now that `anon` holds no grants, and left alone
rather than churning ~70 policies for no behavior change.

### Result

Supabase security advisors: **11 ERROR + ~20 WARN → 0 ERROR + 4 WARN.**

Remaining warnings are reviewed and deliberate: `current_user_role()` must be
DEFINER and callable; `lot_projected_weight()` and `lot_weighted_arrival_date()`
are DEFINER and could probably be INVOKER; leaked-password protection is a
dashboard toggle.

### Was it exploited?

No indication. Only two accounts existed, both expected. Neither sent a `role`
key at signup. All 1,080 doctoring events were attributed to the owner account.
Nothing anomalous in row counts.

---

## 3. Two traps worth remembering

Both of these produced *false confidence* — checks that appeared to pass while
the hole was open. That failure mode is worse than an obvious error.

### `information_schema` grant views lie on hosted Supabase

`information_schema.role_table_grants` only shows grants involving roles the
**querying** user is a member of. Against a hosted Supabase project it returns
an empty set for `anon`, so an assertion built on it reports "anon has no
privileges" while `anon` in fact holds `arwdDxtm` on every table and view.

This is precisely how ten exposed views can sit unnoticed indefinitely.

Use `has_table_privilege('anon', c.oid, 'SELECT')` and `pg_class.relacl`. Both
read the catalog directly.

### `REVOKE ... FROM anon` does not remove a PUBLIC grant

Postgres grants `EXECUTE` on every new function to `PUBLIC` by default.
`revoke all on function f() from anon` succeeds, changes nothing, and leaves
`anon` able to call `f()` through its PUBLIC membership.

Always `revoke ... from public, anon`, then grant back to `authenticated`
explicitly.

---

## 4. Verifying

`supabase/migrations/20260821000300_rls_verify.sql` asserts:

1. Every public table has RLS enabled
2. No table has RLS on with zero policies (total lockout)
3. All four commands covered per table
4. `anon` holds no table **or view** privileges
5. No `SECURITY DEFINER` function is `anon`-callable
6. No view bypasses RLS
7. Every DEFINER function pins `search_path`
8. At least one active user exists
9. Prints the full roster

Run it after every migration that adds a table, view, or function. It changes
nothing and raises an exception on a real finding.

**The SQL editor swallows `RAISE NOTICE` output** — it shows only the final
result grid. Read the notices in the editor's message pane, or run it through
`psql` where they print inline.

The coverage report at the end should show 4 policies for most tables. Tables
showing 2 use one SELECT plus one `FOR ALL` write policy; that is the original
design and is sound.

`FORCE ROW LEVEL SECURITY` is deliberately **not** set. It would only affect
connections as the table owner, and `service_role` carries `BYPASSRLS` anyway.

---

## 5. Changing the model later

- **Adding a role** (e.g. `vet`, read-only on doctoring): add it to the
  `user_profiles.role` CHECK constraint, then extend the role arrays in the
  policies that should include it. No structural change.
- **Restricting cost data further**: costs are currently table-level
  (`invoices`, and the cost views). Column-level restrictions would need
  `GRANT SELECT (col, ...)` or a split view. Prefer a view.
- **Multi-tenancy**: `ranch_id` on every table, backfill, and rewrite every
  policy to join through it. A real day of work. Do it only when a second
  operation actually exists — the `ranches` table sitting empty is evidence
  that speculative scaffolding does not survive.
- **Soft delete**: if `deleted_at` arrives, decide whether policies filter it or
  the app does. Policies are safer; the app is faster. Do not do both halfway.
