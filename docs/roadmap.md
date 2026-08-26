# Roadmap

**Last reviewed:** 2026-08-26.

Agreed order, oldest first. This file is *where we are going*. Known gaps and
things deliberately not done yet live in `docs/OPEN-ITEMS.md`; the two are
cross-referenced rather than duplicated, so check both before planning work.

---

## 1. ✅ Claude Code + `CLAUDE.md` + Supabase MCP connector

Done. Note the MCP connector is **read-only** — DDL and DML fail with
`25006: cannot execute ... in a read-only transaction`. Schema changes are
delivered as pasteable SQL in chat, not as a file or a path.

## 2. ✅ Multi-user auth + RLS

Live since Aug 2026. **Implemented as `owner` / `office` / `crew`**, not the
originally planned admin/manager/cowboy/guest — the `user_profiles.role` CHECK
constraint permits exactly those three.

Delivered: role gate (`current_user_role()`, filtering on `is_active`),
Settings → Users for owner-managed roles and activation, `guard_last_owner()`
so the last active owner cannot be removed, a login screen that refuses
inactive accounts by name, and 77 role-gated controls.

**Open decision:** whether a read-only `guest` role is still wanted. It does not
exist today, and adding it means a fourth CHECK value plus a SELECT-only pass
over every policy.

Lauren Yezak signed in 2026-08-25 and works the books as `owner`. In practice
both current users are `owner`; the `crew` path is built and policied but no
crew user works the field app today.

Related open items: `OPEN-ITEMS.md` 1 (custom SMTP — no email leaves the project,
so John is the password-reset mechanism), 2 (two dashboard settings:
leaked-password protection, public signup), 3 (a refused write is silent),
8 (no standing RLS verify script).

## 3. ✅ Field PWA for cowboys

Live 2026-08-25, build v12, at `field-app/` in this repo. The field app writes
to `pending_field_entries`; the office **Approvals** tab reviews and posts into
the books. Google Apps Script and the Google Sheet are out of the loop entirely;
the Sheet was abandoned in place (test data only, John's call — no backfill).

Verified in production: eleven real doctoring entries with frozen cost and zero
drift. **Still unexercised: a real Dead and a real Move.** Both paths are built,
RPC-backed and rollback-tested; John will run one of each as they occur and flag
it for verification. Check `event_datetime`, the `approved_ref`, and drift on the
affected lot after.

Remaining tail: retire the old repo — disable Pages and archive
`johnfreagan/JFR-Ranch-Cattle-Field-App` **on or after 2026-09-14**
(`OPEN-ITEMS.md` item 4). The wait exists because an installed copy needs one
online load to run the self-destructing worker.

## 4. ⏳ Cost ledger — **in progress**

18 categories, monthly, allocated per head-day. Redwing exports imported via
Cowork. Cost data is office+owner only.

**Phase 1 shipped 2026-08-25:** the Closeout rebuild — budget / actual /
projection, `lot_budgets` (frozen by trigger), `lot_daily_head` and
`lot_head_days_by_month`, verified against production on all eight lots. It
fixed the death-loss double count, interest charged on purchase price only, cost
of gain never reaching cattle that had already shipped, Closeout being visible to
crew, and the tab rendering before `loadSales`. See `docs/architecture.md` §5.

**Deliberately still out:** cost ledger categories and pasture cost. John enters
a cost-of-gain rate for now.

**Blocked on:** a Redwing export from John before the ledger itself can start.

**Should be folded in:** validation on cost assumptions. `OPEN-ITEMS.md` item 9 —
37X-1 had labor at $35.00/head/day (corrected to $0.35), 47-26 and 60X carry no
assumptions at all, 36-27 sits at $2.00/head/day COG against 0.75–1.00 elsewhere.
Nothing validates these on entry. A sanity band on the input (warn outside, say,
$0.10–$5.00 per head per day) rather than a hard limit.

## 5. Daily buy/sell dashboard

Breakevens against market data. Not started. Depends on item 4 for trustworthy
cost inputs.

---

## Near-term, off the numbered list

**Automatic daily send of the daily report** (`OPEN-ITEMS.md` item 7). The report
is built; delivery is not. Agreed order is email first, then SMS. Agreed
settings: 6:30pm CT pinned to `America/Chicago` so DST does not move it,
recipients in an owner-managed table with a Settings screen, short recap in the
text and the full PDF in the email.

The decision that gates the build: a scheduled Edge Function has to compose the
report with no browser, so either the report logic is written a second time in
TypeScript, or a SQL function becomes the single source of truth and both the app
and the function read it. The rules that would drift if duplicated are the
test-lot filter, the death dedupe between `doctoring_events` and `lot_events`,
the carcass-not-hauled detection, and recovering the cowboy's name through
`approved_ref`. The second option means refactoring a screen that was just
shipped and verified.

Blocked on John either way: a Resend account with a verified sending domain (the
same account closes the SMTP item, so it is worth doing once for both), and
enabling `pg_cron` and `pg_net` in the dashboard. SMS is a separate hurdle — US
A2P 10DLC registration is mandatory for automated texts on a normal number.
Carrier email-to-SMS gateways were considered and **rejected**: free, but they
drop messages silently, and a blocked report and a quiet day look identical.

**A standing RLS verify script** (`OPEN-ITEMS.md` item 8). `CLAUDE.md` rule 7
cited one; it does not exist, and neither does the `supabase/` directory. Write
it once as a standalone script asserting rules 1–6 across every object in
`public`. Until then every migration must carry its own inline assertions.

The `tag_history` finding on 2026-08-26 is the argument for doing this sooner:
a view had been reaching into `auth.users` for an email since before the August
hardening, and the manual sweep three days earlier did not catch it because
nobody thought to ask that question. Supabase's own linter did. The spec in
`docs/security-model.md` §4 now carries that assertion — a script would run it
every time instead of when somebody remembers.

---

## Background / housekeeping

- **Adopt the Supabase CLI for migrations.** The remote has no CLI migration
  history — the schema was built through the dashboard and SQL editor, so
  `supabase db push` would try to apply everything from scratch. Path:
  `supabase link --project-ref xpfmebdzcxorvwikfvtj` → `supabase db pull` for a
  baseline → mark it applied → verify with `supabase migration list`. Until
  then, SQL editor, with the applied file kept in `docs/sql/`.
- **Take `guard_last_owner()` off the API surface** (`OPEN-ITEMS.md` item 10).
  `anon` can call it over RPC. It is a trigger function so the call raises and
  there is no data path, but it should not be callable. Verify against the live
  trigger before revoking — this is the guard that stops John locking himself
  out of user administration.
- **Review the two unreviewed `SECURITY DEFINER` functions**,
  `lot_projected_weight` and `lot_weighted_arrival_date`. They predate the
  hardening work. Both carry a pinned `search_path`, so this is a correctness
  review, not an exposure.
- **Consolidate the duplicated guides** (`OPEN-ITEMS.md` item 5).
  `docs/USER-ADMIN-GUIDE.md` and `docs/manuals/admin-manual.html` carry the same
  content in two formats, as do the two field guides. Either generate the HTML
  from the markdown or drop the markdown.
- **Make every save check its returned row count** (`OPEN-ITEMS.md` item 3). A
  broad pass through `index.html`, not yet attempted.

---

## Parked

Agreed as worth doing eventually, with nothing scheduled:

- Breakeven budget-vs-actual
- Bottle inventory
- Lot comparison report
- Weather integration

---

## Ruled out

- **Google Sheet backfill** — everything in the Sheet is test data (John's
  call). Supabase started clean at cutover; the Sheet is abandoned in place.
- **`git subtree` for the field-app merge** — history not preserved, plain file
  copy in one commit instead. Grafting an unrelated history into a production
  repo's `main` was not worth it. John was told and accepted.
- **Leaving both field-app URLs live**, and **redirecting but keeping the old
  repo around** — the old repo is being retired outright.
- **Carrier email-to-SMS gateways** for report delivery — see above.
- **Rejecting duplicate field submissions.** `(entry_type, client_id)` is an
  upsert key by design; rejecting the second send would strand an edit on the
  phone.
