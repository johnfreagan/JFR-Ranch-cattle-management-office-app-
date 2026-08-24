# User Administration Guide

**Who this is for:** the owner (John). Adding, activating, changing, and
removing people who can sign in to the JFR Ranch apps.

**Last verified against the live database:** 2026-08-24.

---

## The two-minute version

Three protocols. Everything below them is the detail behind these.

### Protocol A — add a user

**Supabase dashboard**, once per person:

1. Authentication → Users → **Add user** → **Create new user**
2. Their **email**, and a **password you invent** — write it down
3. **Tick "Auto Confirm User."** Skip it and they cannot sign in at all
4. **Create user**

**Office app**, right after:

5. Settings → **Users** → **Refresh**
6. They appear as: name = their email, role = `crew`, status = **not active**
7. **Type their real name** over the email, then click away
8. **Set the role** in the dropdown
9. Click **Activate**
10. Text them the app URL, their email, and the password

### Protocol B — edit a user

All in the app, Settings → Users:

| To do this | Do this |
|---|---|
| Fix a name | Type over it, click away |
| Change role | Dropdown → confirm |
| Remove access | **Deactivate** — instant, everywhere, history kept |
| Restore access | **Activate** |

Your own row and the last active owner's row are locked. That is the lockout
guard, not a fault.

### Protocol C — someone cannot get in and has no history

Use when an account was created but never used, and nobody knows the password.
**Only safe when the person has no history in the books** — otherwise deactivate
and start a fresh account instead, because deleting a user with history fails on
a foreign key.

1. Authentication → Users → find them → **Delete user**
2. **Add user → Create new user** — same email, a password you choose,
   **Auto Confirm ✅**
3. App → Settings → Users → Refresh → name → role → **Activate**
4. Text them the URL, email, and password

There is no emailed reset available today — see `docs/OPEN-ITEMS.md` item 1.

---

## 1. The three roles

The database allows exactly three role values. A `CHECK` constraint on
`user_profiles.role` rejects anything else.

| Role | Who | In one line |
|---|---|---|
| `owner` | John | Everything, including deletes and the money screens. |
| `office` | Bookkeeper / office help | Runs the books day to day. No hard deletes on core records. |
| `crew` | Cowboys | **Read-only.** Can look at the books but change nothing, and cannot see invoices at all. |

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

Two steps: create the login in the Supabase dashboard, then finish them off in
**Settings → Users** in the app. Only the first step needs the dashboard.

### The Users screen

Settings → Users, visible to `owner` only. The sub-tab is hidden from everyone
else by the role gate, and `admin_list_users()` returns zero rows to anyone who
is not an active owner — so it fails closed even if someone reaches the tab.

It lists everyone with name, email, role, status, and last sign-in. You can:

- **Rename** — type over the name and tab away. New accounts arrive with their
  email address as a placeholder name, so this is usually the first fix.
- **Change role** — the dropdown, with a confirm.
- **Activate / deactivate** — the button on the right.

Two rows are deliberately locked: **your own** (so you cannot demote or
deactivate yourself by accident) and **the last active owner**. The database
refuses both anyway via `guard_last_owner()`; the screen just does not offer
them.

Requires `docs/sql/2026-08-24_users_admin.sql`. If the screen says no users were
returned, that migration has not been run.

### Creating the login itself

Still the dashboard — the browser cannot create an `auth.users` row, and the
key that could must never ship in a client-side app.

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

**In the app:** Settings → Users. Type over the placeholder name, set the role,
click Activate. Done.

**Or by SQL**, if you prefer or the screen is unavailable — edit the three
values at the top and run:

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

Read this as: **the database is the enforcement.** The app hides controls a
role cannot use (see §8 gap 2), but that is presentation only. Anyone who gets
past the UI still hits RLS, and RLS is what actually refuses them.

### The short version

- **`crew` can read but not write.** Anywhere. The only thing they cannot even
  read is invoices.
- **`office` can do everything except hard deletes** on the records where
  deletion is owner-only.
- **`owner` can do everything.**

Because every write policy is either `{owner, office}` or `{owner}`, write
access is a clean ladder: owner > office > crew. The app's role gate relies on
that; if you ever add a policy that breaks the ladder, the UI gate stops
matching the database.

### Reads

All three roles read everything **except** `invoices` and
`invoice_attachments`, which are owner and office only. That is the one hard
wall in the schema, and the only place a role is denied `SELECT`.

### Writes

| Table | Insert | Update | Delete |
|---|---|---|---|
| `lots` | owner, office | owner, office | **owner** |
| `lot_tags` | owner, office | owner, office | owner, office |
| `lot_events` | owner, office | owner, office | **owner** |
| `lot_pasture_assignments` | owner, office | owner, office | **owner** |
| `lot_movements` | owner, office | owner, office | **owner** |
| `weights` | owner, office | owner, office | **owner** |
| `delivery_receipts` | owner, office | owner, office | owner, office |
| `delivery_receipt_attachments` | owner, office | owner, office | owner, office |
| `load_out_destinations` | owner, office | owner, office | owner, office |
| `sales` | owner, office | owner, office | owner, office |
| `sale_sources` | owner, office | owner, office | owner, office |
| `doctoring_events` | owner, office | owner, office | owner, office |
| `doctoring_event_meds` | owner, office | owner, office | owner, office |
| `invoices` | owner, office | owner, office | **owner** |
| `invoice_attachments` | owner, office | owner, office | **owner** |
| `medications` | owner, office | owner, office | **owner** |
| `protocols` | owner, office | owner, office | **owner** |
| Reference data * | owner, office | owner, office | owner, office |

\* `ranches`, `pastures`, `forage_types`, `field_actions`, `field_protocols`,
`protocol_steps`, `protocol_meds`, `lot_adg_phases`.

### `user_profiles` itself

| Action | Who |
|---|---|
| Read | your own row, or `owner` reads all |
| Insert | nobody via the API — only the signup trigger |
| Update | `owner` only |
| Delete | no policy; removed only by the cascade from `auth.users` |

---

## 5. Changing a role

Settings → Users, change the dropdown. Or by SQL:

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

Settings → Users, click Deactivate. Or by SQL:

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

- **Crew:** they should see lots and tags but **no add, edit, or delete
  buttons anywhere**, and no Invoices card on a lot. Reading works; nothing
  else does.
- **Office:** can they record a sale and edit a lot? Then confirm the
  owner-only controls are absent — "Delete all test lots" in Settings, and
  Delete invoice on an open invoice.
- **Owner:** everything visible, including the two above.
- **Inactive:** bounced at the login screen with "Your account is not active
  yet", never reaching the app shell.

---

## 8. Known gaps

All six gaps found in the 2026-08-24 audit are closed or scheduled. Two of
them need an action from you — see §9.

1. ~~**The login screen does not check `is_active`.**~~ **Fixed 2026-08-24.**
   `onLoggedIn()` refuses an inactive profile before revealing the app shell:
   it signs the session back out, returns to the login screen, and shows
   *"Your account is not active yet. Ask John to activate it."* This covers
   both a fresh sign-in and a restored session, so somebody you deactivate is
   kicked out the next time they open the app.

2. ~~**The UI is not role-aware.**~~ **Fixed 2026-08-24.** Every control that
   writes now carries a `data-perm` attribute naming the minimum role, and
   `<body>` carries `data-role` for the signed-in user. A short CSS block
   hides what the role cannot use. Crew see no add/edit/delete buttons and no
   Invoices card; office see everything but the owner-only deletes.

   The gate is presentation only — it is not a second layer of security, and
   it is not meant to be. If it and the policies ever disagree, **the
   policies win and the gate is the thing that is wrong.** Any new write
   control needs a `data-perm`, and any new policy that breaks the
   owner > office > crew ladder breaks the gate's assumption.

   Refused writes that do slip through now read *"Not allowed: crew cannot
   make that change. Ask John if you need it."* instead of a raw Postgres
   row-level-security error.

3. ~~**`doctoring_event_meds` has no ownership check.**~~ **Closed by gap 4.**
   Crew could update or delete a medication line on anybody's treatment
   event. Crew now cannot write to that table at all, which is strictly
   stronger than the per-row ownership check originally proposed.

4. ~~**Crew write directly to the books.**~~ **Fixed** by
   `docs/sql/2026-08-24_crew_read_only.sql` — **run it (see §9).** Crew lose
   INSERT on `doctoring_events`, `doctoring_event_meds`, `weights`,
   `delivery_receipts`, `delivery_receipt_attachments`,
   `load_out_destinations`, `lot_tags`, `lot_pasture_assignments` and
   `lot_movements`, plus the own-row UPDATE/DELETE they had on
   `doctoring_events`. Reads are untouched.

   **When `pending_field_entries` lands, grant crew INSERT on that table and
   nothing else.** Do not restore any grant this migration revoked — the
   staging table is meant to be the field app's only write surface.

5. **Leaked-password protection is off.** Your action — see §9.

6. **Public signup may be open.** Your action — see §9.

See **`docs/OPEN-ITEMS.md`** for everything still open, including the two
dashboard settings and the missing email provider.

### Still true, and deliberately not fixed

**A refused UPDATE or DELETE is silent, not an error.** PostgREST returns an
empty result rather than a failure when RLS filters every row, so a save can
report success while changing nothing. The role gate hides the controls where
this could bite, which is why it is not urgent — but if you ever add a write
path without a `data-perm`, this is the failure mode you will see. Making
every save assert on the returned row count is the real fix, and it is a
bigger change than this pass.

---

## 9. What only you can do

The migrations, and two dashboard settings nothing else can reach.

### ~~Run the crew read-only migration~~ — done

`docs/sql/2026-08-24_crew_read_only.sql` was run on 2026-08-24 and verified
statement by statement: all 27 non-SELECT policies across the nine affected
tables now read `owner, office`, and no policy anywhere in `public` grants crew
a write. Kept here because it is idempotent and safe to re-run if you ever need
to confirm the state.

### Run the Users screen migration

`docs/sql/2026-08-24_users_admin.sql` adds `admin_list_users()` (the owner-only
roster, needed because `authenticated` has no `SELECT` on `auth.users`) and
`guard_last_owner()` (a trigger that refuses to let the final active owner be
demoted or deactivated). Same drill: SQL Editor, paste, Run. It verifies its own
grants and raises if `anon` can still execute the function.

Until it runs, the Users screen loads but reports that no users were returned.

### Two dashboard settings

**Leaked-password protection.** Authentication → **Policies** (password
settings) → enable it. Supabase then checks new passwords against
HaveIBeenPwned and rejects known-breached ones. Do this before handing out
passwords.

**Public signup.** Authentication → **Sign In / Providers** → check whether
"Allow new users to sign up" is on. If it is, anyone with the app's URL can
create an account. They land as inactive `crew` and can do nothing, so this is
not a breach — but it lets strangers put rows in your auth table. Turn it off
and add people by invitation, per §3.

---

## 10. Quick reference

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
