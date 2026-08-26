# Architecture — how the system fits together, and why

**Last reviewed:** 2026-08-26. Verified against the repo and the live schema on
that date; the verification numbers below are from that sweep.

`CLAUDE.md` holds the standing rules and **takes precedence over this file**.
This one explains *why* each of those rules exists — mostly by recording what
broke. Read it before changing anything structural; the rules look arbitrary
until you know the incident behind them.

---

## 1. The shape

```
                     Supabase project xpfmebdzcxorvwikfvtj
                     PostgreSQL + auth + PostgREST
                                  ▲
              ┌───────────────────┴───────────────────┐
              │                                       │
     office app (the books)                 field PWA (cowboys)
     index.html, repo root                  field-app/, build v12
     ~800 KB, one <script> block            app.js + vendored supabase.min.js
     reads and writes everywhere            writes ONE table: pending_field_entries
     role: office / owner                   role: crew (in principle)
```

Both are static files on GitHub Pages. There is no server, no build step, and no
API layer of our own — PostgREST plus RLS *is* the API, which is why the RLS
rules in `CLAUDE.md` are load-bearing rather than defence in depth.

### Repo layout

| path | what |
|---|---|
| `index.html` | the entire office app (~800 KB) |
| `field-app/` | the field PWA: `index.html`, `app.js`, `styles.css`, `sw.js`, `manifest.json`, `supabase.min.js`, icons |
| `login-diagnostic.html` | standalone auth troubleshooting page |
| `CLAUDE.md` | standing rules |
| `HANDOFF.md` | narrative of the field-app merge and retirement |
| `docs/` | this file, roadmap, open items, security model, guides, applied SQL |
| `docs/sql/` | every migration and correction actually applied, dated |

### Office app navigation

Five top-level tabs — **Lots, Animal Health, Approvals, Reports, Settings** —
with sub-tabs including active-lots, doctoring, doctoring-entry, field-actions,
field-protocols, meds, protocols, locations, users, yard-sheet, anomalies,
death-analysis, pasture-utilization, processing-costs, daily-report, data-tools.
Closeout is a sub-view on lot detail.

77 controls carry a role gate: 69 `data-perm="office"`, 8 `data-perm="owner"`.

### Field app mechanics

- `SUPABASE_URL` / `SUPABASE_ANON_KEY` at the top of `field-app/app.js`; the
  client is `sb`. `STAGING_TABLE = 'pending_field_entries'` is its only write
  target. Google Apps Script and the Google Sheet are out of the loop entirely.
- **Service worker is network-first for the app shell** (`isAppShell()`),
  stale-while-revalidate for everything else. It used to be cache-first, which
  left every device one deploy behind and — worse — able to pair new HTML with
  old JS.
- `CACHE_VERSION` (currently `v12`) is bumped on every deploy of the field app.
- `DATA_SCHEMA_VERSION` (currently `4`) gates `checkDailySync()`. It used to
  check only whether `records` existed, so a device that had cached data before
  new lookups were added looked synced while holding empty tag maps. **Bump it
  whenever the shape of cached data changes.**
- All `JSON.parse(localStorage…)` sites go through `loadJSON()`, which self-heals
  a corrupt value instead of throwing. This exists because a careless
  find-and-replace once stored a literal key name where JSON belonged; the parse
  threw on load and killed every event handler, and Lauren could not sign in at
  all. **The tests missed it because they always started from empty storage and
  never reloaded after a pull.**
- `supabase.min.js` is vendored pristine from npm (2.46.1). An earlier attempt
  concatenated it with a webpack chunk whose leading `"use strict"` became a
  prologue for the whole file. Do not concatenate it with anything.
- The inline boot-diagnostics block in `field-app/index.html` runs before
  `app.js`, catches `error`/`unhandledrejection`, renders into `#bootError`, and
  wires a `hardReset()` with no dependency on `app.js`. That independence is
  what made a dead-on-boot app recoverable in the field.

The old standalone repo `johnfreagan/JFR-Ranch-Cattle-Field-App` is retired: its
`index.html` is a redirect stub and its `sw.js` is a self-destructing worker with
**no fetch handler**, so the stale shell can never be served again. `localStorage`
is deliberately left alone — same origin, shared with the new URL. Replacing only
`index.html` would not have worked: the old worker serves its *cached* copy, so
users would never see the stub. Disabling Pages and archiving is
`docs/OPEN-ITEMS.md` item 4.

---

## 2. Head math is the spine

`head_in − head_dead − head_sold = head_current`, and `head_current` must equal
the sum of open `lot_pasture_assignments`. Divergence is **drift**.

Everything downstream — head-days, cost of gain, closeout, the Anomalies report
— assumes this holds. That is why deaths, moves, sales and receipt deletions go
through atomic RPCs rather than plain inserts and deletes, and why a plain
`doctoring_events` insert for a `Dead` action is a bug rather than a shortcut.

**The reversal bug worth remembering.** `delete_death_event` reopened a closed
assignment (`moved_out = null`) *and* added the head back to `head_count`.
Reopening already restores the count, so 3 head, a death of all 3, and a reversal
produced a lot with 6. Fixed 2026-08-25. Any new reversal RPC must be tested
against a lot whose assignment the event closed **outright**, not just one it
partially decremented — the partial case passes either way and hides the bug.

**Historical drift.** Lot 37X carried −3: sixteen deaths predated the lot's first
pasture assignment (an April import). Corrected 2026-08-25 by reducing
Steele–Front Native 244→241 with an audit note, John's call. All lots verified at
zero drift after.

---

## 3. Two cost systems that behave oppositely

| | processing (receiving) | treatment (doctoring) |
|---|---|---|
| captured on | `delivery_receipts.receiving_protocol_id` | `doctoring_events` + `doctoring_event_meds` |
| cost is | **derived live** from current prices | **frozen per row** at save time |
| denominator | per head **IN** | per **live head current** |

This asymmetry is the single most dangerous thing in the schema, because the
same action — "update a medication price" — is harmless in one system and
retroactive in the other.

`lot_processing_costs` and `lot_processing_cost_detail` join receipts →
`protocol_meds` → `medications` and read **current** price, dose config and
`round_up_to`. Editing a protocol's meds, or a medication's price or rounding,
therefore rewrites processing cost for **every lot that ever used it** — closed
lots and prior fiscal years included, silently, with no audit trail.

`protocols.effective_from` is **decorative**. The cost views never reference a
date. Creating a new version with an effective date changes nothing on its own.

**The correct procedure** (full version in
`docs/processing-cost-and-protocol-versioning.md`): create a NEW protocol row
(`parent_protocol_id` → old, new `version_label`, set `effective_from`), then
`UPDATE delivery_receipts.receiving_protocol_id` on exactly the receipts on or
after that date. Never edit the old protocol in place — the earlier loads
genuinely got the old product and their books must keep saying so.

**Worked example, 2026-08-24.** Lot 36-27, Draxxin → Macrosyn effective Wed
2026-08-19. New protocol version created; 5 of 11 receipts (197 of 441 head)
repointed. Lot processing went $9,109.06 → $8,901.48, or $20.66 → $20.18 per head
in. The six Aug 11–18 loads stayed on branded Draxxin.

**Two traps around pricing:**

- An unpriced medication prices as NULL, and `SUM()` ignores NULL — the line
  silently vanishes from processing cost instead of erroring. Price the med
  *before* pointing a protocol at it, check `unpriced_line_count` after any
  protocol change, and guard repoint scripts with a pre-check that raises if any
  med on the target protocol has both `cost_per_unit` and `cost_per_head` null.
- `round_up_to` models the **syringe setting including waste**, not drug
  consumed. A generic entered at 0.1 against a brand at 1.0 is a math change
  disguised as a price change. Keep it consistent between generic and brand of
  the same drug.

---

## 4. Head-days, and the clock

### Two implementations that disagree

- The FUNCTION `lot_head_days(uuid, date)` anchors on
  `lot_weighted_arrival_date()`, built from **invoice** dates.
- The VIEW `lot_head_days_by_month` (over `lot_daily_head`) walks arrivals by
  **receipt** date.

Where invoices follow receipts closely they agree within ~1%. On 36-27 the
function read 2,646 against the view's 3,424 — 29% low — because the cattle
landed Aug 11 and the invoices weighted to Aug 19.

**Use the view for anything involving cost.** Cattle eat from the day they hit
the ground, not from the day the invoice clears.

Neither may be rebuilt on `lot_pasture_assignments`: 37X's assignment history
starts 2026-04-27 against a first invoice of 2025-12-04, so that basis would
silently drop 144 days. `lot_daily_head` reconciles to `lot_status.head_current`
by construction and is verified to do so on every lot.

### The database runs UTC; the ranch does not

`CURRENT_DATE` becomes tomorrow at 7pm Central (6pm in CST). `lot_daily_head`
shipped with `CURRENT_DATE` and gained a whole extra day of head-days each
evening — 441 on 36-27, $882 at its rate, for a day Texas had not had.

SQL uses `public.ranch_today()`. The app matches it with `ranchToday()`, pinned
to `America/Chicago` rather than the viewer's clock. `toISOString()` in the field
app is the same trap wearing a different hat.

---

## 5. Closeout — budget, actual, projection

Rebuilt 2026-08-25. One set of economics in three columns, office+owner only.

| column | source |
|---|---|
| **Budget** | `lot_budgets`, frozen when the lot starts, immutable |
| **Actual** | the books: invoices, processing, treatment, real head-days |
| **Projection** | actual to date, carried forward to the ship date |

**Why `lot_budgets` is frozen by a trigger rather than a policy.** Office and
owner deliberately **pass** the RLS check on UPDATE so `lot_budgets_frozen()`
fires and raises a real error. Denying at the policy layer would make PostgREST
return zero rows, and the app would cheerfully report a save that changed
nothing. Owner-only DELETE is the escape hatch for a budget typed wrong.
Assumptions that change over the life of the lot stay on `lots.*`, not here.

**Everything is computed in total dollars and divided at the end.** This is what
fixes the death-loss double count: the old per-head math added a death-loss line
on top of a cattle cost that already contained the dead animals, and applied the
full assumed percentage to a head count already reduced by the deaths that had
happened — 6% budgeted plus 5% already buried came out near 11%. In total dollars
death loss needs no line at all; it falls out of the division. The projection
estimates only **deaths still to come**:
`clamp(0, head_current, head_in × pct − head_dead)`.

**Cost of gain and labor charge against head-days, never today's head count ×
total days.** Cattle that shipped in June ate grass until June. On 37X-1 the old
math charged 75 head × 231 days = 17,325 head-days against a real 56,993 — about
$39,700 of cost that appeared nowhere. A **per-head** (flat) COG or labor rate is
charged once on `head_in` and never carried forward again; only **per-day** rates
accrue on head-days.

**Interest** accrues on the cattle for the whole period and on operating cost at
half the period — the usual convention for a cost that builds linearly. The old
screen charged interest on the purchase price only.

**Treatment carries forward at the lot's own observed $/head-day**, not at the
budgeted med figure. Once there is history, the lot's own burn rate beats an
assumption.

**Naming trap:** `lots.target_sale_cwt` is **$/lb** despite the name, and
`lot_budgets.budget_cost_per_cwt` follows it for consistency. Both are multiplied
by a weight in pounds. Do not "fix" one without the other.

Also fixed in the rebuild: the Closeout tab was visible to crew, and it rendered
before `loadSales` so it showed the previously viewed lot's sales.

**Live data problems this surfaced** are tracked in `docs/OPEN-ITEMS.md` item 9 —
37X-1 had labor at $35.00/head/day (corrected to $0.35), 47-26 and 60X carry no
cost assumptions at all, and 36-27 sits at $2.00/head/day COG against 0.75–1.00
everywhere else. Nothing validates these on entry; a rate off by 100× produces a
confident, wrong projection.

---

## 6. Field → books

```
field PWA → pending_field_entries → office Approvals tab → RPC → books
         ↑ localStorage queue keeps this offline-first
```

The field app's only write surface is the staging table. Nothing a cowboy records
reaches the books until someone in the office approves it.

### `pending_field_entries` as built

`id uuid pk`, `entry_type text` (`'doctoring'` | `'move'`), `raw jsonb` (the field
payload verbatim, never edited), `client_id text` (the app's own id —
`String(Date.now())`, or `"M-"+…` for moves), resolved FKs nullable until review
(`lot_id`, `pasture_id`, `to_pasture_id`, `field_action_id`, `tag_number`,
`no_tag`, `head_count`, `resolved_meds`), `status`, `review_notes`,
`approved_ref jsonb` (`{kind, id}`), `submitted_by`, `reviewed_by`, `reviewed_at`,
timestamps. There is no `approved_at`. Grants are pinned to
`{authenticated, service_role}`, revoked from `PUBLIC` and `anon`.

**Three things the original design got backwards, all corrected in the build:**

1. **`(entry_type, client_id)` is an UPSERT key, not a reject-duplicates
   constraint.** The field app re-sends an *edited* record under the same client
   id, so the second send must overwrite the first — rejecting it would strand
   the correction on the phone. Submitting the same entry twice correctly yields
   **one row reflecting the second submission**; testing for a rejection is
   testing for the wrong behaviour.
2. **`status` has a fourth value, `'withdrawn'`**, because the field app can
   delete a record. `pfe_guard_settled()` enforces transitions in the DB:
   `pending → approved | rejected | withdrawn`; `withdrawn → pending` and
   `rejected → pending`; **`approved` is terminal.**
3. **There is no `'dead'` entry_type.** A death arrives as
   `entry_type='doctoring'` and is identified by `field_actions.is_dead` on its
   resolved action. Anything classifying entries must check `is_dead`, not the
   entry type. This is the easiest thing on this page to get wrong.

### Mapping free text → UUIDs

| field payload | target | notes |
|---|---|---|
| `treatmentType` | `doctoring_events.field_action_id` (**NOT NULL**) | match on `field_actions.name` — already aligned |
| `location` (`"Ranch - Pasture"`) | `pasture_id` | split on `" - "`, resolve ranch then pasture; ambiguity → null, force review |
| `lotNumber` | `lot_id` | scope to **OPEN** lots (tags recycle) |
| `medication1..3` | `doctoring_event_meds.medication_id` | fall back to `medication_name_freetext` when unmatched |
| `dosage1..3` (text) | `dose_cc` (numeric) | parse; non-numeric → null + flag |
| `tagNumber` / No Tag | `tag_number` (text), `no_tag` (bool NOT NULL) | direct |

On approve, write `legacy_source='field_app'` and `legacy_id=client_id` into
`doctoring_events`, and stamp `approved_ref` on the staged row.

**Never auto-create** ranches, pastures, lots, or medications from field text. An
unresolved name is a review item, not a new row.

### Three landmines

1. **`Dead` is not a doctoring event.** Approval must branch on
   `field_actions.is_dead` and call `record_death_with_pasture`. A plain insert
   creates drift.
2. **Field moves carry no lot**, but `lot_movements.lot_id` is NOT NULL. The
   reviewer must pick; pre-select when the from-pasture holds exactly one open
   lot.
3. **Med cost freezes at approval**, not at field capture — the cowboy's phone
   has no pricing. Price the med before approving anything that uses it.

### The Approvals screen as built

One line per entry, not a card layout. Rows group by **work day** (newest first),
then sort by lot → pasture → tag. Doctoring, Move and Dead each have a section.
Checkbox per row.

- **Per-row note** writes `review_notes` without changing status, so an entry can
  be parked with a reason and picked up later.
- **Per-row date correction** shifts `event_datetime` by whole days and rewrites
  only the date half of `raw.dateTime`, preserving time of day. Guarded
  `.eq('status','pending')` so a posted entry can never be rewritten. Appends an
  audit note. Added after John entered a doctoring on the wrong day and found he
  could not fix it from either app.
- **Batch approve is all-or-nothing** (John's call). If any row fails,
  `rollbackPosted()` unwinds what was already written.
- **Order within a batch matters:** doctoring first, then deaths and moves sorted
  by `event_datetime`. Head-math entries must replay in the order they happened
  or a move can outrun the death that freed the head.
- **Deaths approve without a cause**; cause is filled in later on the lot.
  Carcass disposal is flagged when the animal was **NOT** hauled off. `drug_off`
  means "removed to the proper location for dead animals" — nothing to do with
  drug withdrawal.
- **Unpriced meds are flagged permanently.** Do not approve past the flag.
- Reject sets `status='rejected'` + `review_notes` and surfaces back in the
  cowboy's app. Rejected entries are never deleted and can be reopened.

### Verified in production, 2026-08-25

Eleven real doctoring entries, lot 36-27, First Pull EX, over three work days.
All eleven posted with `legacy_source='field_app'`, a real `approved_ref`, two med
rows each, cost frozen at ~$16.17/head, **zero unpriced lines**. Drift = 0 on
every open lot after (36-27, 37X, 37X-1, 37X-F, 47-26, 59X, 60X). The date
correction was exercised for real: tag 8288 moved Aug 25 → Aug 24, time of day
preserved, audit note on the staged row.

**Still unexercised on production data: a real Dead and a real Move.** Both are
built, RPC-backed, and their reversals were tested against a local Postgres
replica — that testing is what caught the `delete_death_event` double count. John
will run one of each as they occur and flag it for verification. Check
`event_datetime`, the `approved_ref`, and **drift on the affected lot** after.

---

## 7. Security model

Detail lives in `docs/security-model.md`; the rules are in `CLAUDE.md`. The parts
worth restating here are the reasons.

**Why RLS is not defence in depth.** There is no server of ours between the
browser and the database. The publishable key is embedded in both apps, which is
correct and expected — and it means anything granted to `anon` is public to the
internet. `authenticated` + RLS is the only path.

**Why `security_invoker` on every view is absolute.** A view without it runs as
its owner and bypasses RLS entirely, regardless of what the base-table policies
say. Ten views were exposed exactly this way in Aug 2026 and were readable by
`anon` with no login at all.

**Why roles never come from `raw_user_meta_data`.** That field is written by the
client at signup. `handle_new_user()` trusted it, so `signUp({data:{role:'owner'}})`
minted a working owner account. The trigger is `AFTER INSERT ON auth.users FOR
EACH ROW`, so the same hole applies to `inviteUserByEmail` and
`admin.createUser`. New users land `role='crew'`, `is_active=false`; an owner
activates them.

**Why deletes are the narrowest privilege.** `lot_movements`, `lot_events` and
`lot_pasture_assignments` are audit trails. An accidental delete there is
unrecoverable in a way an accidental insert is not.

**Sweep of 2026-08-26 — all clean:**

| assertion | result |
|---|---|
| tables in `public` | 28, all RLS-enabled, all carrying policies |
| views in `public` | 12, all `security_invoker = true` |
| objects readable by `anon` | 0 |
| `SECURITY DEFINER` functions | 7, all with a pinned `search_path` |

The seven are `current_user_role` (the gate), `admin_list_users`,
`guard_last_owner`, `handle_new_user`, `cleanup_attachment_storage`,
`lot_projected_weight`, `lot_weighted_arrival_date`. The first four are
deliberate and fail closed. The two lot functions predate the hardening work and
have not been reviewed. The head-math RPCs are all `SECURITY INVOKER` and must
stay that way — they have to run under the caller's RLS.

**There is no standing verify script.** `CLAUDE.md` rule 7 once cited
`supabase/migrations/20260821000300_rls_verify.sql`; **that file, and the whole
`supabase/` directory, do not exist in this repo.** Every migration since has
either skipped the check or inlined its own assertions. Inline assertions only
cover the objects that migration touched — nothing sweeps the whole schema for a
view missing `security_invoker`, a table with RLS and no policy, or a fresh grant
to `anon`. Tracked as `docs/OPEN-ITEMS.md` item 8.

**A refused UPDATE or DELETE is silent.** PostgREST returns an empty result
rather than an error when RLS filters every row, so a save can report success
while changing nothing. Only the Users screen asserts on the returned row count.
The role gate hides the controls where this would bite, which is why it is not
urgent — but any new write path added without a `data-perm` will hit it.

### Offline consequences

- An RLS denial on SELECT returns **zero rows, not an error**, so "no lots" is
  ambiguous between not-authorized, offline, and genuinely empty. Call
  `current_user_role()` on load and distinguish all three, or every access
  problem looks like a sync bug.
- A write queued offline replays under **later** authorization: queued Tuesday,
  synced Thursday, user deactivated Wednesday → `42501`. Needs a dead-letter
  path — never a silent drop (this is animal health data), never infinite retry.
- Purge local stores on sign-out and on user change; IndexedDB knows nothing
  about RLS. Persist the write queue outside the auth session, keyed by user id;
  days offline can outlive the refresh token.

---

## 8. Migrations

The remote has **no CLI migration history**. This schema was built through the
dashboard and SQL editor, so `supabase db push` would try to apply every local
migration from scratch against tables that already exist.

Until that is reconciled, apply migrations through the **SQL editor** and keep
the applied file in `docs/sql/`, named `YYYY-MM-DD_what-it-does.sql`. Files there
carry explicit `begin;`/`commit;` so they are all-or-nothing in the editor —
**strip those two lines if applying via the CLI**, which wraps migrations in its
own transaction where the inner `commit;` closes it early. Note the editor
*swallows* `begin;`/`commit;` in some paths and can report "Success. No rows
returned" without applying anything.

To adopt the CLI: `supabase link --project-ref xpfmebdzcxorvwikfvtj` →
`supabase db pull` for a baseline → mark it applied → verify with
`supabase migration list`. This is in `docs/roadmap.md` as a background item.

Applied to date (`docs/sql/`): crew read-only, pending_field_entries, users
admin, crew read-all staged entries, 37X assignment drift, 37X-1 labor rate,
budget and head days, head-days rename, record_move_with_pasture, ranch_today.

---

## 9. Conventions that exist for a reason

- **Validate before shipping `index.html`:** the big script block must parse
  (`new Function`) and `<div>` open/close counts must balance outside
  script/style. One file, no build step, no type checker — this is the only
  safety net there is.
- **Role-gate every new control** with `data-perm`. Without it, a control a role
  cannot use will silently no-op rather than refuse.
- **Idempotent SQL, always** — `IF NOT EXISTS`, guarded `DO` blocks that
  `RAISE EXCEPTION` when state is not as expected.
- **Every direct data correction appends an audit note** to the row's `notes`:
  what changed, why, and the date. Historical scar tissue is real; read the notes
  before "fixing" anything.
- **Paginate.** PostgREST caps at 1000 rows, and its query builders are
  single-use — a pager must take a builder *function* and call it fresh per page.
- **Enumerate consumers before changing a fetch.** Swapping the field app's reads
  once silently lost dose auto-fill, tag recall, and the safety checks; the app
  reads more than it looks like it does.
