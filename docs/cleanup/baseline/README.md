# P0 baseline (2026-10-09, commit 86f456f)

Golden outputs for the cleanup project (`docs/cleanup/PLAYBOOK.md`). After
every cleanup commit, rerun the same commands and diff against these files.
No code was changed to make them, and nothing touched the live database.

## Results

| File | Command | Result |
|---|---|---|
| `validate-index.txt` | `node scripts/validate.js index.html` | PASS (1415/1415 divs) |
| `office-tap-A.txt` | `node scripts/office-tap-harness/walk.js` | ran; output is a log, no PASS/FAIL. Rerun is byte-identical |
| `office-tap-B.txt` | `BATCH=B node scripts/office-tap-harness/walk.js` | same; byte-identical on rerun |
| `office-tap-C.txt` | `BATCH=C node scripts/office-tap-harness/walk.js` | same; byte-identical on rerun |
| `date-sync.txt` | `FLATPICKR_JS=… node scripts/date-sync-harness/run.js` | ALL PASS (9) |
| `field-deadletter.txt` | `node scripts/field-deadletter-harness/run.js` | ALL PASS (21) |
| `load-out-ticket.txt` | `node scripts/load-out-ticket-harness/run.js` | ALL PASS (26) |
| `med-intake.txt` | `FLATPICKR_JS=… node scripts/med-intake-harness/run.js` | ALL PASS (35) |
| `med-charge.txt` | `sh scripts/med-charge-harness/build-base.sh` then `node scripts/med-charge-harness/run-local.js` | ALL PASS (43), on a local PostgreSQL 16 scratch database |
| `pasture-check.txt` | `node scripts/pasture-check-harness/run.js` | ALL PASS (17) |
| `field-pasture-recall.txt` | `node scripts/field-pasture-recall-harness/run.js` | **FAILS**: 3 PASS, then a click times out because `#loginScreen` covers the page. Same result on a second run |
| `withdrawal.txt` | `node scripts/withdrawal-harness/run.js` | **CANNOT RUN**: it reads `scripts/pb-feed-harness/fake.js`, which is not in the repo and never was in git history (only `fake-local.js` exists) |
| (not run) | `scripts/pb-feed-harness/run-local.js` | needs the scratch server on `/tmp:5499` holding a snapshot of the live ranch (`feed_base`, `cc_ui_base`). Not available in a fresh session |

All browser harnesses need `NODE_PATH=$(npm root -g)` for Playwright.
`FLATPICKR_JS` points at `dist/flatpickr.min.js` from `npm pack flatpickr@4.6.13`.

## Pre-existing problems found

These were broken before the cleanup started. Fixing them is its own small
PR, ahead of any slice that depends on them.

1. **`field-pasture-recall-harness` fails at its fourth check.** It was added
   in the most recent commit (Field app v26). After the first three checks
   the field app's login screen is up and blocks the click on
   "Shop - Shop House". Either the harness's signed-in stand-in lapses or v26
   signs the user out in that path. Needs a look before the field app is
   cleaned (Phase 4).
2. **`withdrawal-harness` points at a missing file.** Withdrawal is a red
   area, so this harness has to run before any withdrawal code is touched.
   Likely fix: point it at a fake client that exists, or commit the one it
   was written against.
3. **`pb-feed-harness` can't be rebuilt from the repo alone.** Feed and COG
   slices (red) have no runnable net until it can, or until P5 adds
   office-tap cases for them.

## Function inventory

`functions.md` lists every `function` declaration (office app 819, field
app 110) with every line that names it. `inventory.js` regenerates it:
`node docs/cleanup/baseline/inventory.js . <commit> > docs/cleanup/baseline/functions.md`.

What it flagged:

- **One name declared twice:** `filterPastures` at `index.html:25113` and
  `:25268`. Both are local helpers nested inside two different pasture-picker
  functions, so this is not a collision.
- **Two functions nothing names:** `openEditAssignmentModal`
  (`index.html:25776`) and `deleteAssignmentRow` (`:25816`). For P7.
  `deleteAssignmentRow` deletes a row from `lot_pasture_assignments`
  directly. If anything can still reach it, that raw delete goes around the
  atomic RPCs that CLAUDE.md requires for head math.
