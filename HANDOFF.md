# Handoff — field app merge & retirement

**Last updated:** 2026-08-26 (both goals met and live. What remains is the old
repo's archive date, and a first real Dead and Move through Approvals.)

**Open items live in `docs/OPEN-ITEMS.md`** — read that first for what still
needs doing. This file is the narrative of how things got here.

Working note for picking up in-flight work, not app code. Read alongside
`CLAUDE.md`, which holds the standing business rules and schema landmines and
takes precedence over anything here. `docs/architecture.md` explains how the
system fits together and why each rule exists; `docs/roadmap.md` is what comes
next. The structure of this file is generalized as
`docs/handoff-spec-template.md` — follow it for the next piece of in-flight
work rather than extending this one.

---

## Core goal

Consolidate two cattle apps into one repo and one deploy, then retire the
duplicate. A secondary goal emerged during the work: connect the field app to
the production books. **Both are done as of 2026-08-25.**

| | Repo | Backend |
|---|---|---|
| Office app | `johnfreagan/JFR-Ranch-cattle-management-office-app-` | Supabase `xpfmebdzcxorvwikfvtj` — the real books |
| Field app (PWA for cowboys) | same repo, `field-app/` | **Supabase, same project** — via `pending_field_entries` |
| ~~Old field app repo~~ | `johnfreagan/JFR-Ranch-Cattle-Field-App` | retired; redirect stub only. Archive on/after 2026-09-14 |

Google Apps Script and the Google Sheet are **out of the loop entirely** — the
field app no longer writes to them. The Sheet was abandoned in place (test data
only, John's call).

---

## Current status

### Live on office repo `main`

- **`9536e37`** — field app copied verbatim into `field-app/` (5 files). No
  source edits were needed: every asset path was already relative
  (`manifest.json` `start_url`/`scope` `"./"`, `sw.js` `APP_SHELL` `"./"`,
  `navigator.serviceWorker.register('./sw.js')`), so the app resolves from the
  subfolder and its service worker scopes to `/field-app/` instead of the site
  root. The office app's caching is untouched.
- **`e8edbe1`** — PWA icons. `manifest.json` referenced `icon-192.png` and
  `icon-512.png`, but neither file existed. Added a JFR longhorn mark (white on
  the app's `#007aff`) at 192/512, plus `apple-touch-icon.png` (180) and its
  `<link>` in `field-app/index.html`, plus `icon.svg` as the vector source.

Office `index.html` is byte-identical to v83 across both commits — verified by
diff, not assumed.

**Live URL — confirmed working on John's phone (2026-08-24):**
`https://johnfreagan.github.io/JFR-Ranch-cattle-management-office-app-/field-app/`

### Part B, live on office repo `main` (2026-08-25)

Field app swapped off Google Apps Script and onto Supabase, plus the office
Approvals tab. Shipped across `e1d1359 … d191f13`. Field app is at **build v12**.

Things that broke on the way and are worth not repeating:

- **The service worker served the app shell cache-first**, leaving every device
  one deploy behind and — worse — able to pair new HTML with old JS. Now
  network-first for the shell (`isAppShell()`), stale-while-revalidate for the
  rest. Reproduced both ways before and after the fix.
- **A careless find-and-replace called `safeSetItem` with five arguments**,
  storing a literal key name where JSON belonged. `JSON.parse` threw on load and
  killed every event handler — Lauren could not sign in at all. Fixed, and all
  fourteen `JSON.parse(localStorage…)` sites now go through `loadJSON()`, which
  self-heals a corrupt value instead of throwing. **The tests missed it because
  they always started from empty storage and never reloaded after a pull.**
- **`checkDailySync()` only checked whether `records` existed**, so a device
  that had cached data before the new lookups were added looked synced while
  holding empty tag maps. Now gated on `DATA_SCHEMA_VERSION` (**currently 4**
  as of 2026-08-26) — bump it whenever the shape of cached data changes.
- **Swapping the reads lost three features** — dose auto-fill, tag recall, and
  the safety checks all went blind to the books. Fixed with a `lot_status` join
  and a `booksHistory` pool. Lesson: the field app reads more than it looks like
  it does; enumerate every consumer before changing a fetch.
- **`lots.start_tag`/`end_tag` is the first receipt only.** Tag resolution goes
  lot_tags → receipt ranges → and only then that fallback. John caught this:
  *"8310 is in the range of tags for 36-27 you just looked at first load."*
- **`supabase.min.js` is vendored pristine from npm (2.46.1).** An earlier
  attempt concatenated it with a webpack chunk, whose leading `"use strict"`
  became a prologue for the whole file. Do not concatenate it with anything.
- **`index.html` carries an inline boot-diagnostics block that runs first**,
  catches `error`/`unhandledrejection`, renders into `#bootError`, and wires a
  `hardReset()` that does **not** depend on `app.js`. That independence is the
  point — it is what made a dead-on-boot app recoverable in the field.

### Live on field app repo `main`

- **`1dc84cb`** — the retirement. Merged and pushed after the new URL was
  confirmed. The old repo now self-destructs installed copies and redirects:
  `sw.js` is a self-destructing worker with **no fetch handler** (so the stale
  shell can never be served again), and `index.html` is a redirect stub that also
  unregisters workers and clears caches. `localStorage` is deliberately left
  alone — same origin, already shared with the new URL.
- Old repo `main` went `23831a6` → `1dc84cb`. Both URLs now lead to the same
  place; the old one is a one-way door.

---

## Key decisions

### Made

- **Plain file copy, one commit — not `git subtree`.** History is not preserved.
  John was told and accepted; grafting an unrelated history into a production
  repo's `main` wasn't worth it.
- **Longhorn mark, not a "JFR" wordmark.** `manifest.json` declares
  `"purpose": "any maskable"`, so Android crops to a circle and only the centre
  80% survives. A safe-zone overlay render showed the wordmark-plus-horns combo
  had its horn tips falling *outside* that circle. The mark alone fits with room
  to spare, and the home screen already prints "Beta Tracker" underneath.
- **Retire the old repo** — chosen over "leave both live" and "redirect but keep
  it around".
- **Plan the Supabase wiring now, build later** — chosen over building it
  immediately.
- **No Google Sheet backfill.** Everything in the Sheet is test data (John's
  call). Supabase starts clean at cutover; the Sheet is abandoned in place.

### Ruled out / corrected mid-flight

- **Replacing only `index.html` in the old repo does not retire it.** The old
  service worker serves its *cached* `index.html`, so users would never see the
  stub — they'd keep running the dead app offline indefinitely. It takes a
  self-destructing `sw.js` as well. The original plan said one file; that was
  wrong and is corrected in `1dc84cb`.
- **Adding the icons to `sw.js` `APP_SHELL` + bumping `CACHE_VERSION`** —
  unnecessary. The fetch handler already caches same-origin GETs
  stale-while-revalidate, so icons cache on first load on their own.
- **Clearing `localStorage` in the retirement stub** — would have destroyed data
  the new app reads. See below.

---

## Critical technical findings

**Read the dates.** The first four bullets describe the app **as it was before
Part B** and are kept because they are why Part B was built the way it was.
They are no longer true of the code — each is marked. Everything from
`field_actions` down still holds.

- ~~**The field app has zero Supabase references.**~~ **Superseded 2026-08-25.**
  It was true when this was written: `CLOUD_URL` pointed at Google Apps Script
  and nothing a cowboy recorded reached the books — someone re-keyed it by
  hand. The field app now talks to Supabase directly (`SUPABASE_URL` /
  `SUPABASE_ANON_KEY` at the top of `field-app/app.js`, client `sb`,
  `STAGING_TABLE = 'pending_field_entries'`). There is no `CLOUD_URL` and no
  Apps Script call left in the file.
- **`localStorage` is shared between the old and new URLs.** Both are on origin
  `johnfreagan.github.io`, and storage is scoped per *origin*, not per path. The
  `betaCattle*` keys carry over with no migration, and both copies write to the
  same Sheet. This is why the stub must not clear storage.
- ~~**Writes are fire-and-forget.**~~ **Fixed 2026-08-25, as predicted.**
  `sendOne()` used `mode: 'no-cors'`, so a 500 from Apps Script looked exactly
  like success. Moving the transport to supabase-js fixed it for free: the app
  now reads the real response, and a rejected write surfaces to the cowboy
  (`⛔ Save rejected: …`) instead of vanishing. A rejected record never leaves
  the queue quietly — that was deliberate, this being animal health data.
- ~~**Reads are manual only.**~~ **Still manual, and still by design.** The
  JSONP `<script>` injection is gone; **🔄 Pull Cloud History** now runs
  authenticated Supabase reads. Nothing pulls automatically, which is the
  intended behaviour on a metered phone in a pasture.
- **`field_actions` already matches the field app exactly** — Receiving, First
  Pull EX, Second Pull RES, Pinkeye, Footrot Dart, Dead, Other. Action mapping is
  nearly free.
- **`Dead` is the landmine.** `field_actions.Dead` has `is_dead = true`, and a
  cowboy can pick it in the field app today. Approving that as a plain
  `doctoring_events` insert bypasses `record_death_with_pasture` and **creates
  drift**, breaking the head-math invariant.
- **Field moves carry no lot**, but `lot_movements.lot_id` is NOT NULL. A
  reviewer must pick the lot; it cannot be inferred.
- **`doctoring_events` already has `legacy_source` / `legacy_id`** — used as the
  idempotency key for live field submissions (not for historical import, which
  isn't happening).

---

## Active constraints

### From `CLAUDE.md` — non-negotiable

- Fiscal year runs Jul 1 – Jun 30, **named for the ending year**.
- Head math: `head_in − head_dead − head_sold = head_current`, and that must
  equal the sum of open `lot_pasture_assignments`. **Never create drift.**
- Deaths, sales, and receipt deletions go through atomic RPCs
  (`record_death_with_pasture`, `delete_receipt_with_reversal`, …). Never
  raw-delete.
- Production DB is a real ranch's live books. Schema changes and data
  corrections need explicit approval before execution.
- Query `information_schema` rather than guessing column names.
- Migration/correction SQL must be idempotent; direct data corrections append an
  audit note to the row's `notes`.
- **After any `index.html` edit:** confirm the big script block parses
  (`new Function`) and that `<div>` open/close counts balance outside
  script/style. Ship only if both pass.

### Process

- Designated branch is per piece of work and is given at the start of each
  session; it is **not** a fixed property of the repo. The one this file was
  written under was `claude/merge-field-app-repo-2hd0dr`, long since merged.
  Take the current branch from the session's instructions, not from here.
- The office repo has explicit permission for `main` (John gave it twice). The
  field app repo does **not** — its retirement stub was staged on a branch by
  design and merged only once the new URL was confirmed on a phone.
- `git push -u origin <branch>`, retrying up to 4× with exponential backoff.
- No PRs unless asked.

### Tone (owner preference)

Terse and decisive. Offer A/B/C with a recommendation ("my vote"). Ask before
building anything significant; push back on scope creep. For data issues:
investigate and show findings first, propose the fix, wait for approval. Never
delete data unprompted.

---

## Next immediate steps

1. ~~John verifies the new URL on a phone~~ — ✅ done, works.
2. ~~Merge the retirement to the field app repo's `main`~~ — ✅ done, `1dc84cb`.
3. ~~Part B — field app writes to Supabase~~ — ✅ **done and live 2026-08-25.**
   See the section below; it is now a record of what was built, not a plan.
4. **Disable Pages on the old repo and archive it — on or after 2026-09-14.**
   *Outstanding.* Archiving early strands anyone who hasn't opened the app
   online since the switch: an installed copy needs **one online load** to run
   the self-destructing worker. Until then it keeps working from its own cache.
   Three weeks from the 2026-08-24 switch was the agreed wait, hence the date.

   Steps are John's, in the GitHub UI: old repo → Settings → Pages (disable),
   then Settings → Archive. Worth nudging anyone still on the old copy to open
   it once on signal first.
5. **First real death and first real move through Approvals.** Both paths are
   built, RPC-backed and rollback-tested, but neither has been exercised on
   production data. John will run one of each as they occur and flag it for
   verification. Check `event_datetime`, the `approved_ref`, and **drift on the
   affected lot** after.

6. **Two dashboard settings and a mail provider** — `docs/OPEN-ITEMS.md` items
   1, 2 and 7, all John's to do and all still open: leaked-password protection,
   confirming public signup is off, and a Resend account with a verified
   sending domain. The Resend account unblocks both password resets and the
   automatic daily report, so it is worth doing once for both.

**Where the roadmap stands (2026-08-26):** item 4, the cost ledger, is **in
progress** — its first phase, the Closeout rebuild, shipped 2026-08-25 and is
verified against production. The ledger categories themselves need a Redwing
export from John before they can start. Item 5, the daily buy/sell dashboard,
is untouched and depends on item 4 for trustworthy cost inputs. Full detail in
`docs/roadmap.md`.

---

## Part B — field app → Supabase (BUILT, live 2026-08-25)

**This section was the design; it is now the record of what shipped.** Where the
build diverged from the plan, the divergence is called out inline — those
divergences are the load-bearing part. The operational rules live in `CLAUDE.md`
under "Field → books approval path"; that file takes precedence.

### Shape

The field app stopped writing to Apps Script and writes to a **staging table**,
never straight into the books. The office reviews and approves; approval runs an
RPC that writes the real rows.

```
field PWA → pending_field_entries (staging) → office review screen → RPC → books
         ↑ localStorage queue keeps this offline-first
```

Keep the existing offline queue (`SYNC_QUEUE_KEY`, `TOMBSTONES_KEY`,
`processSyncQueue` around `field-app/app.js:197-215`) exactly as-is. Only the
transport changes: swap `sendOne()`'s `fetch(CLOUD_URL, {mode:'no-cors'})` for a
supabase-js insert.

### New table: `pending_field_entries`

*Applied 2026-08-24 via `docs/sql/2026-08-24_pending_field_entries.sql`. As
built:*

- `id uuid pk`, `entry_type text` (`'doctoring'` | `'move'`)
- `raw jsonb` — the field payload verbatim, never edited
- `client_id text` — the app's own id (`String(Date.now())`, or `"M-"+…` for
  moves), unique together with `entry_type`
- resolved FKs, nullable until review: `lot_id`, `pasture_id`, `to_pasture_id`,
  `field_action_id`, `tag_number`, `no_tag`, `head_count`, `resolved_meds`
- `status text`, `review_notes text`, `approved_ref jsonb` (`{kind, id}` —
  what the approval actually wrote)
- `submitted_by uuid` → `user_profiles`, `reviewed_by`, `reviewed_at`, timestamps

**Three divergences from the design above, all deliberate:**

1. **`(entry_type, client_id)` is an UPSERT key, not a reject-duplicates
   constraint.** The design got this backwards. The field app re-sends an
   *edited* record under the same client id, so the second send must overwrite
   the first — rejecting it would strand the correction on the phone.
2. **`status` has a fourth value, `'withdrawn'`** — the field app can delete a
   record. Transitions are enforced in the DB by `pfe_guard_settled()`:
   `pending → approved | rejected | withdrawn`; `withdrawn → pending` and
   `rejected → pending` (office reinstates/reopens); **`approved` is terminal.**
3. **There is no `'dead'` entry_type.** A death arrives as
   `entry_type='doctoring'` and is identified by `field_actions.is_dead` on its
   resolved action. Anything classifying entries must check `is_dead`, not the
   entry type — this is landmine 1 below, and it is easy to miss.

Grants are pinned to `{authenticated, service_role}`, revoked from `PUBLIC` and
`anon`.

On approve, write `legacy_source='field_app'` and `legacy_id=client_id` into
`doctoring_events`, and stamp `approved_ref` on the staged row.

### Mapping free text → UUIDs

| Field payload | Target | Notes |
|---|---|---|
| `treatmentType` | `doctoring_events.field_action_id` (**NOT NULL**) | Match on `field_actions.name` — already aligned. |
| `location` (`"Ranch - Pasture"`) | `pasture_id` | Split on `" - "`, resolve ranch then pasture. Ambiguity → null, force review. |
| `lotNumber` | `lot_id` | Scope to **OPEN** lots (tags recycle across fiscal years). |
| `medication1..3` | `doctoring_event_meds.medication_id` | Fall back to `medication_name_freetext` when unmatched. |
| `dosage1..3` (text) | `dose_cc` (numeric) | Parse; non-numeric → null + flag. |
| `tagNumber` / No Tag | `tag_number` (text), `no_tag` (bool NOT NULL) | Direct. |

**Never auto-create** ranches, pastures, lots, or medications from field text. An
unresolved name is a review item, not a new row.

### Three landmines

1. **`Dead` is not a doctoring event.** Approval must branch on
   `field_actions.is_dead` and call `record_death_with_pasture`. A plain insert
   creates drift.
2. **Field moves have no lot.** The reviewer must pick; pre-select when the
   from-pasture holds exactly one open lot.
3. **Med cost freezes at approval.** `doctoring_event_meds.cost` is frozen per
   row at save time — price at *approval*, not at field capture. The cowboy's
   phone has no pricing.

### Auth prerequisite (roadmap #2)

Cowboy login, plus RLS so a cowboy can INSERT into `pending_field_entries` and
read lookup tables only — never write to `doctoring_events`, `lots`, `sales`, or
receipts. The staging table is the field app's only write surface.

**Status 2026-08-25: done.** Both halves are in place — `crew` is read-only
across the books, and `pending_field_entries` is the one table they may INSERT
into. Note that in practice both current users (John, Lauren) are `owner`; the
`crew` path is built and policied but no `crew` user works the field app today.

### Office review screen — as built

The **Approvals** tab in the office `index.html`. John's spec (2026-08-25):
*"concise and organized by lot, pasture, then tag number… each entry selectable
to transfer… leaving behind ones that need to be followed up on… a note by each
one left behind"*, plus *"group approvals by day"* and *"one line is enough"*.

**It shipped as one line per entry, not the card layout designed above.** Rows
group by **work day** (newest day first), then sort by lot → pasture → tag.
Doctoring, Move and Dead each have their own section. Checkbox per row.

- **Per-row note** — the "left behind" note John asked for; writes
  `review_notes` without changing status, so an entry can be parked with a
  reason and picked up later.
- **Per-row date** — added after John entered a doctoring on the wrong day and
  found he could not fix it from either app. Shifts `event_datetime` by whole
  days and rewrites only the date half of `raw.dateTime`, preserving time of
  day, guarded `.eq('status','pending')` so a posted entry can never be
  rewritten. Appends an audit note.
- **Batch approve is all-or-nothing** (John's call: *"b. all or nothing for
  now"*). If any row fails, `rollbackPosted()` unwinds what was already
  written.
- **Order within a batch matters:** doctoring first, then deaths and moves
  sorted by `event_datetime`. Head-math entries must replay in the order they
  happened or a move can outrun the death that freed the head.
- **Deaths approve without a cause** (John's call, option B) — cause is filled
  in later on the lot. Carcass disposal is flagged when the animal was **NOT**
  hauled off. `drug_off` means "removed to the proper location for dead
  animals" — nothing to do with drug withdrawal.
- **Unpriced meds are flagged permanently** (John's call: *"a and c"*) — cost
  freezes at approval, so a med must be priced before anything using it is
  approved.

Reject sets `status='rejected'` + `review_notes` and surfaces back in the
cowboy's app. Rejected entries are never deleted, and can be reopened to
`pending`.

### Verification — what actually happened

Done in production 2026-08-25. **Eleven real doctoring entries**, lot 36-27,
First Pull EX, over three work days:

- All eleven posted with `legacy_source='field_app'`, a real `approved_ref`,
  two med rows each, cost frozen at ~$16.17/head, **zero unpriced lines**.
- **Drift = 0 on every open lot** after (36-27, 37X, 37X-1, 37X-F, 47-26, 59X,
  60X) — checked as `head_current` vs the sum of open
  `lot_pasture_assignments`.
- The date correction was exercised for real: tag 8288 moved Aug 25 → Aug 24,
  time of day preserved, audit note on the staged row.

**Still unexercised on production data — still true as of 2026-08-26:** a real
**Dead** and a real **Move**. Both are built, RPC-backed, and their reversals
were tested against a local Postgres replica — that testing is what caught the
`delete_death_event` double-count. John will run one of each as they occur.

Also worth noting about the offline-queue test in the original plan: the
`(entry_type, client_id)` pair is an **upsert**, so submitting the same entry
twice correctly results in **one row that reflects the second submission** —
not a rejected duplicate. Testing for a rejection would be testing for the
wrong behaviour.
