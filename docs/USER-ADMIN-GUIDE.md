# User Administration Guide

**Who this is for:** the owner (John). Adding, activating, changing, and
removing people who can sign in to the JFR Ranch apps.

**Last verified against the live database:** 2026-08-24.

---

## 1. The three roles

The database allows exactly three role values. A `CHECK` constraint on
`user_profiles.role` rejects anything else.

| Role | Who | In one line |
|---|---|---|
| `owner` | John | Everything, including deletes and the money screens. |
| `office` | Bookkeeper / office help | Runs the books day to day. No hard deletes on core records. |
| `crew` | Cowboys | Records what happens in the pasture. **Cannot see invoices.** |

> **Note on naming.** The roadmap in `CLAUDE.md` called these
> admin/manager/cowboy/guest. What actually shipped is **owner / office /
> crew**, and there is no guest role. Use the shipped names — the constraint
> and every RLS policy are written against them.

Roles are **flat**, not hierarchical. There is no inheritance: each policy
lists the roles it allows by name.

---

## 2. How authorization actually works

Three moving parts. Understand these and the rest of this guide is mechanical.

### `user_profiles`

One row per person, keyed to their `auth.users` id.

| Column | Notes |
|---|---|
| `id` | uuid, = `auth.users.id`, `ON DELETE CASCADE` |
| `full_name` | NOT NULL. Falls back to the email address if not set. |
| `role` | NOT NULL, one of `owner` / `office` / `crew` |
| `is_active` | NOT NULL, defaults `true` on the column but the signup trigger writes `false` |
| `created_at` / `updated_at` | timestamps |

### `current_user_role()`

Every policy calls this one function:

```sql
SELECT role FROM public.user_profiles
WHERE id = auth.uid() AND is_active = TRUE;
```

Two consequences worth internalising:

- **`is_active = false` returns NULL**, and `NULL = ANY (...)` is never true.
  So an inactive user is denied by every policy on every table. Deactivating
  is a complete, instant kill switch.
- A signed-out visitor has no `auth.uid()`, so they get NULL too. Some
  policies are declared against the `public` Postgres role rather than
  `authenticated`; that is cosmetically inconsistent but **not** a hole,
  because the NULL check closes it either way.

### The signup trigger

`on_auth_user_created` fires on every insert into `auth.users` and runs
`handle_new_user()`, which creates the profile row with:

- `role = 'crew'` — **hardcoded.** The role is never read from client-supplied
  signup metadata, so nobody can promote themselves by crafting a signup.
- `is_active = false` — **this is the gate.** A brand-new account can sign in
  but can read and write nothing until you activate it.

There is no `INSERT` policy on `user_profiles`. The trigger is the only way a
profile row gets created, and only an `owner` can `UPDATE` one.

---

## 3. Adding a user

There is no user-management screen in the app. This is done in the Supabase
dashboard, in two steps: create the login, then grant the role.

**Project:** `xpfmebdzcxorvwikfvtj` →
<https://supabase.com/dashboard/project/xpfmebdzcxorvwikfvtj>

### Step 1 — create the login

Dashboard → **Authentication → Users → Add user**.

Pick one:

- **Send invitation** — they get an email and set their own password. Preferred
  for office staff.
- **Create new user** — you set the password and hand it over. Preferred for
  cowboys, who may not have easy email access on a horse. Tick **Auto Confirm
  User**, otherwise they cannot sign in until they click a link.

The trigger now creates their profile: `crew`, inactive, `full_name` set to
their email address (the dashboard form has no name field). They cannot do
anything yet. That is correct.

### Step 2 — set the name, role, and activate

Dashboard → **SQL Editor**. Edit the three values at the top and run:

```sql
-- Grant a role to an existing auth user. Idempotent: safe to re-run.
DO $do$
DECLARE
    v_email TEXT := 'person@example.com';   -- EDIT
    v_name  TEXT := 'First Last';           -- EDIT
    v_role  TEXT := 'crew';                 -- EDIT: owner | office | crew
    v_id    UUID;
BEGIN
    SELECT id INTO v_id FROM auth.users WHERE lower(email) = lower(v_email);
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No auth user with email %. Create the login first.', v_email;
    END IF;

    IF v_role NOT IN ('owner', 'office', 'crew') THEN
        RAISE EXCEPTION 'Invalid role: %', v_role;
    END IF;

    -- The signup trigger should have made this row; be defensive anyway.
    INSERT INTO public.user_profiles (id, full_name, role, is_active)
    VALUES (v_id, v_name, v_role, TRUE)
    ON CONFLICT (id) DO UPDATE
        SET full_name = EXCLUDED.full_name,
            role      = EXCLUDED.role,
            is_active = TRUE,
            updated_at = now();

    RAISE NOTICE 'Active: % as % (%)', v_name, v_role, v_id;
END
$do$;
```

### Step 3 — verify before you hand over the password

```sql
SELECT p.full_name, p.role, p.is_active, u.email,
       u.email_confirmed_at IS NOT NULL AS confirmed,
       u.last_sign_in_at
FROM public.user_profiles p
JOIN auth.users u ON u.id = p.id
ORDER BY p.role, p.full_name;
```

You want `is_active = true` and `confirmed = true`. If `confirmed` is false
they will get "Email not confirmed" at the sign-in screen — go back to
Authentication → Users, open the user, and confirm them.

---

## 4. What each role can do

Read this as: **the database is the only enforcement.** The office app shows
every button to everybody — it reads the role only to print the badge in the
header, and never hides a control. A `crew` user who taps Delete on a lot sees
a Postgres permission error, not a missing button. That is safe, but it is ugly,
and it is worth knowing before somebody reports it as a bug.

`✓` = allowed, `—` = denied.

### The books

| Table | Read | Insert | Update | Delete |
|---|---|---|---|---|
| `lots` | all 3 | owner, office | owner, office | owner |
| `lot_tags` | all 3 | **all 3** | owner, office | owner, office |
| `lot_events` | all 3 | owner, office | owner, office | owner |
| `lot_pasture_assignments` | all 3 | **all 3** | owner, office | owner |
| `lot_movements` | all 3 | **all 3** | owner, office | owner |
| `weights` | all 3 | **all 3** | owner, office | owner |
| `delivery_receipts` | all 3 | **all 3** | owner, office | owner, office |
| `delivery_receipt_attachments` | all 3 | **all 3** | owner, office | owner, office |
| `load_out_destinations` | all 3 | **all 3** | owner, office | owner, office |
| `sales` | all 3 | owner, office | owner, office | owner, office |
| `doctoring_events` | all 3 | **all 3** | owner, office, **or crew on their own rows** | same |
| `doctoring_event_meds` | all 3 | all 3 | all 3 | all 3 |

Crew self-service on `doctoring_events` is scoped by
`recorded_by_user_id = auth.uid()` — a cowboy can fix or remove a treatment he
recorded, and nobody else's.

### Money — the one hard wall

| Table | Read | Insert | Update | Delete |
|---|---|---|---|---|
| `invoices` | owner, office | owner, office | owner, office | owner |
| `invoice_attachments` | owner, office | owner, office | owner, office | owner |

**Crew cannot read invoices at all.** This is the only place a role is denied
`SELECT`. Everything else in the books is readable by everyone who can sign in.

### Reference data

Read by all three roles; written by owner and office only:
`ranches`, `pastures`, `forage_types`, `field_actions`, `field_protocols`,
`protocol_steps`, `protocol_meds`, `lot_adg_phases`, `sale_sources`.

`medications` and `protocols` are the same, except **delete is owner-only**.

### `user_profiles` itself

| Action | Who |
|---|---|
| Read | your own row, or `owner` reads all |
| Insert | nobody via the API — only the signup trigger |
| Update | `owner` only |
| Delete | no policy; removed only by the cascade from `auth.users` |

---

## 5. Changing a role

```sql
-- Idempotent. Fails loudly if the person does not exist.
DO $do$
DECLARE
    v_email TEXT := 'person@example.com';   -- EDIT
    v_role  TEXT := 'office';               -- EDIT
    v_id    UUID;
BEGIN
    SELECT p.id INTO v_id
    FROM public.user_profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE lower(u.email) = lower(v_email);

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No profile for %', v_email;
    END IF;

    UPDATE public.user_profiles
    SET role = v_role, updated_at = now()
    WHERE id = v_id;

    RAISE NOTICE 'Role for % is now %', v_email, v_role;
END
$do$;
```

The change takes effect on their **next request** — `current_user_role()` is
read fresh on every policy evaluation, so there is no need to make them sign
out and back in. Their header badge will be stale until they reload, but their
actual permissions are already current.

Keep at least one active `owner` at all times. Nothing in the database stops
you from demoting yourself and locking everyone out of user administration; if
that happens, the SQL Editor still works (it bypasses RLS) and can put it back.

---

## 6. Removing someone

### Deactivate — the right answer

```sql
UPDATE public.user_profiles
SET is_active = FALSE, updated_at = now()
WHERE id = (SELECT id FROM auth.users WHERE lower(email) = lower('person@example.com'));
```

Immediate and total on two levels: `current_user_role()` goes NULL so every
policy denies them, and the login screen refuses them with "Your account is not
active yet" rather than letting them into an empty app. A person already signed
in is kicked out the next time the app loads. Their history stays intact and
attributed.

Reactivating is the same statement with `TRUE`.

### Do not delete auth users

Deleting from `auth.users` cascades into `user_profiles`, and **most of the
books point at `auth.users` with `ON DELETE NO ACTION`**. Any person who has
ever created a lot, sale, receipt, invoice, weight, movement, pasture
assignment, ranch, pasture, medication, or protocol **cannot be deleted** — the
delete fails on a foreign key violation.

A few columns are `ON DELETE SET NULL` (`doctoring_events.recorded_by_user_id`,
`lot_tags.registered_by`, the attachment `uploaded_by` columns). Those would
silently lose their attribution — you would erase who doctored what.

Both outcomes are bad. **Deactivate, never delete.**

---

## 7. Verifying a role actually works

Do not trust the matrix — test it. Sign in as the user in a private browser
window and confirm both halves:

- **Crew:** can they open a lot and record a doctoring event? Then confirm the
  invoice screens come back empty or error. Both must be true.
- **Office:** can they record a sale and edit a lot? Then confirm a hard delete
  of a lot is refused (that is owner-only).
- **Inactive:** an inactive account should be bounced at the login screen with
  "Your account is not active yet", never reaching the app shell.

---

## 8. Known gaps

Documented deliberately — none of these are bugs you have hit yet, but each
will produce a confusing support call one day.

1. ~~**The login screen does not check `is_active`.**~~ **Fixed
   2026-08-24.** `onLoggedIn()` now refuses an inactive profile before
   revealing the app shell: it signs the session back out, returns to the
   login screen, and shows *"Your account is not active yet. Ask John to
   activate it."* This covers both a fresh sign-in and a restored session,
   so somebody you deactivate is kicked out the next time they open the app.

2. **The UI is not role-aware.** `currentProfile` is assigned and then used
   only for the header badge. Every button is visible to every role; the
   database refuses the write. Correct, but it looks broken to the user.

3. **`doctoring_event_meds` has no ownership check.** Crew can update or
   delete any medication line, including on another person's treatment
   event — even though the parent `doctoring_events` row is protected by
   `recorded_by_user_id = auth.uid()`. Worth tightening when the review
   screen is built.

4. **Crew currently write directly to the books.** The Part B design in
   `HANDOFF.md` calls for cowboys to write only to `pending_field_entries`
   for office review. That table does not exist yet, so today's crew
   permissions on `doctoring_events`, `weights`, and receipts are broader
   than the intended end state. Tighten these *at the same time* as the
   staging table lands, not before — nothing else would be able to write.

5. **Leaked-password protection is off.** Supabase can reject passwords found
   in HaveIBeenPwned breaches. Dashboard → Authentication → Policies. Worth
   turning on before adding people.

6. **Check whether public signup is open.** Dashboard → Authentication →
   Sign In / Providers. If anyone can sign up with an email, they get an
   inactive `crew` profile and can do nothing — so this is not a breach — but
   it lets strangers create rows in your auth table. Recommend disabling it
   and adding people by invitation only.

---

## 9. Quick reference

```sql
-- Everyone, with sign-in status
SELECT p.full_name, p.role, p.is_active, u.email, u.last_sign_in_at
FROM public.user_profiles p JOIN auth.users u ON u.id = p.id
ORDER BY p.role, p.full_name;

-- Logins that never got a role granted (created but never activated)
SELECT u.email, u.created_at
FROM auth.users u JOIN public.user_profiles p ON p.id = u.id
WHERE p.is_active = FALSE;

-- What a given role can do to a given table
SELECT policyname, cmd, qual, with_check
FROM pg_policies WHERE schemaname = 'public' AND tablename = 'lots';
```
