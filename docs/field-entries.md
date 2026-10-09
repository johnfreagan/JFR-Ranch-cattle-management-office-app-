# Field entries: the field app, the approval path, counts and weights

_Moved word for word from `CLAUDE.md` on 2026-09-27, when CLAUDE.md became a short index. Nothing here was rewritten; section dates are the dates the rules were written._

The phone queue and its Failed list live in `field-app/app.js`. Crew instructions: `docs/FIELD-APP-GUIDE.md`.

### Offline/PWA consequences (the live field app depends on all three)

- An RLS denial on SELECT returns **zero rows, not an error**. "No lots" is
  ambiguous between not-authorized, offline, and genuinely empty. Call
  `current_user_role()` on load and distinguish all three, or every access
  problem looks like a sync bug.
- A write queued offline replays under **later** authorization. Queued Tuesday,
  synced Thursday, user deactivated Wednesday → `42501`. Needs a dead-letter
  path. Never a silent drop (this is animal health data), never infinite retry.
- Purge local stores on sign-out and on user change; IndexedDB knows nothing
  about RLS. Persist the write queue outside the auth session, keyed by user
  id — days offline can outlive the refresh token.
- **The dead-letter path is built (field app v23, 2026-09-27).** The phone
  queue lives in `field-app/app.js` (`syncQueue`, `enqueueForSync`,
  `sendOne`, `processSyncQueue`; localStorage `betaCattleSyncQueue`). A
  PERMANENT refusal — `42501`, any `23xxx`, any `22xxx`, or our `P0001`
  guards — leaves the queue for the **Failed list** (`betaCattleFailed`):
  the whole payload, the error, the user it was queued under, when. Red
  "N failed" badge → list with the error in plain words, Retry, Copy, Mark
  handled. **Nothing deletes a failed entry**: Retry moves it back to the
  queue (a second refusal returns it), Mark handled keeps it stored off the
  badge, and `betaCattleFailed` is on NEITHER reset list. Network errors
  still retry every minute; the old 25-try backstop now lands in Failed
  instead of vanishing (it used to keep a one-line summary only). A
  deactivated user who reopens the app is signed out at bootstrap, so the
  list is visible again once the office reactivates them. Harness:
  `scripts/field-deadletter-harness/run.js`.

## Field → books approval path (live 2026-08-25)

Nothing a cowboy records reaches the books directly. The field app's only write
surface is `pending_field_entries`; the office **Approvals** tab posts from
there. Read this before touching either side.

```
field PWA → pending_field_entries → office Approvals tab → RPC → books
         ↑ localStorage queue keeps this offline-first
```

- **`(entry_type, client_id)` is an UPSERT key, not a duplicate check.** The
  field app re-sends an edited record under the same client id, and the second
  send must overwrite the first. Do not add a reject-duplicates constraint.
- **Statuses:** `pending → approved | rejected | withdrawn`; `withdrawn → pending`
  (office reinstates); `rejected → pending` (office reopens); **`approved` is
  terminal.** `pfe_guard_settled()` enforces this in the DB — the app is not the
  only guard. `withdrawn` exists because the field app can delete a record.
- **Approval is all-or-nothing per batch** (John's call, 2026-08-25). If any row
  in a selection fails, `rollbackPosted()` unwinds the ones already written.
  Deaths and moves post through their atomic RPCs so head math stays intact.
- **Order matters within a batch.** Doctoring first, then deaths and moves
  sorted by `event_datetime` — head-math entries must replay in the order they
  happened or a move can outrun the death that freed the head.
- **Cost freezes at approval, not at field entry.** Price a medication BEFORE
  approving anything that uses it; an unpriced med writes a NULL cost line that
  `SUM()` then ignores. The approvals screen flags unpriced meds — do not
  approve past that flag.
- **`resolved_meds` is NEVER null: it is `NOT NULL DEFAULT '[]'`.** An
  untouched entry carries an EMPTY array, so "is it an array" is always true.
  Commit e0530ba (2026-08-31) tested exactly that, and every doctoring entry
  approved without an office edit posted with NO meds: 167 events,
  2026-09-01 to 2026-09-26, found because the office app showed doctorings
  with no meds attached. The edit form pre-fills from the same list, so
  edited entries lost them too. Now a med list overrides the cowboy's only
  when it is non-empty or the row was office-edited (every edit writes
  `lot_id`). Repaired 2026-09-26 from `raw`:
  `docs/sql/2026-09-26_backfill_field_app_meds.sql`, 305 lines, $2,974.03.
  **A field entry with a med name and a blank dose would have been blocked
  before the bug and must be blocked again** — 13 such entries slipped
  through only because the med list was empty. Check the approvals screen
  shows "dose ... is not a number" for one.
- **Correcting a date** is done on the approvals row, which shifts
  `event_datetime` by whole days and rewrites only the date half of
  `raw.dateTime`, preserving time of day. It is guarded `.eq('status','pending')`
  so an already-posted entry can never be rewritten.
- Deaths approve **without a cause** — cause is filled in later on the lot.
  Carcass disposal is flagged when the animal was **NOT** hauled off.
  (`drug_off` means removed to the proper location for dead animals; it has
  nothing to do with drug withdrawal.)

## Pasture counts and test weights (live 2026-09-07)

Recorded on the field app's Pasture tab, reviewed on the office Approvals
tab. Migrations: `docs/sql/2026-09-07_field_counts_and_test_weights.sql` and
`..._07b_pfe_resolved_detail.sql`. **Neither kind posts head.**

- **`pending_field_entries.entry_type` now has four values** —
  `doctoring | move | count | weight`. Adding a fifth means touching THREE
  places in the office or it resolves correctly and then vanishes: the
  `['doctoring','move','dead','count','weight']` loop in `renderApprovals`,
  `entryDayKey()` (which otherwise files it under Undated), and the
  `ordered` list in `approveSelected`. All three were missed on the first
  cut and only surfaced under test.
- **A count that does not tie is BLOCKED, never absorbed.** A gap between
  the count and the books is a death, sale or move nobody recorded — a
  different problem — and approving it would bury the thing worth finding.
  A count that ties writes the same `[counted YYYY-MM-DD]` marker the Settle
  screen writes, which is what silences the Anomalies check.
- **Neither kind asks the cowboy which lot.** On a mixed pasture nobody at
  the scale can say, which is the whole premise of the pro-rata split.
  `weights.lot_id` is NOT NULL, so the OFFICE assigns it at approval — one
  lot in the pasture is inferred with a warning, more than one blocks and
  names them.
- **Shrink is indicative in the field, true at approval.** John's factors
  (2026-09-07): **3% weighed on the ground, 2% hauled and weighed** — hauled
  cattle have already shrunk on the trailer. The field app shows the shrunk
  figure so the number in the cowboy's hand is realistic; the office sets
  what is stored, and a shrink still on the method default warns that nobody
  has confirmed it.
- **`weights` stores gross AND booked separately.** `gross_weight_lb` is off
  the scale, `total_weight_lb` is booked after shrink. A later true-up has to
  calibrate on GROSS or each estimate's error compounds into the next — the
  same rule the silage allowance follows. `weights_booked_le_gross_check`
  and `weights_gross_present_check` refuse the two ways to get this wrong.
- **One `weights` row per scale draft**, sharing a `weigh_session_id`, so the
  average can be rebuilt with each drag still visible underneath it.
- **`applies_to`** ('pasture' | 'lot') is John's call that the office decides
  whether a sample stands for the pasture it came off or the whole lot, and
  is asked about mixed lots at that point.
- **`pending_field_entries.resolved_detail` (jsonb) holds review decisions
  with no column of their own** — a weight's `shrink_pct` and `applies_to`.
  They belong to `weights`, not to the staging table, but have to persist
  between the edit and the approval. Do NOT overload `resolved_meds`; it is
  med-specific.
- **`weights` now feeds the projection — but only a WHOLE-LOT row does**
  (2026-09-10, the CFO project; migration
  `docs/sql/2026-09-10_lot_weight_anchor.sql`). This reverses the
  2026-09-07 "option A, capture and display only" decision, and answers
  rather than discards its reason. That reason was sound: a pasture weight
  is full of grass and water while a pay weight is shrunk, and the first 20
  head into the trap are the gentle ones, not a random sample. So `weights`
  gained a third field, `coverage` ('whole_lot' | 'sample'), and ONLY
  `coverage='whole_lot'` **and** `applies_to='lot'` anchors anything.
  Everything the field app writes is `weight_type='pasture_check'` at the
  default `coverage='sample'` and still anchors nothing — **anchoring is
  opt-in, and only the office can opt in.** Realized ADG and the `per_lb`
  COG mode still do not read `weights`; that half of option A stands.
- **The office sets `coverage` on the Approvals correction screen**
  (2026-09-10). It rides in `resolved_detail` beside `shrink_pct` and
  `applies_to` — same reason: it belongs to `weights`, not to the staging
  table, but has to survive between the edit and the approval. The control
  is a plain two-option select, and **a live hint says which way the choice
  falls**, because coverage and "stands for" are two different questions and
  only their COMBINATION anchors: a whole-lot weighing marked *just this
  pasture* looks like it should anchor and does not. A row that WILL anchor
  also raises a review warning saying the lot's projected weight is about to
  be re-based, so nobody does it by accident on the way past.
- **The three fields on `weights` are three different questions.**
  `weight_type` is the occasion (arrival · chute · pasture_check · sale ·
  individual · other), `applies_to` is what the sample stands for (pasture
  or lot, decided by the office at approval), and `coverage` is whether
  every head was on the scale. The third had to exist because the office is
  explicitly allowed to say a 20-head draft stands for the lot average —
  `applies_to='lot'` — and that is NOT the statement "we ran all 585 head
  across the scale". Only the second may anchor a lot average, so
  overloading `applies_to` would have made a gentle-cattle draft the
  lot's weight.

- **A pasture weighing now sets that pasture's weight, and the weight goes
  with the cattle** (2026-10-01, migration
  `docs/sql/2026-10-01_pasture_weight_estimates.sql`, design in
  `docs/weight-estimation-design.md`). It counts once it covers **25% of the
  head on the books in that pasture** (John: "25 for now"); below that it is
  kept and shown, marked *note only*. The field app's weigh form says how
  many head that is and how many more are needed (v24), and Approvals warns
  when a weighing is under it. **Display only** — see the design doc for
  what does not read it.

### Pasture inventory in the field app (v19)

A fourth tab: pick a ranch, then a pasture, and it shows the lots standing
there with head and a pasture total. Reads `pastureLotsMap`, the same cache
the move form's split uses, so it works with no signal.

- **The pickers offer only pastures that HOLD cattle** (v21). Built from
  `pastureLotsMap`, not from the pasture list: on ~60 pastures most are empty
  most of the time, and offering them all buries the handful that matter. A
  device that has never synced says "No cattle on the books — sync first"
  rather than showing an empty dropdown. Consequence to know: a pasture the
  books show as empty cannot be selected, so cattle found somewhere the books
  do not know about cannot be counted there — that is a move to record first.
- **It is deliberately not a yard sheet.** Both selectors must be answered
  before anything appears; there is no all-pastures list, no ranch subtotal
  and no route to an operation-wide number. John's reason (2026-09-02): a
  phone gets left on a truck seat, and a whole-ranch total one tap from the
  home screen is not something to hand out.
- **The selection resets every time the tab is opened**, rather than being
  remembered. Leaving the last pasture on screen would defeat the same point.
- A pasture holding more than one lot says so, and says the split is the
  books' estimate — the same caveat the move form carries.
- **Layers of authorization (crew lead vs crew) are anticipated, not built.**
  John, 2026-09-02: "might have to eventually have layers... not at this
  point but might be a need." This screen is already the shape that would
  want: one pasture, nothing aggregate. A `crew_lead` role would be one line
  in `can_read_operational()` plus the `user_profiles.role` CHECK, the same
  path `accountant` took.

## Doctoring on a pasture the lot is not in (2026-10-09)

**What happened.** On 8 Oct ten 36-27 entries came in on Corner 2, 3, 4, 7
and 8 while the lot stood in Shop House, Goat Hill, Shelton and elsewhere
— three of those pastures were empty on the books. The field app fills the
pasture from the **last entry it saw for that tag** (`recalledLocation` in
`field-app/app.js`), and that beats what the books say. The lot had moved;
the tags had not (pasture is tracked per lot, not per animal), so the
recall was a pasture the calf had left. Approvals took it as written.

**Check (`resolveApprovalEntry`, doctoring and deaths).** If the lot has no
head in the resolved pasture, the entry names where the lot actually
stands and:

- **blocks** when the pasture is the cowboy's (a recall is not a decision);
- **warns only** when the office picked a *different* pasture with ✎ —
  cattle do get worked where they do not live, and that is the office's
  call. An ✎ save that leaves the cowboy's pasture in place still blocks:
  every ✎ save writes `pasture_id`, so "office edited" alone is not
  "office decided".

**Fix in the fewest taps.** Under a blocked row: one button
(`📍 Use Shop – Shop House`) when the lot stands in one pasture, a picker
(lot's pastures, most head first) when it stands in several. Above the
Needs-info list: **Fix all N** for the single-pasture rows, and a per-lot
picker when one lot has several stale rows — one pick fixes the batch.
`apprFixPastures()` writes the same resolved columns ✎ writes (lot,
pasture, action, **full med list**) — an office-edited row with an empty
`resolved_meds` posts with no meds (the 2026-09 bug) — and appends who
changed which pasture to `review_notes`. `raw` is untouched. A row whose
med lines do not all resolve gets no quick fix: it would drop a line, so
✎ is the way in. Harness: `scripts/pasture-check-harness/run.js`.

**Moves are not involved.** The books already have the lot where it is;
only the entry's pasture was stale. No move is recorded by the fix.

## Posted doctoring: owner edits, office voids and re-enters (2026-10-09)

John's call. In the doctoring modal a posted event is read-only for
anyone but the owner, with a note saying so; the office gets **Void &
re-enter** in place of Delete: the event comes off the books (meds back on
the shelf, as Delete always did) and the modal re-opens as a NEW entry
pre-filled with the same values to correct and save. Cancel there and it
stays voided. Migration `docs/sql/2026-10-09b_doctoring_edit_owner_only.sql`
makes UPDATE on `doctoring_events` / `doctoring_event_meds` owner-only and
adds `doctoring_event_audit` (trigger-written before-images of every edit,
void and removed med line; books readers only). Office can still delete
and insert med lines (void and posting need both); the app does not offer
that path and the audit logs it if it happens.
