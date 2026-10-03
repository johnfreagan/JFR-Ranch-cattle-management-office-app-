# Feed: inventory, cost of gain, inventory flow, PB daily import

_Moved word for word from `CLAUDE.md` on 2026-09-27, when CLAUDE.md became a short index. Nothing here was rewritten; section dates are the dates the rules were written._

Decisions and plans in full: `docs/feed-design-decisions.md`, `docs/commodity-feed-inventory-plan.md`, `docs/inventory-flow-design.md`.

## Commodity feed & mineral inventory (phases 1-2 live 2026-08-27)

Migration: `docs/sql/2026-08-27_feed_inventory.sql`. Plan and the reasoning
behind every choice: `docs/commodity-feed-inventory-plan.md`. Office+owner
only; the whole tab carries `data-perm="office"`.

```
feed_receipts (= the FIFO layer)  ──▶ feed_usage ──▶ feed_usage_costs (frozen $)
feed_items · feed_storage_locations       │              ▲
feed_counts · feed_count_lines ───────────┘   physical count → variance → ledger
```

- **`feed_items` has NO price column, and that is the point.** Price lives on
  the receipt that brought the load in and FREEZES into `feed_usage_costs`
  when the pounds are consumed. This is treatment cost's behaviour, chosen
  deliberately against processing cost's — where editing a drug price silently
  rewrites closed lots and prior fiscal years. Do not add `cost_per_lb` to
  `feed_items`; the migration's verify block raises if anyone does.
- **The one sanctioned after-the-fact write is `recost_pending_usage()`.**
  Feed gets delivered, fed, and only then invoiced. Those cost rows are
  written NULL and flagged; the RPC fills them in and is guarded
  `WHERE cost IS NULL`, so it can fill a hole but never move a frozen number.
  The receipt modal calls it automatically when an unpriced load gets a price.
- **A blank cost is not allowed to be an accident.** `cost_pending` is an
  explicit checkbox. Without it the unpriced-medication trap repeats exactly:
  NULL cost, `SUM()` ignores it, feed silently becomes free.
- **FIFO runs per (item, location).** Corn in Bay 2 and Bay 5 are one item in
  two places. Global FIFO would let a count on one bay eat a layer sitting in
  another and on-hand-by-bay would stop reconciling.
- **Going short is allowed, flagged, never blocked.** A bulk bay is an
  estimate; if the layers run out, the remainder costs at the item's last
  known price and sets `is_short`. Refusing does not un-feed the cattle.
- **`feed_usage` carries `period_start`/`period_end`, not just a date.** Feed
  is entered weekly and PB invoices a date RANGE. Phase 4 spreads dollars over
  the head-days inside the window — same reason the app writes one `sales` row
  per lot per DAY.
- **`delete_feed_usage` puts pounds back on the exact layers, with no branch
  for a layer consumed to zero.** That branch is the `delete_death_event` trap
  in feed form. Verified against a layer emptied outright, not just a partial.
- `delete_feed_receipt` REFUSES once any pounds are consumed — orphaning
  frozen costs is the disaster this module exists to prevent.
- A transfer between bays lays a new layer at the cost it left at, linked by
  `feed_receipts.from_usage_id`. The reversal refuses if the far bay has
  already fed any of it.
- **Bulk feeders in pastures are NOT locations** (John, 2026-08-27). A
  location is where feed is stored and counted. Feed leaving a bay for a
  feeder is just usage.
- Bays are added and edited in the app — there is no seed list.
- **PB supplies pounds, we own the cost.** The 2026-08-27 invoice is commodity
  level (no rations), its group IS the lot number, it has no per-pen split,
  and its head count and head-days tie to our books exactly. Import
  `Amount Fed` only: never `Cost Per Ton`/`Feed Cost` (may go stale or blank),
  never `Dry Matter Fed` (12.4% low — it would leave a phantom bay balance).
- **Phase 3's real hazard is an OVERLAPPING import, not a duplicate one.**
  `pb_row_key` upserts a re-run of the same invoice; running Aug 17-26 then
  Aug 20-31 double-feeds four days under different keys.

### Counts: book as of the count date, and removing a count (live 2026-10-03)

Migration: `docs/sql/2026-10-03e_feed_count_remove_and_as_of.sql`.

- **Book on a count is the book at the START of the count date**, not at the
  moment of posting (John, 2026-10-03: the count is taken before the truck
  loads). `feed_book_as_of(location, date)` is today's layers, plus what usage
  dated that day or later drew, minus receipts dated that day or later. The
  count sheet and `post_feed_count` both read it, so a count keyed days late
  still compares to the right number. Rows dated ON the count date that still
  count as before it: `count` usage, `count_adjustment` and `opening_balance`
  receipts. A weekly hand entry is all-before or all-after by its `usage_date`.
- **A posted count is removed with `void_feed_count(count_id, reason)`, owner
  only.** Usage goes back through `delete_feed_usage` (exact layers), found
  layers come off through `delete_feed_receipt` (refuses if any was fed). The
  count row stays, `status = 'voided'`, with who, when and why. Edit is remove
  and re-enter. The latest count at a location must come out first.
- The lot-split consumption rows are not linked from the count line. They are
  matched on `source = 'count'`, location, item and `created_at = posted_at`
  (one transaction, one `now()`), and the function proves the pounds tie to
  the lines before it reverses anything.
- **Never raw-delete a posted count.** A trigger refuses; only a draft deletes.
- **A PB daily email showing 0 lb fed means the ranch did not feed.** It is not
  a capture failure and not a reason for a count variance.

### Design decisions taken 2026-08-28 — read `docs/feed-design-decisions.md`

Twenty-five decisions, DECIDED NOT YET BUILT. The full record with the reasoning
for each is in `docs/feed-design-decisions.md`. The ones that change existing
rules:

- **The app is the system of record for feed on hand.** Counts are truth. PB
  supplies usage pounds; Redwing receives our dollars. PB carries four negative
  balances and Redwing carries Salt at −5,457 lb with +$1,999.18 of value —
  neither can be trusted for custody.
- **Cut-over is 2026-09-01, BARN ONLY.** August and prior stay on the cost
  allocation; from 9/1 every lot charges actual feed. Silage is not being fed and
  is carried as a named reconciling item ($225,155). No backdating.
- **`feed_direct_from` must be a RANCH-LEVEL DATE, not the per-lot flag phase 4
  shipped.** (It only bites on lots that HAVE a non-feed rate — see the
  one-number rule under phase 4.) That flag has no date and rewrites a lot's whole life: setting it on
  36-27 on 9/1 would re-price August from $2.00 to ~$1.00/hd/day with no actual
  feed to replace it — about $6,400 evaporating. The closeout must SPLIT
  head-days on the date.
- **Several app items may map to ONE Redwing template box.** Do NOT merge "Corn"
  and "Corn hopper bin" — PB encodes the bay in the commodity name, and that is
  the only signal telling an import which pile was fed. This reverses earlier
  advice in OPEN-ITEMS.
- **Silage shrink is haircut at ENTRY** (gross × (1 − allowance), full harvest
  cost held), so no revaluation mechanic is needed. Store gross, allowance and
  booked separately — actual shrink calibrates on GROSS, never on booked, or each
  year's estimate error compounds into the next.
- **Barn shrink goes to a two-sided variance account, never to a lot.** Its
  balance is the accuracy of the allowances, so found feed must credit the same
  account. Do not build allowance machinery for purchased commodities yet —
  haircutting a scale-ticketed load breaks the invoice and Redwing tie.
- **A count variance means different things per item.** Barn commodities: we know
  what was fed, so it is SHRINK. Mineral: no feeding record exists, so it is
  CONSUMPTION, allocated by head-days across every open lot. One per-item setting.
- **The observed cost-per-pound-of-gain read-out stays on REALIZED ADG only.**
  John's assumed ADG is deliberately biased low; converting a $/lb cost rate
  through it makes the cost projection optimistic ($94/head in the worked
  example) while the revenue side is already conservative. **Superseded in
  part 2026-09-04:** the `per_lb` COG mode (Closeout section) does charge a
  $/lb rate on assumed-ADG gain, by John's decision, and mitigates this by
  truing up to real pay weights as head ship and warning when the shipped
  head ran ahead of the assumption.
- **A premix short is not an ordinary short.** It means the ingredients are still
  on the books — two errors, and the feed still allocates cleanly so nothing looks
  broken. That is how PB reached −1,109,171 lb. It needs its own anomaly wording.
- **Shrink surfaces as a bay that will not go to zero, not as going short.**
  Physical < book = book balance survives on an empty bay. Going short is the
  opposite signal: a delivery was never entered.

### Cost of gain and premixes (phase 4, live 2026-08-27)

- **Feed cost spreads over head-days INSIDE each usage's period**, never onto
  one date. `lot_feed_daily` divides a usage across the days in
  `[period_start, period_end]` in proportion to `lot_daily_head.head_on_hand`.
  Verified on 36-27's real curve: 31,630 lb over Aug 17-26 spreads to the
  penny and sums back to $2,501.14.
- **`feed_cost_unallocated` exists because a JOIN would drop it silently.** A
  usage whose period holds no head-days for its lot cannot spread; rather than
  vanish, it surfaces there and on `lot_feed_costs.unallocated_usd`, and the
  Closeout warns.
- **Since 2026-09-11 there is a RANCH DEFAULT non-feed rate**
  (`ranch_settings.nonfeed_cog_per_day`, `docs/sql/2026-09-11_nonfeed_default.sql`,
  decision in `docs/cog-design-decisions.md` §4). Resolution on the
  closeout: typed in the box → stored on the lot → ranch default; a blank
  box means inherit. So the feed boundary is ON for every lot with
  head-days since 2026-09-01: actual feed charged beside $0.50/head-day on
  those days, the assumed $/lb before. **$0.50 is a placeholder** (John,
  2026-09-11: no hard number yet; excludes labor, which has its own line,
  and feed); `nonfeed_cog_note` says so and the closeout hint shows it in
  amber with a `set` link that updates the ranch row (office/owner UPDATE
  policy). The paragraph below describes the per-lot override, which still
  works exactly as written; only the "NULL means one number" part now
  means "NULL on the lot AND no ranch default".
- **`lots.assumed_nonfeed_cog_per_day` is the COG split, per lot, NULL until
  known — and NULL means COG IS ONE NUMBER.** John, 2026-09-04: "I consider
  COG to be feed and non-feed cost of gain … for now I think in terms of one
  number." While NULL the assumed COG rate is charged on every head-day, the
  feed cut-over date is ignored for that lot, and actual feed shows as a
  **memo row, never added** — the rate already contains it. There is no
  overlap warning and no Anomalies finding for a missing non-feed rate any
  more. Set the rate (Closeout → working assumptions, saved with the rest)
  and that lot switches to actual feed plus the non-feed rate from the
  cut-over. Nothing recomputes retroactively.
- **Forward feed rate is dollars-since-cut-over over head-days-since-cut-over**
  (`currentFeedAfterBoundary / hdAfter`), not the view's `cost_per_head_day`,
  which divides by the lot's whole life. On 36-27 that view read five cents a
  head-day off one day of mineral over 8,931 head-days and carried ~$4,000
  to March. Whole-life is the fallback only when the split is not loaded.
- Feed carries forward in the Projection at the lot's own observed $/hd/day,
  the same treatment cost already gets.
- **A premix is many-in-one-out**: `make_feed_batch` consumes N commodities
  FIFO, sums the frozen dollars, and creates ONE layer for the premix in its
  own bay. No second costing path — the premix is then an ordinary item.
  `delete_feed_batch` refuses once any of it has been fed.
- **Recipes only PRE-FILL.** Actual weights freeze onto the batch. A recipe
  read at cost time would rewrite what every past batch was made of.
- **Feed the premix, never the premix AND its ingredients** — the ingredients
  were consumed when the batch was mixed. Double-counting still allocates
  cleanly, so nothing looks wrong.
- Yield: output pounds = sum of inputs (John's call). `output_qty_lb` is
  stored, not derived, so weighing a batch later is a form field.
- **`post_feed_usage` gained `p_batch_id` and was DROPped and recreated**, not
  overloaded — PostgREST resolves an RPC by argument names and two overloads
  make that ambiguous. The verify block asserts exactly one exists.

## Inventory flow: order → delivery → invoice (wave 1 live 2026-08-31)

Migration: `docs/sql/2026-08-31_inventory_flow.sql`. All 23 decisions with the
reasoning and the rejected alternatives: `docs/inventory-flow-design.md`.
Office+owner only. **The `Feed` tab is now `Inventory`.**

```
reorder signal ─▶ supply_orders ─▶ supply_order_lines ─┐ (one line, many loads)
                                                        ▼
vendors                                          feed_receipts  ← THE FIFO LAYER
                                                        │  costed at the ORDERED price
                                                        ▼
                                supply_invoices ─▶ supply_invoice_receipts
                                                        │  difference only
                                                        ▼
                                                feed_price_variance
```

- **One spine, two ledgers.** `supply_order_lines` carries `item_kind` plus
  `feed_item_id` / `medication_id` with a CHECK that exactly one is set. Meds
  join as a receiving handler, not a second set of screens. Ordering,
  invoicing and the worklist are shared; consumption and costing are not.
- **A delivered load is costed at the ORDERED price**, so feed stops reading
  free until the bill arrives — which was the status quo and is the same
  `SUM()`-ignores-NULL failure the feed module was built to avoid.
  `cost_pending` is now the flagged exception, not the normal path.
- **When the invoice differs, the layer is corrected GOING FORWARD and the
  already-consumed difference is booked to `feed_price_variance`.**
  `feed_usage_costs` is never rewritten. Restating frozen costs would reopen
  closed lots and prior fiscal years exactly the way editing a drug price
  does — processing cost with a slower fuse.
- **The invoice adjustment rides on `feed_receipts.other_cost`**, whose `>= 0`
  check is relaxed because a bill can come in low. `total_cost` and
  `unit_cost_per_lb` are generated from the three cost columns and FIFO reads
  `unit_cost_per_lb`, so one of them has to move; `product_cost` and
  `freight_cost` keep saying what was agreed. The audit trail lives on
  `supply_invoice_receipts` (what the bill said) and `feed_price_variance`
  (what it cost us), not on that column.
- **A load that arrived UNPRICED takes the other path.** Its usage costs are
  NULL holes, not frozen numbers, so matching an invoice fills them through
  the existing `recost_pending_usage()` and writes NO variance row.
- **Orders are optional in the schema and leading in the screen.**
  `feed_receipts.order_line_id` is nullable. Requiring it would have people
  typing fake orders to record a load that turned up unannounced — into the
  very table the reorder alerts read from. An unordered load shows as an
  exception instead.
- **A line with `qty_lb` NULL is a REMINDER-ONLY line** — "Mark ordered" with
  nothing else typed. That is the whole med workflow John described. Any
  receipt for that item auto-closes it, so there is nothing to tidy.
- **`record_feed_delivery()` is the only way a new layer is created from the
  app.** The insert, the order-line close and the reminder close are one
  atomic step, and a field-app caller later is a caller, not a second
  implementation. Editing a delivery is still an ordinary UPDATE — it moves
  no order state.
- **Deleting a delivery reopens the line it closed** (`fdReopenOrderLineIfEmpty`),
  but only when nothing else is left on the line AND the app closed it on
  delivery. A line closed by hand — "that's all they're bringing" — was a
  decision, not a side effect. **This lives in the app, not in
  `delete_feed_receipt`; move it into the RPC next time that RPC is touched.**
- **An invoice can be created and deleted, not re-allocated.** Same posture as
  a saved shipment. `delete_supply_invoice` refuses once variance has been
  booked, because unwinding it would leave frozen usage costs at the invoice
  price while the layer went back to the ordered one.
- **Tie out first, allocate only on a difference.** If the bill matches the
  sum of what those loads expected to cost, every load keeps exactly its own
  number and nothing is booked. Otherwise the difference spreads pro-rata by
  pounds (largest-remainder, sums EXACTLY) or is typed per load.
- **This is NOT accounts payable.** Redwing owns the payable. No due dates, no
  payment status, no aging, no check numbers.

### The one list

`inventory_needs_attention` (view) is the single definition behind the
Needs Attention sub-tab, the count badge on the Inventory tab, and the 7am
email in wave 3. Ten row kinds; four of them (`bay_short`, `premix_short`,
`count_overdue`, `feed_unallocated`) already existed and were merely
ungathered.

- **A row appears because a FIELD IS EMPTY, not because someone wrote a note.**
  A reminder you must remember to set is a reminder for the days you did not
  need one, and it never clears itself. `paperwork_done` is the one deliberate
  "stop asking", recording who decided and when.
- `source` auto-exempts: `count_adjustment`, `transfer_in`, `batch_out` and
  `opening_balance` never expect a ticket or a bill.
- **Rows age visibly.** *Awaiting invoice — 34 days* is a phone call;
  *— 3 days* is the post.

### Inventory tab layout

**Sub-tabs are the ACTIVITY; the material chip is what you are doing it to.**
Feed shows eleven sub-tabs, Meds shows the four material-agnostic ones.
Adding fuel or parts later is a chip and a `data-material` attribute, not
another screen. Materials-as-sub-tabs was rejected: Orders under Feed and
Orders under Meds are two screens, and a vendor billing both on one invoice
would have nowhere to file it.

- `Loads In` became **Deliveries**; the old `Inventory` sub-tab became **On Hand**.
- **The group menu (`.sub-group` / `.group-menu`) is shared, not Inventory's.**
  `subGroupToggle()`, `subGroupsClose()` and `subGroupsRelabel()` sit with the
  sub-tab wiring; one document-level click closes any open menu. The Reports
  bar uses the same shape (2026-09-03): Active Lots · Daily Report ·
  Anomalies stay flat, **Pastures ▾** holds Yard Sheet and Pasture
  Utilization, **Health ▾** holds Receiving, Doctoring & Deaths and Death
  Analysis. Settings is the LAST top-level tab. Do not write a third copy of
  the menu logic for the next bar that grows.
- **The medications catalog stays under Animal Health.** Dose, `round_up_to`,
  price and protocol membership are a doctoring tool read by the field app's
  pickers. Inventory → Meds will hold the *stock*. One drug, two screens.

### Day-one data lesson (worth keeping)

The vendor seed crashed on `vendors_name_uniq` because it deduped with
`DISTINCT btrim(vendor)` against a unique index on `lower(name)` — three
capitalisations of "Beginning Inventory" survived and collided. **A seed
feeding a case-insensitive index must dedupe the way the index does.**

The quieter half mattered more: the marker exclusion list had been written
from a snapshot taken an hour earlier, and five hand-entered opening balances
had appeared since. They would not have crashed anything — they would have
nagged for a weight ticket forever. The verify block now asserts that no
bookkeeping marker became a vendor.

### Wave 2 and 3 — decided, not built

- **Wave 2, reorder.** `on_hand ≤ greatest(floor_qty, daily_burn × (lead_time +
  safety))`; blank means silent, so silage never alerts. Burn comes off
  `lot_feed_daily`'s spread — never off `usage_date`, or a weekly ticket reads
  as a Friday spike — over `least(21, days since first usage)`, suppressed
  below 7 days. The alert is DERIVED; only `was_low_at_last_check`,
  `last_notified_at` and `snoozed_until` are stored. Notify on the transition
  into low, re-notify every 7 days, zero-on-hand breaks a snooze.
  It goes second because **it cannot be tested before there is a week of real
  feed-out to sanity-check the computed lb/day against.**
- **Wave 3, the 7am email.** The app writes to a `notification_outbox`; a
  sender decides how it travels, so a failed send is a visible row rather than
  a silent nothing. Same machinery OPEN-ITEMS #7 needs for the daily report.
  Blocked on John: a Resend account with a verified domain, and `pg_cron` +
  `pg_net` enabled. 7:00am pinned to `America/Chicago`.

## PB daily feed report: email → Approvals → books (built 2026-09-25)

Performance Beef emails a "Delivery Daily Report" every feeding day. A
**Cowork scheduled task reads it each morning** and calls
`stage_pb_report(message_id, text)`; the office reviews it on **Approvals →
Feed**; `approve_pb_report` posts it. Migrations, in order:
`docs/sql/2026-09-25_pb_email_import.sql`, `..._pb_report_list.sql`,
`..._25b_pb_split_drop.sql`, `..._25c_pb_revoke_anon.sql`,
`2026-09-26_pb_parse_2026_format.sql`, `..._26b_pb_norm_revoke_anon.sql`.
The first two and `pb_parse_2026_format` were applied from other sessions
and pulled into the repo verbatim (file md5 = the stored migration's md5).

```
PB email ─(Cowork, mornings)─▶ stage_pb_report ─▶ pb_daily_reports + pb_report_lines
                                                      │  pb_refresh_report → problems[] (block) / notes[] (don't)
Approvals → Feed: Move · Split by weight · Reject     │
                  Approve ─▶ approve_pb_report ─▶ feed_usage (source 'pb_import', one-day period, FIFO)
                  Unpost (owner) ─▶ unpost_pb_report ─▶ delete_feed_usage per row
```

- **Nothing is in the books until Approve.** Staging only parses and
  resolves names. `problems` block approval (unmatched pen or ingredient, no
  default bay, no lot standing in the pasture, a load whose drops and
  ingredients disagree, before the cut-over, on/after the truck cut-over,
  a lot already hand-entered for that day). `notes` do not block (PB manual
  delivery changes, PB head movements — neither is imported).
- **`ranch_settings.pb_email_post_from` is the cut-over** (2026-09-28).
  Earlier days are entered by hand; NULL means stage only, never post. It
  must stop before `feed_truck_post_from` once the truck takes over.
- **The browser does no arithmetic.** It lists `pb_report_list()` and calls
  the RPCs; every split is largest-remainder in SQL. An approve error lists
  every blocking problem and is shown exactly as the database wrote it.
- **Move vs Split by weight.** `pb_move_drop` sends a pen's whole drop to
  another pasture for that day (`pasture_override`). `pb_split_drop` takes
  `[{ranch, pasture, lb}]` that must add EXACTLY to PB's fed pounds for the
  pen — nothing is absorbed, a gap is PB's to fix — and rewrites that pen's
  drop lines. A pen fed on several loads splits load by load with the last
  load taking the exact remainder, so every pasture total is what was typed
  and every load still adds to PB's load TOTAL. Approve needed no change: a
  split pen is just more drop lines, and each line's pounds go to the lots
  in its pasture by head. PB's original figures stay in `parsed`/`raw_text`.
- **Re-staging the SAME gmail message is a no-op** (2026-09-25b). Staging
  deletes and rebuilds the lines, so the morning read seeing yesterday's
  email again would silently wipe every Move and Split. A DIFFERENT message
  for a pending day (PB resent a correction) still replaces it; an approved
  day is never re-staged.
- **Unpost is owner-only in fact, not just on screen**: it deletes
  `feed_usage` rows and RLS lets only owner delete them. The button carries
  `data-perm="owner"`.
- The Feed pane is office+owner (accountant reads it, `data-write` hides the
  buttons); crew never sees Approvals. The nav badge is field entries + PB
  pending, counted at sign-in by `apprRefreshCounts()`, not only when the
  tab opens.
- **A missing day shows after 9 AM Central** — the last 7 days since the
  cut-over with no report in any status. Before 9 the morning read may not
  have run. The link on each card opens the source email in Gmail by
  `gmail_message_id`.
- **The Redwing Feed/Mineral export picks rows by `usage_date`, with no
  `source` filter.** PB rows are one-day periods dated the feeding day.
  Weekly hand entries carry `usage_date = period_end` (the Sunday), so a
  whole hand-entered week posts in the range holding its Sunday; a range
  cutting through a week does not pro-rate it. The export pages all three
  reads (PB adds ~15 usage rows a day, and the all-history read feeds the
  roll-forward's opening balance), prints a tie-out against
  `feed_usage_detail`, and writes "N lines unpriced" as text beside any $
  that includes a NULL cost, so the flag survives Copy rows and the PDF.
  Lot sections take `destination_type = 'lot'` only, so a prefeed transfer
  into "Prefeed - <ranch> <pasture>" never shows as lot feed; the later
  `pbpre:%` rows that charge it to the first lot in are ordinary lot rows
  and do. **Roll-forward fix 2026-09-29:** it tested receipt sources
  `'transfer'` and `'batch'`, which `feed_receipts` never holds (the check
  constraint allows `purchase`, `count_adjustment`, `transfer_in`,
  `batch_out`, `opening_balance`), so every transfer-in layer (a bay move,
  a prefeed hold) and every batch output was counted as a Purchase. End
  balances were unaffected; the Purchases and Transfers columns were wrong.
  It now reads `transfer_in` / `batch_out`. Checked on the scratch copy
  after a 9/28 prefeed approve + 36-27 charge: Purchases 27,146.24 → 0,
  Transfers −27,146.24 → 0, lot sections 34,440 lb over 5 lots.
- Harness: see "Testing the Feed tab" below. The 09-25 canned-data harness
  (`run.js`/`fake.js`) was retired 2026-09-29 with the card rebuild.
- **PB changed the email layout in Sept 2026** (first seen on the 09-25
  report): "Your daily delivery report for <ranch> on MM-DD-YYYY", "Load 1
  1 Starter Deccox" with no parentheses, "Total a b - - -", and a Head
  Movement table. `pb_parse_2026_format` reads both layouts; tested end to
  end on the real 09-25 email 2026-09-26 (staged inside a transaction that
  raised, zero residue): 3 loads, pens Corner 7 / 4 / 1 resolved, every
  ingredient resolved, no problems but the cut-over. **A day with every Fed
  at 0 is normal**, not a parse failure: PB fills in fed pounds only on days
  the truck actually feeds, and in Sept 2026 only bulk feeders were being
  filled (John, 2026-09-26).
- **Names are matched, never mapped** (John, 2026-09-26: "I want no name
  mapping, I want to change anything to match"). `pb_name_aliases` stays
  empty; a PB name that does not match is fixed at the source, in PB or in
  our item/pasture name. `pb_norm()` (lower case, a-z0-9 only) is the one
  tolerance and John chose to keep it: it forgives spacing, punctuation and
  case, which cannot turn one name into a different item. The 09-25 email
  matched only through it on `CornFeed` / `Corrid Crumbles 2.5`; John fixed
  those names on the PB side the same day.
- **anon holds EXECUTE on none of the 14 PB functions** (2026-09-25c,
  2026-09-26b for `pb_norm`,
  `docs/sql/2026-09-25c_pb_revoke_anon.sql`). The first two migrations had
  left Postgres' PUBLIC default in place — rule 4 — and the revoke was
  applied the same day; its verify block raises if anon can execute any PB
  function or authenticated has lost one. Consequence: **the Cowork morning
  read must stage as a signed-in owner/office user or through the Supabase
  connector.** Calling `stage_pb_report` with only the publishable key is
  now refused.

### Prefeed ("first lot in pays") and the rebuilt Feed tab (2026-09-29)

Migrations, all applied live and pulled into `docs/sql/` verbatim:
`2026-09-29_pb_plan_exclude_test_lots.sql` (`pb_lots_standing` skips test
lots and lots closed before the day; `pb_plan`; `pb_report_charges`;
`pb_report_list` gains `charges`), `2026-09-29b_pb_prefeed_first_lot_in.sql`
(`pb_report_lines.prefeed`, `feed_prefeed_holds`, `pb_mark_prefeed`,
`pb_charge_prefeeds`, trigger `lpa_charge_prefeed`, `prefeed_waiting`, and
the approve/unpost changes), `2026-09-29c_pb_report_charges_prefeed_items.sql`,
and `2026-09-29d_pb_summary_prefeed_flag.sql` (approved by John 2026-09-29:
`by_pen[].prefeed`, and `pb_split_drop` keeps a pen's prefeed mark on the
lines it rewrites; before it, a split silently cleared the mark).

- **Prefeed** is for feed dropped in a pasture before the cattle arrive.
  Marking a pen Prefeed (`pb_mark_prefeed`) clears its "no lot standing"
  problem. On approve its pounds move as a transfer to the location
  "Prefeed - <ranch> <pasture>" and are recorded in `feed_prefeed_holds`
  (status `held`). When the first real lot is assigned to that pasture,
  trigger `lpa_charge_prefeed` charges the held pounds to it
  (`pb_row_key 'pbpre:<hold>:<lot>'`, status `charged`). Unpost reverses
  the charges, the transfer and the holds. A pen may not be marked Prefeed
  where lots are already standing; that shows as a problem.
- **The card** (laid out after the "Feed Approvals Mockup" artifact): date
  header with status, loads and ingredient pounds fed; problems in red
  (Approve disabled with "Fix the problem above to approve."); Pens (PB pen →
  our pasture, target, fed, fed %, "(moved for this day)", a "Prefeed - first
  lot in pays" chip, and a row of Move / Split / Prefeed-or-Undo prefeed
  buttons); Ingredients (unmatched in red); "Charges to" from
  `charges` (one row per lot with its items, then a Prefeed block per
  pasture: Will hold / Held - waiting for cattle / Charged to first lot in
  on <date>, then the total, and how many pounds have nowhere to go yet when
  the total is short of ingredient pounds fed); PB notes in amber; an action
  bar with Approve & post and Reject (reason inline, no pop-ups). Reviewed
  days collapse to one line and open read-only; an approved day shows the
  posted charges and, for the owner only, Unpost with a required reason.
- A banner lists `prefeed_waiting()` (pasture, pounds, fed date, days
  waiting, and any charge error in red).
- **Roles come from `current_user_role()`**, called at sign-in
  (`apprRefreshCounts`) and on every load of the tab: crew never gets the
  Feed tab, owner and office act, accountant reads, only owner gets Unpost.
- After every action the tab reloads `pb_report_list` and `prefeed_waiting`.
  The browser computes only display numbers: fed %, the split's running sum
  (Save stays shut until it ties; the database checks it again), and the
  "nowhere to go" difference between two RPC totals.
- On phones the tables wrap and scroll inside their own box, and every
  button, select and input in the pane is at least 40px tall. The app's top
  header (nav tabs and user badge) is wider than a phone on its own; that
  predates this tab.

### Testing the Feed tab

`scripts/pb-feed-harness/run-local.js` loads the real `index.html` in
headless Chromium and runs every RPC through psql against a **scratch local
Postgres** that holds the live PB functions and a snapshot of the ranch
(database `feed_base` with the real 9/28 email staged; `feed` is recreated
from it on each run). It never points at Supabase, so it can approve,
prefeed and unpost freely. It checks the 9/28 read path (2 pens, 7
ingredients, 34,440 lb, the Goat Hill problem in red, charges 7,293.76 lb to
37X / 37X-1 / 37X-F / 59X), roles (crew, office, owner), split's running sum,
prefeed on/off, approve (front lots 7,293.76, Goat Hill held 27,146.24, sum
34,440, the waiting banner), a stale office click showing the database's
refusal word for word, a 36-27 move into Goat Hill the next day charging
27,146.24 and clearing the banner, and Unpost putting every pound back
(every layer equal to the snapshot). It also checks iPhone and iPad widths
and saves screenshots.

### Cost centre drops (Cow/Calf Wip) — 2026-10-03

Some pastures hold the cow herd, not stocker lots (Nichols Front Trap, John 2026-10-02). PB feed
dropped there belongs on a cost centre — **Cow/Calf Wip** — the same destination hand-entered cow
feed already uses (`feed_usage.destination_type = 'cost_center'`). It never touches a lot's cost of
gain and lands in the Redwing export's cost-centre section. Migration
`docs/sql/2026-10-03_pb_drop_cost_center.sql` (applied); `2026-10-03b_pb_split_keeps_cost_center.sql`
(applied by John in the SQL editor the same day, md5 verified - a Split keeps the pen's cost centre).

- **Feed tab:** every pen row has a **Cost centre** button beside Move / Split / Prefeed. It opens a
  picker of active cost centres (`cost_centers.is_active`); saving calls
  `pb_set_cost_center(date, pen, name)`. The pen shows a "Cost centre · Cow/Calf Wip" tag and the
  button turns to **Undo cost centre** (`pb_set_cost_center(date, pen, NULL)`). "Charges to" lists
  the cost centre with its items between the lots and any prefeed, and the total includes it.
- **Per pen, per pending day**, like Move and Prefeed. A drop is a lot charge, a prefeed hold or a
  cost-centre charge, never two: setting a cost centre clears Prefeed and marking Prefeed clears the
  cost centre. Re-staging a different email for the day rebuilds the lines and drops it, as it drops
  moves. There is no standing pasture → cost centre setting yet; John asked for the button only.
- **Posting:** `pb_posting_plan(report)` replaced `pb_plan` for `approve_pb_report` and
  `pb_report_charges`. It is `pb_plan` plus a `cost_center_id` column; a cost-centre drop takes its
  whole share of each ingredient with no head split. Approve posts those rows as destination
  `cost_center`, source `pb_import`, key `pbmail:<date>:L<load>:<item>:cc<id>`, so Unpost backs them
  out with the rest of the day. A cost-centre drop needs no lot standing, is skipped by the
  hand-entered-double check, and an inactive cost centre is a problem. `pb_plan` is still in the
  database, unchanged and unused; see the connector note.
- **Supabase connector note (2026-10-03):** `apply_migration` and `execute_sql` stall for 60 s and
  apply nothing when the SQL contains `DROP` or `DELETE` — even a rolled-back `DROP FUNCTION` with a
  5 s lock timeout. That is why `pb_plan` was not dropped (its result columns could not change in
  place) and why `2026-10-03b` (Split keeps the cost centre; its body deletes the pen's old lines) is
  applied through the connector: John pasted that file into the dashboard SQL editor on 2026-10-03.
  Use the SQL editor the same way for any future change that needs DROP or DELETE. The full `rls_verify` script also contains `DELETE`; its assertions were
  run as separate selects.
- **Tested** on the scratch copy with the real 10/1 email (Corner 4 and Nichols Trap → Front Trap):
  Cost centre → 36-27 4,890 lb + Cow/Calf Wip 7,970 lb = 12,860 (the ingredient pounds); Approve posts
  `cost_center` 7,970 and `lot` 4,890, inventory down exactly 12,860; Unpost restores every layer;
  Undo cost centre brings the "no lot standing" problem back; Prefeed and Cost centre clear each other;
  a bad cost-centre name is refused; with 10-03b, a split keeps it on both pieces. The 9/28 prefeed
  numbers are unchanged (7,293.76 to lots, 27,146.24 held). `run-local.js` covers it in its fourth
  suite (template `cc_ui_base`: feed_base + `local/05_cc_seed.sql` + the 10/1 email staged and moved
  + the 10-03 migration).
- **Cow/Calf Wip** has no Redwing account or production centre filled in (`cost_centers`), the same
  as for the hand-entered draws John already makes against it.
- **Redwing: Feed Application + Cost centres is one sheet (2026-10-03, John: "both on one report so
  we don't have to check each one when we post").** Inventory → Reports → *Feed Application + Cost
  centres* shows the lot blocks for the Feed Application screen, then each cost centre's journal
  block (Cow/Calf Wip …), then "Feed posted this period": lots, cost centres, total. One Print / PDF /
  Copy covers all three parts; Copy rows marks the two parts with upper-case headings. The separate
  Cost centres menu entry is gone (an old pick of it opens this sheet). Mineral, Variance and the
  roll-forward stay separate. `run-local.js` suite 5 checks it on the approved 10/1 day: 36-27
  4,890 lb + Cow/Calf Wip 7,970 lb = 12,860 lb on one sheet and in the copied rows.
