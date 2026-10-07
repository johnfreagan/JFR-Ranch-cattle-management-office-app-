# Test lots out of the live books

Decided 2026-10-07 by John: D44 (`docs/pasture-headdays-phase-design.md`) is
reversed. Test lots leave production. Testing moves to a separate Supabase
project built from a copy of the real books. Each step below waits for John's
go before it runs.

## What is in production today (checked 2026-10-07, read-only)

| lot | state |
|---|---|
| TEST_DOC1 | open, 100 head in Front beside 37 real head |
| TEST_DOC2 | open, 50 head in Goat Hill beside 230 head of 36-27 |
| Test-1 | closed 2026-05-13 |

Rows that point at them:

| table | rows |
|---|---|
| lot_tags | 1,000 |
| doctoring_events | 16 (all entered 2026-04-29, before the med ledger went live 10/01, so no FIFO draws) |
| doctoring_event_meds | 22 |
| lot_pasture_assignments | 8 |
| pasture_head_log | 4 (no foreign key to lots) |
| delivery_receipts | 3 |
| invoices | 3 |
| lot_events | 2 |
| _proc_cost_snapshot_20261002 | 1 (frozen snapshot table) |

Every other table with a lot column has zero test rows: sales, weights, feed,
transfers, shipments, positions, budgets, feed pen, health overrides, pending
field entries. `med_stock_locations` has no `is_test` location.

The "Delete all test lots" button in Settings is not safe to use: about twelve
separate deletes from the browser with no transaction, errors ignored on most
steps, and it misses `pasture_head_log`. It is retired in step 5.

## Steps

1. **Test project.** John uses Supabase "Restore to a new project" on the live
   project's latest daily backup (Dashboard > Database > Backups > Restore to
   a New Project). That copies schema, data, roles and auth users. It does not
   copy edge functions, storage, API keys or auth settings. The new project
   costs extra each month at the same compute size as production; the
   dashboard shows the price before it starts.
2. **Make the copy safe.** First thing on the test project, before anything
   else:
   - `cron.unschedule('market-quotes-sync-daily')`. The copied job posts to
     the LIVE project's edge function URL, so leaving it would double-run
     the market sync against production.
   - Check `cron.job` is empty and nothing else in `pg_net` points at the
     live URL.
   - Rename the project "JFR Cattle TEST".
   - Decide about the 8 copied auth users (keep, or reset passwords).
3. **Point the apps at it.** A test switch in the office app and field app
   that swaps the Supabase URL and anon key, with a red "TEST DATABASE"
   banner on every screen. Production stays the default.
4. **Archive, then purge production.** Export every test row (the tables
   above) to `docs/archive/` as JSON. Snapshot the real numbers (D8 tie-out,
   head per pasture, invoice totals, cost of gain per lot). Then one
   migration, one transaction, deletes in child-to-parent order and raises
   (rolling everything back) if any count or real-lot number moves.
5. **Lock it.** A trigger on `lots` refuses `is_test = true` and lot numbers
   starting `TEST`. The Settings button is removed. The existing `is_test`
   filters stay (harmless) and come out over time.

## Log

- 2026-10-07: D44 reversed. Footprint counted. Plan written.
