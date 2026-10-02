# Handoff: Bar J vet-med invoices → Approvals > Meds

Prompt for Claude Code. Written 2026-10-02 from a Cowork session that could not get
write approval through to John. Everything below is either John's own decision or
read off the live database / repo — no inference.

---

Finish the Bar J invoice intake. Branch `draft/med-invoice-intake` holds the migration
`docs/sql/2026-10-02n_med_invoice_intake.sql` and this file. Work on that branch, then
merge to main to deploy.

## John's decisions (2026-10-02)
- Medicines: the only vendor is **Bar J Vet Supply**, for now.
- Invoices go into **Approvals first** — nothing posts to inventory without his review.
- **Location is a must-answer box** in the approval. No default. (Invoice #6654 went to Ranch.)
- **New meds: ask**, but be ready to build the item (open the medication form pre-filled).
- Staging runs from the **4am triage** for now. (Cowork updates that scheduled task — not you.)
- He approved the migration ("Test" 14:06, "Apply" 14:08 CT). The test passed in a
  forced-rollback run against the real #6654 email; the apply never reached the DB.

## Step 1 — apply the migration
1. `git fetch && git checkout draft/med-invoice-intake`
2. Apply `docs/sql/2026-10-02n_med_invoice_intake.sql` (strip begin/commit for apply_migration).
3. Prove transcription: `md5(prosrc)` of `med_parse_barj_invoice`, `stage_med_invoice`,
   `reject_med_invoice`, `med_alias_learn` against the file.
4. Run `supabase/migrations/20260821000300_rls_verify.sql`. anon must have nothing on the
   two new tables or four functions.
5. Update the file header from "NOT APPLIED" to "Applied <date> on John's approval".

What it creates:
- `med_invoice_intake` — staged invoices. `lines` jsonb `[{name, qty, unit_price, line_total, bottle_size, unit}]`,
  `problems text[]`, `status` pending|rejected. Unique (vendor, invoice_number).
- `med_purchases.intake_id` — FK to the intake, partial **unique** index. Posted = a purchase
  carries the intake id. Deleting the purchase returns the invoice to the queue.
- `med_name_aliases` — (vendor, alias) → medication_id + bottle_size. Written only from John's own picks.
- `stage_med_invoice(message_id, text)` — parses verbatim email text, idempotent per invoice.
- `reject_med_invoice(intake_id, reason)` — refuses if posted; reason required.
- `med_alias_learn(vendor, alias, medication_id, bottle_size)` — upsert.
- RLS: select `can_read_books()`, insert/update owner+office, delete owner. Same as PB tables.

## Step 2 — stage today's invoice
Gmail message `1a0fd5610b3129d5` (Lauren's forward of Bar J #6654, 10/2, $237.69:
Macrosyn 250 ml - Prestige 1 @ $211.88; Vitamin K1 Injection 100ml VetOne 1 @ $25.81).
If you can read Gmail, call `stage_med_invoice('1a0fd5610b3129d5', <plain-text body verbatim>)`.
If not, leave it — the 4am run will stage it.

## Step 3 — Approvals > Meds tab (index.html)
Model it on the Feed tab and **reuse the existing purchase grid** — do not build a second one.

Existing pieces (line numbers as of a2d0af5):
- Approvals markup ~1854–1895: `#apprPaneTabs` sub-tabs, `#apprFieldPane`, `#apprFeedPane`.
  Add `<button class="sub-tab" data-appr-pane="meds" data-perm="office">Meds <span id="apprMedsCount" class="approvals-badge hidden">0</span></button>`
  and `<div id="apprMedsPane" class="hidden" data-perm="office">`.
- `showApprovalsPane` ~11893, `apprPane` localStorage ~11860, `pbLoadRole` / `apprCanFeed` ~11876:
  add the meds pane (same role gate as feed).
- Badge: `updateApprovalsBadge` / `apprRefreshCounts` ~10607–10632. Add `apprMedsN` = pending
  intakes with no purchase (`select('id, med_purchases(id)')`, `status='pending'`, filter client-side).
- Refresh button handler ~15088: route `meds` to the new loader.
- Purchase grid: `openInvPurchaseEntry` ~36098, `parseInvPasteBlock`, `invMatchMedByName`,
  `renderInvPurchaseLines`, `recomputeInvPurchase` (tie-out), `saveInvPurchase` ~36236,
  `invFillLocationSelect` ~35927 (currently defaults to Ranch), Back/Cancel ~37546.
- Medication form: `openMedModal(med)` ~21367, save handler `$('medForm')` submit ~21477.

Build:
1. **Queue list.** One card per pending intake: vendor, invoice #, date, total, lines
   (name, qty, $/bottle, line total), `problems` in red. Buttons: **Review & post**, **Reject**
   (prompt for reason → `reject_med_invoice`). Show recent posted/rejected below, collapsed.
2. **Review & post** opens the existing purchase screen pre-filled from the intake: date,
   vendor, invoice #, invoice total, lines (`pasted_name` = invoice name, `qty_bottles` = qty,
   `unit_price` = line_total ÷ qty, `bottle_size` = alias bottle_size, else the size read off
   the invoice, else blank). Hold the intake in a variable, e.g. `invPurIntake = {id, vendor}`.
3. **Location must-answer.** In intake mode, `#invPurLocation` gets a blank first option
   ("— choose where it went —") and no default. `saveInvPurchase` refuses until chosen.
4. **Matching.** Alias first (vendor + name, case-insensitive), then exact medication name.
   Never near-match (existing rule, `docs/medicine-inventory-fifo-plan.md`). Unmatched lines
   keep the picker and get a **New medication** button → `openMedModal` pre-filled with
   name, bottle size, unit mL, bottle cost = unit price. `openMedModal` currently treats any
   object as "Edit" — key the title off `med?.id`. Add an after-save hook so the new med
   lands in `invMedsCache` and on that line.
5. **Post.** `saveInvPurchase` sets `intake_id` on the `med_purchases` insert. After lines
   insert, for every line whose medication was picked by hand (not already an alias),
   call `med_alias_learn(vendor, pasted_name, medication_id, bottle_size)`. Clear intake
   mode, return to Approvals > Meds, refresh badge. The unique index on `intake_id` is the
   double-post guard — surface its error plainly if hit.
6. Keep everything else about the grid as is: the tie-out must still pass before posting;
   `settleInvUncovered` still runs after.

Known on #6654: catalog "Macrosyn(Draxxin)" is set up as a 500 mL bottle; this invoice is a
250 ml bottle. The purchase line carries 250. Do not change the catalog.

## Step 4 — check, then deploy
- `node scripts/validate.js index.html` must pass. No duplicate top-level function names.
- Test as owner in the browser, up to but NOT including Post: #6654 appears in Meds; Post
  refuses with no location; Macrosyn and Vitamin K1 show as needing a pick (no exact name
  match today); New medication opens pre-filled; tie shows $237.69. Then Cancel. John posts it.
- Do not test Reject on #6654. Ask John before staging any throwaway row to test it.
- Update `docs/medicine-inventory-fifo-plan.md` (intake section) and `CLAUDE.md` index row.
- Merge to main, push, hard refresh, confirm live.
- Tell John what's live and anything that didn't work.

## Do not
- Do not post #6654 to inventory yourself — John approves it.
- Do not add Double T, Agri Tech or any other vendor.
- Do not edit the 4am triage scheduled task.
