# Lot lifecycle workflow map: lot creation to lot close

As of 2026-10-09 (`ranch_today()`), against `main` at `86f456f`. Built from a
read-only pass over `index.html`, `docs/`, `docs/sql/` and a SELECT-only
snapshot of the production database. Nothing was changed.

Line numbers are `index.html` unless another file is named. They drift as the
file changes; search for the function name if a number is off.

Each stage has four parts:

- **Have**: what works today, with the screen, function and table or RPC.
- **Finish**: half-built work, or items already open in `OPEN-ITEMS.md` / `HANDOFF.md`.
- **Build**: things that do not exist yet.
- **Issues**: bugs, data-integrity risks and manual steps.

The punch list at the end ranks all of it.

---

## The lifecycle at a glance

```
 1 CREATE LOT        Lots > + New lot                lots (direct insert)
        |
 2 RECEIVE           Purchases > + Load Out          record_load_out RPC
   (load out =       Approvals > Load outs (photo)     delivery_receipts, load_out_destinations,
    ARRIVAL)                                           lot_pasture_assignments, lot_tags
        |            processing draw                 med_processing_draw (inventory only)
        |
 3 INVOICE + BUDGET  Purchases > + Invoice           invoices (direct insert)
                     Closeout > Save assumptions     lots + lot_assumption_history
                     Closeout > Freeze as budget     lot_budgets (frozen by trigger)
        |
 4 IN-LIFE           Field app -> Approvals          pending_field_entries -> post*Entry
                     Moves / Settle counts           record_move_with_pasture
                     Feed (PB email, hand feed)      approve_pb_report, post_feed_usage
                     Doctoring / meds                doctoring_events, med_consume
                     Deaths                          record_death_with_pasture
                     Strays / missing / transfers    record_missing_head, record_lot_transfer
                     Weights                         field approvals only
                     D8 tie-out                      lot_head_tieout view
        |
 5 MARKET + SELL     Sales > Positions               positions, market_quotes
                     Lot > + Sale -> Shipment        saveShipment (browser, many statements)
                     Sales > Accounting Report       Redwing 12-column export
        |
 6 CLOSE             kebab Close lot / prompts       lots.closed_at = browser clock
                     Closeout tab                    live recompute, nothing frozen
```

---

## Live snapshot (production, 2026-10-09)

There are 8 open lots and 2 closed lots. All 8 open lots tie on D8 (books head = pasture head).

| Lot | State | In | Dead | Sold | Current | Arrived | Note |
|---|---|---|---|---|---|---|---|
| 37X | open | 369 | 18 | 320 | 32 | 2025-12-03 | Tail. 361 head invoiced, receipts for only 8; 72 tags vs 369 |
| 37X-1 | open | 274 | 10 | 255 | 9 | 2026-01-06 | Tail. A 06-04 sale of 2 head has no weight, price or buyer |
| 37X-F | open | 316 | 1 | 307 | 8 | 2026-02-12 | Tail. 317 tags vs 316 head |
| 59X | open | 241 | 4 | 234 | 3 | 2026-05-07 | Tail |
| 60X | open | 251 | 3 | 246 | 2 | 2026-05-20 | Tail. No cost assumptions |
| FEEDPEN-27 | open | 0 | 0 | 0 | 3 | 2026-07-01 | +3 adjustment 09-07 |
| 36-27 | open | 712 | 13 | 0 | 699 | 2026-08-11 | 132 tags on withdrawal to 11-13 |
| 32-27 | open | 206 | 1 | 0 | 205 | 2026-09-30 | 97 head waiting on an invoice |
| 31-26 | closed 08-13 | 1766 | 116 | 1650 | 0 | | Feed cost shows $0 |
| 47-26 | closed 09-03 | 187 | 8 | 178 | 0 | | 1 transferred out to 37X |

Data findings from the snapshot. Each one needs John's approval before anything is corrected.

1. **Sold tags are not retired.** Active tags against head left: 37X-F 317 vs 8, 37X-1 265 vs 9,
   60X 248 vs 2, 59X 237 vs 3, 37X 67 vs 32. The cause is in Stage 5.
2. **Death tags are not all retired.** 37X: 18 dead, 5 retired (3 untagged rows, multi-head rows).
   37X-F: 1 untagged death. Tags 4331 and 4379 on 37X have no `lot_tags` row.
3. **Protivity has no price.** It is in 2 protocols and was dosed to 37X, 37X-1, 37X-F and 47-26.
   Processing cost on those four lots is understated because `SUM()` skips the NULL.
4. **Dexamethasone has no price.** One doctoring line on 59X (2026-05-23) has NULL cost.
5. **COG per head-day is wrong for lots that arrived before 2026-08-31.** Feed cost history starts
   on 08-31, but head-days run from arrival. This covers the X lots and 31-26 ($0 feed for its whole life).
6. **Medicine shows more used than ever received.** Draxxin at the Ranch: 48 units used with 0 on hand.
   Jake Taylor: Ferappease 550, Valcor 251.67, Synovex C 65 units.
7. **3 medicine invoices have waited in Approvals > Meds since 2026-10-02.**
8. **The field-entry queue is clean.** Nothing is pending or failed.

---

## Stage 1: Create the lot

**Have**
- Lots > **+ New lot** opens `openLotModal` (:9973). The `lotForm` submit handler (:10063) does a direct `insert`/`update` on `lots`.
- Fields saved: lot number, arrival date (defaults to `ranchToday()`) and source (free text; it also picks the buyer's medicine shelf).
- Also saved: sex class, target ADG, notes, estimated purchase weight and its source, `is_feed_pen`, `no_precon` and `cog_mode='per_lb'`.
- Estimated weight is required (`syncLotEstWeightRequired` :10010). This rule exists because 32-26 was charged $0 for its per-cwt meds.
- The `derive_fiscal_year` trigger sets the fiscal year. Only one feed pen is allowed per fiscal year.
- Duplicate copies the source lot's targets and assumptions.

**Finish**
- New lots start with no cost assumptions unless they are duplicated. 47-26 and 60X have none (OPEN-ITEMS §8).

**Build**
- A "lot ready" checklist on the lot. There is no status column, so nothing shows that a lot has:
  - an invoice;
  - a protocol on every load out;
  - assumptions;
  - a frozen budget.
- Structured purchase fields: seller (today the free-text `source`), origin, freight, commission, pay weight vs shrunk weight, and $/cwt. `total_cost_in` is the invoice total and nothing more.

**Issues**
- Editing a lot overwrites `created_by` with the editor (:10095, :10132).
- Changing a lot's arrival date can move it to another fiscal year after its tags are registered. `lot_tags.fiscal_year` then no longer matches, and nothing checks for it.

---

## Stage 2: Receive the cattle (load out)

In this app a "load out" is the **arrival** receipt, not a shipment out.

**Have**
- Purchases > **+ Load Out** opens `openReceiptModal` (:27528). The browser checks that:
  - the tag count equals head;
  - the destination split adds up to head;
  - the load out is not a duplicate;
  - no tag conflicts with `tag_registry` (Skip, or Override with a reason).
- `record_load_out` saves in one transaction: `delivery_receipts`, `load_out_destinations`, `lot_pasture_assignments` (the first pasture placement) and `lot_tags`.
- A load out can also come from a photo of the paper ticket (built 2026-10-09). Claude stages it; the office saves it in Approvals > Load outs (`openLoadOutFromTicket` :38124).
- After the save, the processing medicine is drawn from inventory (`invRecordProcessingDraw` :37278 calls `med_processing_draw`).
- Processing cost is worked out live from receipt protocol × `protocol_meds` × `medications`. It is never stored.
- After saving, only the protocol, invoice link and notes can be edited. Anything else means delete (`delete_receipt_with_reversal`) and re-enter.

**Finish**
- A load out saved before a weight exists leaves its per-cwt medicine undrawn. The draw runs again only when someone re-saves the load out. 32-26 still has 3 lines undrawn (OPEN-ITEMS 0i).
- Synovex Primer has no container size (OPEN-ITEMS 0l). Protivity and Dexamethasone have no price (snapshot).
- 37X receipts: 361 head are invoiced with no load out behind them.

**Build**
- A way to receive untagged (`NT<n>`) animals on a load out. Today it takes only an integer tag range.
- Lot-wide NT numbering. Today the field app numbers NT tags per phone, so two phones can both hand out NT1 (gotchas.md).
- Re-run the undrawn per-cwt medicine draws automatically when a weight arrives (invoice or estimate edit).
- Date-driven protocol versioning. Today `effective_from` is decorative and receipts are repointed by hand SQL (costs.md:59-85).

**Issues**
- Some checks exist only in the browser. `record_load_out` does not re-check:
  - tag count = head;
  - a future date;
  - a load out dated before the lot's arrival date.
- Tag conflicts are checked in two places that can disagree: the client reads `tag_registry`, the RPC reads `lot_tags`.
- Swallowed errors, against the "errors are never swallowed" rule:
  - the duplicate check failing only does `console.warn` (:27838);
  - the tag-conflict check failing "skips silently" (:27866);
  - `med_processing_reverse` is never checked for an error (:37298), so a failed reverse can double a draw.
- The default protocol (`lotDefaultProtocolId` :10191) ignores sex class. With more than one active Receiving protocol it picks blank, which means $0 processing.

---

## Stage 3: Invoice, assumptions and budget

**Have**
- Purchases > **+ Invoice** opens `openInvoiceModal` (:10217): date, number, head, total weight, total cost and protocol. Load outs are linked to the invoice while editing it.
- `lot_status.head_in` = GREATEST(invoiced head, received head). Cost in and average weight in come from invoices.
- Closeout > **Save assumptions** (:9964) saves the lot's cost assumptions. The `lot_assumption_history` trigger logs every change to the Audit log tab.
- **Freeze as budget** (`freezeLotBudget` :9869) needs an invoice, a ship date and a sale price. A trigger blocks later edits; only the owner can delete.

**Finish**
- An assumption sanity band (a warning on rates that look wrong) was proposed and not built (OPEN-ITEMS §8).
- The non-feed rate is a $0.50 placeholder until the Redwing cost ledger lands (OPEN-ITEMS §21).
- 32-27: 97 head are still waiting on an invoice.

**Build**
- A prompt to freeze the budget when the lot is complete. Today freezing is manual, even though costs.md:102 says the budget is "frozen when the lot starts".

**Issues**
- Invoice delete is a raw `delete()` (:10475). It does not check that a row was removed and does not reverse the processing draws on linked receipts.
- Invoice edit does not check the returned rows (:10406). A refused update looks like success (OPEN-ITEMS §3, silent RLS refusal).
- A new invoice's head is checked against its load outs only on edit, not on create.
- An invoice entered before its load out raises `head_current` with no pasture behind it. D8 goes red until the load out is entered. This is 37X's state.
- Freezing the budget after the first of several loads bakes in partial head and weight.
- `target_adg` is written in two places: the lot modal and the Closeout assumptions.

---

## Stage 4: In-life (grazing)

### 4a. Field entries and Approvals

**Have**
- The field app writes only to `pending_field_entries`.
- The office Approvals tab posts a batch all or nothing (`approveSelected` :11644, `rollbackPosted` :11609). Doctoring, counts and weights post first; deaths and moves post after, in time order.
- Stale-pasture fixes: `apprFixPastures` / `apprKeepPasture`.

**Issues**
- Marking an entry approved (:11711) has no `.eq('status','pending')` and does not check the returned rows.
  - If marking fails partway, `rollbackPosted` removes the book rows, but the rows already marked `approved` stay approved.
  - `approved` is terminal, so those entries can never post.
  - Two office users approving at once can both post the same entry. No unique constraint guards it.
- Field doctoring posts in three separate browser calls: event, medicine lines, medicine draw. The cleanup ignores its own error (:11478).
- A count is tied against the books when the entry is resolved, but it posts before same-batch deaths and moves. The tie is not re-checked when it posts.

### 4b. Pastures, moves and head-days

**Have**
- Moves (`saveMoves` :15346) and Settle counts (`saveSettlePasture` :11942) go through `record_move_with_pasture`. Reversals use `delete_move_event`.
- The Anomalies report flags pasture sum ≠ head_current and `pasture_head_log_check`.
- Pasture head-days steps 1-3 are built. Go-live is 2026-11-01.

**Finish**
- Pasture head-days steps 4-7 are not built: Redwing ledger import, lot pasture charges, season close / true-up, WIP allocation report (pasture-headdays-phase-design.md:147-160). C9 and C10 wait on John's sample export.

**Issues**
- Direct `lot_pasture_assignments` writes still exist outside the RPCs, for example the shipment save (:14214).
  - These log on the day entered, not the event day.
  - The FY27 gap between lot head-days and assignment head-days (134,749 vs 84,800) is left as history.
- PB feed now spreads each pasture's drop to its lots by head on open assignments. A drifted split now mis-charges feed dollars, not only sale allocation. architecture.md:1028 still says "the split touches no money".
- There are two head-day implementations: the `lot_head_days()` function and the `lot_daily_head` view. They disagree by up to 29%. Only the view is right for cost.

### 4c. Feed and the feed pen

**Have**
- The PB email is staged into `pb_daily_reports` and approved with `approve_pb_report`. The latest report is 10-08, approved.
- Hand feed-out uses `post_feed_usage`; feed counts use `post_feed_count`. Inventory is FIFO through `feed_receipts` / `feed_usage_costs`.
- Feed pen: removal, "found in the pen", and the year-end `close_feed_pen_year` (owner).

**Finish**
- Nothing guards against feeding a premix and its own ingredients at the same time (OPEN-ITEMS #10).
- Range-cube allocation has no scope yet (OPEN-ITEMS #19).
- `fpoSave` does not pass `p_entry_kind` (:17385), so a stray off a closed lot records as `'opening'`, not `'stray'`.

**Issues**
- Feed cost history starts 2026-08-31, so COG per head-day is meaningless for any lot that arrived earlier (snapshot item 5).
- A death in the feed pen does not count against the lot the animal came from, which flatters that lot's death loss.

### 4d. Health, medicine and withdrawal

**Have**
- Office doctoring entry (`saveDoctoringEntryBatch` :28883). Medicine is drawn through `med_consume`; voids use `med_void_doctoring`.
- Checkouts (`med_transfer`) and direct charges (Meds > Charge out).
- Withdrawal holds warn and list the tags; they never block.
- Health curves report and lot health card.

**Finish**
- Crew doctoring entered in the office app never draws medicine, because `med_consume` is SECURITY INVOKER. This waits on John's role-model decision (OPEN-ITEMS #0).
- `invLedgerReady` picks the ranch location with `.limit(1)` (:37199). The doc calls the fix "not optional" (OPEN-ITEMS 0d).
- Redwing still expenses medicine when issued. Method B was proposed and not adopted (OPEN-ITEMS 0e).
- Health curves: flag thresholds are blank, `health_exceptions` is empty, and the Position Desk panel and by-order-buyer cut are not built.
- Open question: should withdrawal include processing medicine given at receiving?

**Issues**
- **Medicine draw errors are thrown away.** `med_consume` sits in `try{}catch{}` (:37253-37264). supabase-js returns `{error}` and does not throw, so a failed draw is never noticed. The treatment saves, the shelf does not move, and the next count books it as shrink.
- `invLedgerReady` caches `false` for the whole session after one read error. Every later dose then skips the ledger silently until the page reloads.
- Unpriced medicine posts at $0, frozen at approval. Approvals warns but does not block (:11663). This is how Protivity and Dexamethasone got through.
- Medicine dollar columns are hidden from crew on screen only. Crew can still read them through the API.

### 4e. Deaths, strays, missing, transfers

**Have**
- Deaths: `record_death_with_pasture`, `update_death_event`, `delete_death_event`. Tags retire through an AFTER trigger.
- Strays and missing head: `record_missing_head` / `record_stray_return`.
- Lot transfers: `record_lot_transfer` and `recompute_transfer_basis`.

**Finish**
- 47-26's "missing" death has not been reclassified as a missing-head adjustment (architecture.md:605).
- Transfers have no field-app entry. Cattle cost and head-days do not travel with transferred animals in the closeout (OPEN-ITEMS §9).

**Issues**
- A multi-row death save is not atomic (:27024-27041). Earlier rows stay saved when a later row fails, and the user must delete them by hand.

### 4f. Weights and projection

**Have**
- Weights enter only through field approvals (`postWeightEntry` :11573). Projection order is phases → realized → assumed.

**Build**
- An office screen to enter a whole-lot or chute weighing.
- The weight level correction and B1, blending a partial weighing into the lot average (weight-estimation-design.md).

**Issues**
- `lot_status` counts days with `CURRENT_DATE`: `days_on_feed`, `days_since_weighted_arrival` and `projected_current_weight` (docs/sql/2026-09-10_realized_adg_projection.sql:266-282). After about 7 pm Central these run one day ahead. This breaks the `ranch_today()` rule. `lot_weight_anchor` already uses `ranch_today()`.

---

## Stage 5: Market and sell

**Have**
- Sales > Positions: `positions`, `position_lot_links`, `hedge_coverage_by_month`.
  - `market_quotes` is filled each night by the `market-quotes-sync` edge function.
- Selling starts at Lot > **+ Sale**, which opens a shipment (`openShipmentForLot`).
  - Pay weight is gross less shrink, or typed directly.
  - Also entered: $/cwt, deductions and freight.
- Head is split across lots and pastures by largest remainder (`shpAllocate`). `saveShipment` (:14025) writes:
  - `shipments` and the load tables;
  - one `sales` row per lot per day;
  - `sale_sources`;
  - the decrements to pasture assignments.
- After a shipment saves, it offers to close any lot it emptied.
- Deletes use owner-only RPCs that put the head back: `delete_shipment_with_reversal` and `delete_sale_with_reversal`.
- Sales > Accounting Report exports one shipment in Redwing's 12 columns.

**Finish**
- The 37X-1 sale on 2026-06-04 (2 head) has no net weight, price/cwt or buyer, and no shipment.
- Three `[VERIFICATION ROW 2026-09-10]` positions against 36-27 are still flagged to be deleted.
- Hedge coverage % stays blank until lots carry `target_ship_weight`. No lot does.

**Build**
- **Tag retirement on sale.** The trigger fires only when a sale carries `tag_start`/`tag_end`. `saveShipment` never writes them, so sold tags stay active. This is the cause of snapshot item 1. The fix needs a decision: capture sold tags at the shipment, or retire all remaining active tags when the lot closes.
- Mark-to-market and realized P&L on positions. Hedge results never reach the lot closeout.
- An export path for the 15 legacy lot sales that have no shipment.
- Storing the production/tax year. Today it is typed at export time and stored nowhere.
- Reports by tax year (calendar) and by stocker year (Jul-Jun).

**Issues**
- **`saveShipment` is not atomic.** It is many browser statements.
  - Closing the tab mid-save leaves sales without their pasture decrements, and the drift is permanent.
  - The rollback checks only for an error, never for rows removed. `shipments` DELETE is owner-only, so for an office user the shipment row survives while the message says "Everything was rolled back".
  - CLAUDE.md says sales go through atomic RPCs; today only the deletes do.
- The reversal RPCs silently reopen closed lots. Neither warns about books already reported for the year.
- Market quotes are Yahoo closes, not CME settlements. The cron job uses the publishable key, so anyone with that key can trigger a run.
- Dead code: the legacy new-sale branch (:30766-30791) does unchecked assignment updates. The empty-state text "Click '+ Sale'" (:30195) still points users at it.

---

## Stage 6: Close the lot

**Have**
- There is no status column. Open means `lots.closed_at IS NULL`.
- Four browser paths write `closed_at = new Date().toISOString()`:
  1. the kebab **Close lot** button (:10172), which also re-opens;
  2. `offerToCloseEmptiedLots` after a shipment (:14303);
  3. the death save's 0-head prompt (:27064);
  4. the legacy sale form's 0-head prompt (:30821).
- The only gate is `closeLotGuard` (:10155). It refuses while a sale has no pay weight, unless the user marks the sale `[no scale ticket]`.
- Transfers close an emptied source lot server-side, and that path does check head = 0.
- The Closeout tab shows Budget, Actual and Projection side by side. Once anything has sold it splits into sold head / head left / lot at close.

**Build: a real lot close**

Today closing a lot is one timestamp. It needs a `close_lot` RPC (and `reopen_lot`) that refuses to close unless:

- `head_current = 0` and there are no open pasture assignments (D8 tie at zero);
- no field entries, PB reports or medicine invoices are pending for the lot;
- every sale has a pay weight and a price, or a recorded no-ticket decision;
- every processing and doctoring line is priced (no NULL cost);
- every tag is retired;
- the invoice head matches the received head.

When it closes, it should:

- stamp `closed_at` from `ranch_today()`;
- freeze a closeout snapshot (head, weights, costs, revenue, COG, break-even, hedge result) in a closed-lot results table, so the P&L stops moving;
- write an audit note.

Re-open should be owner-only, need a reason, and warn when the fiscal year has already been reported.

After that:

- a cross-lot P&L / lot comparison report, and budget vs actual break-even (parked, architecture.md:1200);
- a stocker-lot year-end posting, like the feed pen has;
- the daily breakeven-vs-market dashboard (roadmap #5) and the "Forecast/Realized breakevens" TODO on the lot tile (:7932).

**Issues**
- **The kebab Close lot button closes a lot that still has head on pastures.** Closed lots then drop out of `lot_head_tieout` and the drift badge, and `lot_daily_head` stops at `closed_at`. Leftover head and its cost disappear without notice.
- **A closed lot's P&L keeps changing.** Interest runs from start to `ranchToday()` (:8724, :8892), also on transfers (:8910). The header says "to <today>" even on a closed lot. Interest also keeps accruing on cattle already sold.
- Closeout revenue uses `total_price` only (:8920). The lot Sales table falls back to `price_per_head × head`, so the two screens disagree when `total_price` is null. `soldWeight` falls back to gross weight, against the pay-weight-only rule.
- Close timestamps use the browser clock in UTC. A close after about 7 pm Central dates to the next day.
- Swallowed errors: the death-path close (:27060-27067) ignores both its read and its update error. The legacy sale close (:30820) ignores its update error.
- `[no scale ticket]` is free text in `sales.notes`. Anyone with write access can add or remove it, and there is no audit trail.

**Ready to close now** (head left): 60X (2), 59X (3), 37X-F (8), 37X-1 (9), 37X (32). Each of these also has unretired tags, and 37X / 37X-1 have the data holes listed above.

---

## Cross-cutting

- **Atomicity.** Shipments, invoices, field doctoring, multi-row deaths, approval marking and lot close run as browser statements. They should be RPCs, as moves, deaths and load outs already are.
- **Silent RLS refusals.** Updates and deletes that do not check returned rows (OPEN-ITEMS §3).
- **Swallowed errors.** Six or more places listed above break the "errors are never swallowed" rule.
- **Clock.** `lot_status` uses `CURRENT_DATE` and close timestamps use the browser clock. Both should use `ranch_today()`.
- **NULL costs.** Unpriced medicine passes through Approvals with a warning only and freezes at $0.
- **Roles.** The crew boundary has never been tested with a real crew login (OPEN-ITEMS #12).
- **Cost model.** COG and labor are typed rates until the Redwing cost ledger import (OPEN-ITEMS §21).

---

## Punch list

### A. Data fixes (investigate, show, get John's approval, then correct with an audit note)
1. Price Protivity and Dexamethasone (new price rows, not edits in place to past costs).
2. Find and enter the missing 37X receipts (361 head), or reconcile the invoice.
3. Complete the 37X-1 06-04 sale (weight, price, buyer), or mark it no-ticket.
4. Retire sold and dead tags on the X lots, once the rule in B1 is decided.
5. Clear the 3 medicine invoices waiting since 10-02, and the 3 verification positions.
6. Invoice the 97 head on 32-27. Add cost assumptions to 60X (47-26 is closed).
7. Look into the medicine over-use: Draxxin at the Ranch; Ferappease, Valcor and Synovex C at Jake Taylor.

### B. Finish (small, built mostly)
1. Tag retirement on sale (decision: at the shipment, or at close).
2. Check `med_consume` and `med_processing_reverse` results. Stop caching `invLedgerReady=false`.
3. Guard approval marking with `.eq('status','pending')` and a row check.
4. Switch `lot_status` to `ranch_today()`.
5. Make the closeout stop interest at `closed_at` and on sold head. Fall back to per-head revenue. Use net weight only.
6. Close timestamps from `ranch_today()`. Surface the swallowed close errors.
7. `fpoSave` passes `p_entry_kind`.
8. Re-run undrawn per-cwt draws when a weight lands. Clear the 32-26 lines.
9. Make `lotDefaultProtocolId` respect sex class.
10. Stop overwriting `created_by` on lot edit.
11. Remove the dead legacy new-sale code and its empty-state text.

### C. Build (new work, in suggested order)
1. `close_lot` / `reopen_lot` RPC with the gates above, plus a frozen closeout snapshot table.
2. A `save_shipment` RPC (atomic), so sales stop drifting on a failed save.
3. RPCs for invoice save/delete (with draw reversal) and multi-row deaths.
4. A lot readiness checklist (invoice, protocol, assumptions, budget) shown on the lot.
5. Structured purchase fields (seller, freight, commission, pay vs shrunk weight).
6. Hedge P&L into the closeout. Mark-to-market on positions.
7. Cross-lot P&L and lot comparison. Reports by tax year and stocker year. A stocker year-end posting.
8. An office weighing entry screen. Then the weight level correction.
9. Pasture head-days steps 4-7 (go-live 11/1).
10. Lot-wide NT tag numbering, and NT on load outs.

### Decisions needed from John
- Tag retirement on sale: capture sold tags at the shipment, or retire all remaining tags at close?
- Crew medicine draw from office doctoring (`med_consume` INVOKER): which role model?
- Close gates: which of the list above are hard blocks and which are warnings?
- Should re-open stay possible after the fiscal year is reported?
- Should withdrawal include processing medicine given at receiving?
- Redwing medicine expensing: Method B or not?
