# Handoff — field app merge & retirement

**Last updated:** 2026-08-24 (retirement merged)

Working note for picking up in-flight work, not app code. Read alongside
`CLAUDE.md`, which holds the standing business rules and schema landmines and
takes precedence over anything here.

---

## Core goal

Consolidate two cattle apps into one repo and one deploy, then retire the
duplicate. A secondary goal emerged during the work: establish whether the field
app is connected to the production books (**it is not**) and design that
connection for later.

| | Repo | Backend |
|---|---|---|
| Office app | `johnfreagan/JFR-Ranch-cattle-management-office-app-` | Supabase `xpfmebdzcxorvwikfvtj` — the real books |
| Field app (PWA for cowboys) | `johnfreagan/JFR-Ranch-Cattle-Field-App` | Google Apps Script → a Google Sheet |

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

- **The field app has zero Supabase references.** `CLOUD_URL` at
  `field-app/app.js:4` points at Google Apps Script. Nothing a cowboy records
  reaches the books; someone re-keys it by hand. This is expected per the
  roadmap — it is not a regression.
- **`localStorage` is shared between the old and new URLs.** Both are on origin
  `johnfreagan.github.io`, and storage is scoped per *origin*, not per path. The
  `betaCattle*` keys carry over with no migration, and both copies write to the
  same Sheet. This is why the stub must not clear storage.
- **Writes are fire-and-forget.** `sendOne()` uses `mode: 'no-cors'`
  (`field-app/app.js:203`), so the app cannot read the response and cannot tell a
  rejected write from a good one — only a hard network failure rejects. A 500
  from Apps Script currently looks like success. Pre-existing; fixed for free
  when the transport moves to supabase-js.
- **Reads are manual only** — the ⏳ Sync button injects a JSONP `<script>`
  (`field-app/app.js:978`). Nothing pulls automatically.
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

- Designated branch in both repos: `claude/merge-field-app-repo-2hd0dr`.
  The office repo has explicit permission for `main` (John gave it twice). The
  field app repo does **not** — its stub is staged on the branch by design.
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
3. **Disable Pages on the old repo and archive it — on or after 2026-09-14.**
   *Outstanding; this is the only open item.* Archiving early strands anyone who
   hasn't opened the app online since the switch: an installed copy needs **one
   online load** to run the self-destructing worker. Until then it keeps working
   from its own cache. Three weeks from the 2026-08-24 switch was the agreed
   wait, hence the date.

   Steps are John's, in the GitHub UI: old repo → Settings → Pages (disable),
   then Settings → Archive.
4. **Part B stays blocked** on roadmap item 2 (multi-user auth + RLS).
   `user_profiles` already exists with `role` and has a `crew` row, so that item
   is partly underway.

Worth a look before archiving: anyone still on the old copy has, by definition,
not loaded it online since the switch. If cowboys are already using it, give them
a nudge to open it once on signal.

**Do not** start Part B or import Sheet data.

---

## Part B design — field app → Supabase (build after roadmap #2)

Not started. Recorded here so the design survives; execute only once cowboys can
log in.

### Shape

The field app stops writing to Apps Script and writes to a **staging table**,
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

- `id uuid pk`, `entry_type text` (`'doctoring'` | `'move'`)
- `raw jsonb` — the field payload verbatim, never edited
- `client_id text` — the app's own id (`String(Date.now())`, or `"M-"+…` for
  moves). **Unique together with `entry_type`** — the idempotency key that makes
  offline-queue retries safe.
- resolved FKs, nullable until review: `lot_id`, `pasture_id`,
  `field_action_id`, `tag_number`
- `status text` (`'pending'` | `'approved'` | `'rejected'`), `review_notes text`
- `submitted_by uuid` → `user_profiles`, `reviewed_by uuid`, timestamps

On approve, write `legacy_source='field_app'` and `legacy_id=client_id` into
`doctoring_events`.

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

### Office review screen

Lives in the office `index.html`. Entry list newest-first, filter bar
(`All / Ready / Needs info / Deaths`), and a bulk **Approve all ready** covering
only fully-resolved non-death entries. Cards reuse `buildTileRows()` (label left,
value right), `showModal()`/`hideModal()` for pickers, `showAlert()` for results.

- **Ready** — everything resolved. Shows tag, datetime, lot, pasture, meds with
  doses, recorded-by, and med cost priced at review time. One-tap Approve.
- **Needs info** — unresolved fields render inline with ⚠ and a picker
  (`Pick lot ▾`, `Map medication ▾`, or `Keep as text` → writes
  `medication_name_freetext`, no cost, labelled as such). **Approve stays
  disabled** until nothing is unresolved.
- **Death** — flagged ☠, excluded from bulk approve, previews the head math
  before commit (`head_current 412 → 411`, matching pasture assignment, drift
  after = none).
- **Move** — from/to/head plus a lot picker. A partial move (120 of 412) splits
  the assignment rather than moving the whole thing.

Reject prompts for a reason, sets `status='rejected'` + `review_notes`, and
surfaces it back in the cowboy's app. Rejected entries are never deleted.

### Verification when built

With a cowboy-role login: submit an entry in airplane mode, go online, confirm
one `pending_field_entries` row. Submit the same entry twice — the
`(entry_type, client_id)` constraint must reject the duplicate. Approve; confirm
`doctoring_events` + `doctoring_event_meds` rows with frozen cost.

Then the tests that actually matter:

- Approve a **Dead** entry and confirm the Anomalies report shows **no drift**.
- Submit a garbage lot and an unknown med; confirm Approve stays disabled until
  both resolve, and `Keep as text` lands in `medication_name_freetext` with no
  cost.
- Submit a move; confirm the lot picker pre-selects and a partial move splits.
- Confirm a cowboy token is refused a direct write to `doctoring_events`.
