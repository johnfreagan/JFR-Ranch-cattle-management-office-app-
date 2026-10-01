# SQL test harness

The live database is the books of a real ranch, so a migration that touches
money or head math is run against a throwaway PostgreSQL 16 first. Each test
set is two files:

- `*_fixture.sql` — the smallest stub of the live schema the migration
  touches. Column names and types are copied from the live
  `information_schema`, and the Supabase pieces (`auth.uid()`,
  `current_user_role()`, `can_read_books()`, `ranch_today()`, the `anon` and
  `authenticated` roles) are stubbed so RLS can actually be exercised. The
  role gate reads a session GUC instead of `auth.uid()`, which is the only
  way one session can test four roles.
- `*_tests.sql` — assertions. Every block raises on failure and prints `PASS`
  on success, so the run is checked by counting `PASS` lines and grepping for
  `ERROR`.

Run:

```sh
pg_ctlcluster 16 main start
su postgres -c "dropdb --if-exists medtest && createdb medtest"
su postgres -c "psql -q -v ON_ERROR_STOP=1 -d medtest -f docs/sql/tests/2026-10-01_med_inventory_fixture.sql"
su postgres -c "psql -q -v ON_ERROR_STOP=1 -d medtest -f docs/sql/2026-10-01_med_inventory.sql"
su postgres -c "psql -q -d medtest -f docs/sql/tests/2026-10-01_med_inventory_tests.sql"
```

The migration file is run **as it ships**, `begin;`/`commit;` and all — the
point is to prove the file that will be pasted into the SQL editor, not a
cleaned-up version of it. Re-running the migration against the same database
proves it is idempotent.

`ON_ERROR_STOP=0` on the test file is deliberate: one failed assertion must
not hide the twenty-eight after it. Tests share state on purpose where the
scenario needs it (a count posted in one test is the lock another test runs
into), so they are **not** safe to run twice against the same database —
drop and recreate it.
