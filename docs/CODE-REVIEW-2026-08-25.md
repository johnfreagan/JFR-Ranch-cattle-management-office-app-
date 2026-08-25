# Code review, simplification pass, and build-out plan

**Date:** 2026-08-25
**Scope:** office `index.html` (16,034 lines), `field-app/` (2,710 lines),
`docs/sql/*`, and the live Supabase project.
**Branch:** `claude/code-review-architecture-5lz8s4` — nothing here is on `main`.

Read `CLAUDE.md` first; it takes precedence over anything below.

---

## 1. Bugs — fixed on this branch

Five defects, all confirmed by reading the code and checking it against the
live database, not by suspicion.

### 1.1 The Doctoring report's table never rendered — FIXED

`renderDoctoringTable` was declared **twice at top level** of the same
13,000-line script, at lines 8230 and 13521. Function declarations hoist and
the last one wins, so *every* call went to the lot-detail version:

```js
renderDoctoringTable(rows);          // Reports -> Doctoring, line 7811
function renderDoctoringTable(rows)  // line 8230  <- shadowed, never ran
function renderDoctoringTable()      // line 13521 <- this ran instead
```

The surviving version ignores the `rows` argument, reads the *lot detail*
filter boxes, and writes into `doctoringContent` / `doctoringSummary`. It
never touches `reportDocTableContent`, which is written **nowhere else** —
verified. So Reports → Doctoring showed its summary and charts and then
nothing where the detail table belongs, and the column sort was dead code.

No error, no stack trace. It fails silently because both DOM elements exist
(the lot-detail markup is present but hidden), so nothing throws.

**Fix:** renamed the lot-detail one to `renderLotDoctoringTable` and updated
its four references. The report keeps the original name.

### 1.2 Every "today" default was tomorrow after ~7pm — FIXED

Eleven date defaults used `new Date().toISOString().slice(0, 10)`.
`toISOString()` is UTC. Central is UTC−5/−6, so from about 7pm the UTC date
is already the next day:

```
Local wall clock : 8/25/2026, 7:30:00 PM
toISOString()    : 2026-08-26T00:30:00.000Z
slice(0,10)      : 2026-08-26   <- what the form defaulted to
correct local day: 2026-08-25
```

Evening is exactly when a day's work gets entered. The affected sites write
to the books: the deaths modal date and its save fallback, the move date and
its save fallback, receipt date, sale date, the doctoring datepicker, lot
arrival date, duplicate-lot arrival date, and protocol `effective_from`.

The app already knew about this — `dfrLocalDay()` at line 6982 exists
precisely because "toISOString() is UTC and would roll the date over during
the evening." The daily report used it. The forms did not.

**Fix:** added `todayLocal()` next to `fmtDate` and pointed all eleven sites
at it. Filenames (`yard_sheet_2026-08-25.csv`) deliberately left alone — the
date in a filename does not reach the books.

### 1.3 Field app silently dropped records saved during a sync — FIXED

`processSyncQueue()` snapshotted the queue, awaited a network round trip per
item, then ended with `syncQueue = stillFailed`.

Every send is an `await`. A cowboy saving a record mid-drain calls
`enqueueForSync`, which pushes onto `syncQueue` and then calls
`processSyncQueue()` — which returns immediately on the `isSyncingQueue`
guard. That push was the only record of the new entry, and the closing
assignment overwrote it. No retry, no rejection entry, no badge. Silent loss
of animal health data, which `CLAUDE.md` explicitly forbids.

The obvious fix — keep anything whose `id` is not in the snapshot — is
**wrong**, and I wrote it before catching it: `enqueueForSync` de-dupes by
id, so an *edited* record re-queues under the same id. Filtering by id
discards the correction and keeps the stale copy. The fix matches on object
identity and drops a failed retry when a newer version of the same record
arrived while draining.

Verified against all three races with the real algorithm:

| scenario | old code | fixed |
|---|---|---|
| new record saved mid-drain | **lost** | kept |
| record edited mid-drain | **lost** | kept |
| edit mid-drain + old copy fails to send | **stale copy kept, edit lost** | edit kept |

### 1.4 An uncounted move could kill a whole approval batch — FIXED

A field move with no head count was classed a **warning**, so its checkbox
stayed enabled. But `record_move_with_pasture` opens with:

```sql
IF p_head_count IS NULL OR p_head_count <= 0 THEN
    RAISE EXCEPTION 'Head count must be positive (got %).', p_head_count;
```

It can never post. Approval is all-or-nothing, so selecting one alongside a
good day's work fails the batch and rolls back every correctly-posted row
with it.

**Fix:** it is a blocker now, which is what `ready` is for.

### 1.5 Dead code that bypassed the head-math architecture — REMOVED

`openEditAssignmentModal` and `deleteAssignmentRow` (67 lines) were
unreferenced — a comment claimed the "Currently In card" used them; nothing
does. They raw-`UPDATE` and raw-`DELETE` `lot_pasture_assignments`, which
`CLAUDE.md` forbids and which produces drift instantly. Deleted so nobody
re-wires them. Also removed a second, identical top-level `ceilTo`.

---

## 2. Bugs found and deliberately NOT fixed

### 2.1 A failed approval batch can strand entries as permanently approved

**This is the most serious thing in the review, and it needs a schema change,
not a patch.**

`approveSelected()` posts every row to the books, then in a *second loop*
marks each staged row `approved`. If that second loop fails partway — row 3
of 5 — the `catch` calls `rollbackPosted()`, which deletes **all** the book
rows. But rows 1 and 2 are already marked `approved`, and
`pfe_guard_settled()` makes that terminal (verified against the live
function):

```
approved  -> (terminal)
RAISE EXCEPTION 'pfe_settled: entry % is approved and cannot be modified'
```

Result: the work is gone from the books, and the staged entries can never be
re-approved through the app. Recovery needs an owner deleting the staged rows
in SQL and the cowboy re-entering the day.

Low probability — it needs an UPDATE to fail after INSERTs succeeded. High and
irreversible consequence.

**Why I did not patch it:** every client-side fix is a half-fix. PostgREST
gives no client transaction, so "all or nothing" is currently
post-then-roll-back-on-failure, and that is structurally unable to keep the
books and the queue in step. The right fix is one `approve_field_entries(uuid[])`
RPC that does the posts and the status updates in a single Postgres
transaction, which makes rollback the database's problem and deletes
`rollbackPosted()` entirely. That is a real change to the books' write path and
it needs your sign-off. **It is item 1 in the build order below.**

### 2.2 `guard_last_owner()` is callable by `anon` over the API

Flagged by the Supabase advisor. It is a *trigger* function on
`user_profiles` and has no business being reachable via
`/rest/v1/rpc/guard_last_owner` by anyone, let alone unauthenticated. It is
exposed only because Postgres grants EXECUTE to PUBLIC by default — exactly
the hole `CLAUDE.md` rule 4 warns about.

Impact is low: called outside a trigger it errors on an undefined `TG_OP`.
But it is the last anon-executable function on the auth path.

Pasteable SQL is in `docs/sql/2026-08-25_revoke_guard_last_owner.sql`, with a
verify block. Revoking EXECUTE does not break the trigger — Postgres checks
TRIGGER on the table when it fires, not EXECUTE on the function. **Not
applied; the MCP connector is read-only and production DDL is your call.**

### 2.3 Two latent problems that are not wrong today

Stating these honestly: neither is producing a bad number right now.

- **Field-app dose maths is a second implementation.** The office uses
  `dose_mode` / `per_weight_rate` / `per_weight_basis` / **`round_up_to`**.
  The field app builds a `"rate/basis"` string and `Math.ceil()`s to a whole
  number — it never fetches `round_up_to`. They agree only because 23 of 24
  active meds have `round_up_to = 1.0`. The exception is **Synanthic** (0.5),
  which has never been entered on a doctoring event (checked: 0 uses). One
  `round_up_to` edit makes the phone and the office disagree on a dose that
  gets frozen as cost at approval.

- **`flagDuplicateApprovals` is unpaginated.** `doctoring_events` is at
  **1,091 rows** — already past the PostgREST 1,000-row cap — though the
  query is scoped by lot and the largest lot holds 613. Fine today. When a
  batch spans enough lots it truncates silently, the duplicate check passes
  something it should have blocked, the DB trigger rejects it at approval,
  and the whole all-or-nothing batch dies — the exact failure the function
  exists to prevent.

- Minor: `.maybeSingle()` at line ~14844 runs on a query that can legitimately
  return several rows (a tag active on more than one lot). The error is
  destructured away, so it degrades to a misleading "not registered to any
  active lot" message.

---

## 3. What is actually fluff

Measured against the live database, not guessed.

| Feature | Code | Rows in production | Verdict |
|---|---|---|---|
| Invoice + receipt attachments | ~250 lines, storage bucket, RLS, 2 modals | **0 / 0** | Built, never used |
| `weights` table | 2 references | **0** | Effectively not in the app |
| `lot_adg_phases` | **0** references | **0** | Dead schema |
| `login-diagnostic.html` | 8 KB, public on Pages | — | Debug page, still live |
| Test lots in production | — | **3** (`TEST_DOC1`, `TEST_DOC2`, `Test-1`) | Noise in the real books |

Everything else earns its place. `field_protocols` (4), `forage_types` (3),
`protocols` (6), `field_actions` (7), `invoices` (33), `sales` (14) are all
in genuine use. The reports are not fluff — Anomalies, Yard Sheet, Daily
Report and Fresh Cattle are the operational core.

**My vote:**
- **Attachments** — this is not fluff, it is zero adoption. Photographing a
  delivery receipt at the chute is worth more than most of the roadmap. Either
  surface it properly or delete it; leaving it half-alive is the worst option.
  Ask me to do one or the other.
- **`lot_adg_phases`** — drop the table. Nothing references it.
- **`weights`** — decide. Real weigh-ups would sharpen every breakeven, but
  two references and zero rows means today it is a stub.
- **`login-diagnostic.html`** — delete it. It served its purpose during the
  auth work. It embeds the (already public) key and offers a tidy login-testing
  form to anyone who finds the URL.
- **Test lots** — `isTestLot()` filters them from reports, which is a workaround
  for their being there at all. Move them out or delete them.

---

## 4. Simplification — the honest read on one big file

790 KB and 16,034 lines in one file, with ~243 functions sharing one scope.

**The costs are no longer theoretical.** Bug 1.1 is exactly what a
13,000-line shared scope produces: two functions, same name, no warning,
one silently deleted. `ceilTo` was doubled the same way and only escaped
because the two copies happened to be identical. That will happen again.

**But "no build step" is a real asset here,** not laziness. Deploy is
`git push`. There is no dev team, no CI, no node_modules to rot. Adding a
bundler adds a way for a deploy to fail that does not exist today. On a
one-owner ranch app that is a bad trade.

**The way out is native ES modules — no bundler, no build step.**
`<script type="module" src="js/approvals.js">` works on GitHub Pages as-is.
Each file gets its own scope, so the collision class of bug disappears
structurally rather than by vigilance.

**My vote: C.**

- **A — leave it as one file.** Cheapest today, and the next silent collision
  is already priced in.
- **B — big-bang split into modules now.** ~2 days of mechanical work on a
  live app with no test suite, for zero user-visible benefit. The risk is
  concentrated exactly where you cannot afford it.
- **C — build all new code as modules; peel off old code only when you are
  already touching it.** Inventory becomes `js/inventory.js`, the first
  module. The pattern is proven on new code where a mistake is cheap, and
  nothing working gets destabilised to prove a point. Reports peel off
  easily later — they are leaf nodes with few callers.

**Shipped as part of this: `tools/check.mjs`.** It runs the two gates
`CLAUDE.md` already requires (script parses, `<div>` balanced) plus the one
that was missing — duplicate top-level function declarations. Run
`node tools/check.mjs` before any deploy. Against the pre-fix file it fails
with exit 1 and names both collisions; against the fixed file it passes.
It is 200 lines, needs nothing installed, and would have caught 1.1 the day
it was introduced.

---

## 5. Modules — is it time for Inventory?

**Yes for medicine. Not yet for commodity and mineral, and they should not be
the same build.**

The three things you named have different shapes:

| | How it is consumed | Already modelled? |
|---|---|---|
| **Medicine** | per animal, per event, cost frozen at save | Yes — `doctoring_event_meds` |
| **Commodity** (feed, protein, hay) | by a pasture or lot over time | No |
| **Mineral** | by a pasture over time | No |

Commodity and mineral are the same shape: a consumable put out in a place,
consumed by whatever grazes there, costed by **per-head-day allocation**.
That allocation engine is precisely what roadmap item 4 — the cost ledger —
is for. Building an Inventory module that allocates feed per head-day *before*
the cost ledger means writing that engine twice and reconciling two answers.

Medicine is genuinely different: consumption is already captured per animal
at the dose. Adding on-hand quantity is a small, self-contained addition that
pays off immediately.

### What medicine inventory buys you

1. **Reorder visibility** — on-hand against usage rate.
2. **Reconciliation, which is the real prize.** You already know what the
   books say you used: sum `dose_cc` over `doctoring_event_meds`, plus
   receipts × `protocol_meds` for processing. Count the shelf and the
   difference is either waste or a doctoring event that was never recorded.
   That is a **data-quality check on treatment cost**, which feeds breakevens.
   Nothing else on the roadmap catches a missed doctoring event.

### The landmine to design around — read before building

`CLAUDE.md` already warns that **processing cost is derived LIVE** from
current `medications.cost_per_unit`, so editing a price retroactively rewrites
every lot that ever used that protocol, closed lots and prior fiscal years
included, silently.

Inventory makes that trap automatic. The natural design — receive a bottle at
a new price, update weighted-average cost — would silently rewrite the books
every time you buy product.

**So: receiving inventory must write a purchase record and must NOT touch
`medications.cost_per_unit`.** Price changes stay a deliberate act using the
protocol-versioning dance in `docs/processing-cost-and-protocol-versioning.md`.
Inventory tracks *quantity*; pricing stays where it is. If you later want
true weighted-average costing, it has to be frozen per event like treatment
cost already is — never derived live.

### Shape

Two tables, one module, no allocation engine:

```
medication_purchases   (medication_id, qty, unit, unit_cost, purchased_on,
                        vendor, invoice_id?, notes)
medication_adjustments (medication_id, qty_delta, reason, adjusted_on, notes)
                        -- counts, breakage, expiry; every change is a row
```

On-hand is a view: purchases − recorded usage + adjustments. No mutable
`quantity_on_hand` column, so there is nothing to drift and every movement has
an audit row — the same discipline as `lot_pasture_assignments`.

Built as `js/inventory.js`, the first ES module.

---

## 6. Build order

1. **`approve_field_entries()` RPC** — one transaction for the whole batch.
   Fixes 2.1, deletes `rollbackPosted()`, and removes the only path that can
   put the books and the staging queue permanently out of step. Do this before
   the first real Dead and Move go through Approvals (both still unexercised
   on production data per `HANDOFF.md`).
2. **Apply the `guard_last_owner` revoke** — SQL is written and waiting.
3. **Paginate `flagDuplicateApprovals`; make the field app fetch
   `round_up_to`** and use one dose function. Both are small and both are
   latent-today, wrong-later.
4. **Fluff decisions** (§3) — attachments in or out, `lot_adg_phases` dropped,
   diagnostic page deleted, test lots moved out. An hour, and it shrinks the
   surface everything else has to be correct against.
5. **Medicine inventory** as `js/inventory.js` — the first module, and the
   proof that modules work here.
6. **Cost ledger** (roadmap 4) — and fold **commodity + mineral** into it as
   consumables sharing one per-head-day allocation engine. Still blocked on a
   Redwing export.
7. **Daily buy/sell dashboard** (roadmap 5).

Items 1–4 are correctness and cleanup and should land before new surface area.
Item 5 is the first genuinely new thing.

---

## Verification

- `node tools/check.mjs` — passes; fails with exit 1 on the pre-fix file.
- Both inline script blocks parse; `<div>` balanced 569/569 outside
  script/style, per `CLAUDE.md`.
- `field-app/app.js` parses; queue fix tested against all three race cases.
- No schema or data changes were made. The Supabase connector is read-only and
  was used only to read row counts, medication config, and function definitions.
