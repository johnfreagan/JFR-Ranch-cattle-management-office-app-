# Inventory flow — order to receipt to invoice — design decisions

Thirteen decisions taken 2026-08-31 in one working session with John, reached in
dependency order. Each records what was decided **and why the alternative lost**,
because the reason is the part that stops it being re-litigated in six months.

**The problem.** Nothing in the app knows a product needs ordering, knows one was
ordered, or knows a bill is outstanding against a load already fed. A feed receipt
appears out of nowhere. Price per unit is known when the order is placed and weight
is known at delivery, but the invoice routinely arrives the following month — and
today that gap is carried by `cost_pending`, which makes the feed read **free**
until the bill lands.

**Scope.** Feed and meds share one ordering spine. **Feed is the live build; meds
join later** — John has a medicine inventory design ready and is rolling out one
module at a time. For meds the order document is largely optional: entry happens at
receipt, and the value of an "order" there is the reorder reminder.

Companion documents: `feed-design-decisions.md`, `commodity-feed-inventory-plan.md`,
`sql/2026-08-27_feed_inventory.sql`, `sql/2026-08-27_feed_phase4_premix.sql`,
`sql/2026-08-28_feed_decisions.sql`.

**Status:** wave 1 schema **APPLIED 2026-08-31** —
`sql/2026-08-31_inventory_flow.sql`. App code not yet built. Waves 2 and 3
decided, not built.

---

## The shape, in one picture

```
        reorder signal (derived: on hand vs floor / days of cover)
                    │
                    ▼  "Mark ordered" — one tap
   vendors ──▶ supply_orders ──▶ supply_order_lines
                                        │  (one line, many loads)
                                        ▼
                                  feed_receipts  ◀── THE FIFO LAYER, unchanged
                                  (order_line_id, invoice_id,
                                   costed at the ORDERED price)
                                        │
                                        ▼
                                  supply_invoices ──▶ tie-out
                                        │
                                        ▼  difference only
                                  feed_price_variance
```

Everything the office chases — low, ordered, overdue, delivered-without-a-ticket,
unpriced, unbilled, doesn't-tie — is **one derived list**, rendered three ways:
a sub-tab, a dashboard badge, and a 7am email.

---

## 1. One spine, two ledgers

### 1. Feed and meds share the ordering spine; each keeps its own ledger

`supply_orders` / `supply_order_lines` cover both. A line points at either a
`feed_items` row or a `medications` row (`item_kind` plus two nullable FKs and a
CHECK that exactly one is set). Receiving a feed line writes a `feed_receipts`
layer exactly as today; receiving a med line will write into whatever the med
design specifies.

**Why not two separate systems.** The reorder engine, the notification path and the
"waiting on paperwork" worklist would be built twice and would drift inside a
month. One screen answering "what do I need to order" for the whole ranch is the
actual thing being asked for.

**Why not force meds into `feed_items`.** A med would then need a FIFO bay, and its
price would live in two places — `feed_receipts.unit_cost_per_lb` and
`medications.cost_per_unit`. That is the processing-cost trap wearing a new hat.

**What they do NOT share: consumption and costing.** Feed draws FIFO per bay and
spreads over head-days. Meds draw per doctoring event with cost frozen per row,
and processing cost derives live off `medications`. Those stay apart.

### 2. Med inventory is out of scope here

John has it designed. This document does not specify it. The obligation this
creates: **when the med design lands, check it against the spine before building**
— specifically that `supply_order_lines` and `supply_invoices` take it with no
schema change, and that the reorder engine's input shape (decision 6) can be
filled from wherever meds hold on-hand.

---

## 2. Money

### 3. A delivered load is costed at the ORDERED price. The invoice difference goes
### to a two-sided variance account. Frozen dollars are never rewritten.

Delivered cost = ticket weight × ordered $/unit, at the moment of delivery.
`cost_pending` stops being the normal path and becomes the flag on an exception —
the unordered load, the vendor who would not quote.

When the invoice arrives and differs: the layer is corrected **going forward** (the
remaining pounds carry the true price) and the already-consumed difference is
booked to `feed_price_variance`. `feed_usage_costs` is never touched.

**Why not keep `cost_pending` as the norm (status quo).** Feed delivered 8/20 and
fed 8/22 reads $0.00 until the bill arrives in late September. Every closeout, cost
of gain and breakeven runs light for a month, and runs light **silently**, because
`SUM()` ignores NULL. That is the exact failure the feed module was shaped to
avoid; keeping it would be reintroducing it as the normal case.

**Why not restate the frozen usage costs when the invoice lands.** It is the option
that looks most correct and it reopens closed lots and prior fiscal years the same
way editing a drug price does. The whole reason feed cost freezes is to *not be*
processing cost. Restating makes it processing cost with a slower fuse.

**What the variance account earns.** Its balance is a live measurement of how well
agreed prices predict actual bills. A consistent drift is a freight assumption to
fix or a vendor conversation to have. Same argument already accepted for barn
shrink: a two-sided account whose balance is the accuracy of the estimate.

**The obligation this creates.** The ordered price must be captured at order time
or the whole thing degrades to the status quo. The order line's price field is
required, with an explicit "price unknown" checkbox — same shape as `cost_pending`,
for the same reason: **a blank price must never be an accident.**

### 4. `recost_pending_usage()` is unchanged and still guarded `WHERE cost IS NULL`

It fills holes. It does not move numbers. Decision 3 removes most of the holes; it
does not change what the function does with the ones that remain.

---

## 3. Orders and receiving

### 5. An order is OPTIONAL in the schema and LEADING in the screen

`feed_receipts.order_line_id` is nullable. The receiving screen opens showing the
open order lines for that item — pick one and item, bay, vendor and price all
pre-fill; or choose "no order" and type it by hand, which forces either a price or
an explicit `cost_pending`.

**Why not mandatory.** The mill drops a load nobody wrote down. A tote comes off
the back of a truck. A load arrives against an order placed by phone and never
entered. Under a NOT NULL constraint the only way to record any of those is to
back-date a fake order — and the moment people type fake orders to satisfy the
software, the order table stops meaning anything. It is the table the reorder
alerts read from.

**Why not simply optional with no guidance.** The entire benefit of orders is that
the screen knows what is coming, so receiving becomes "which of these three open
loads is this ticket?" instead of retyping four fields. That only materialises if
the screen leads with the orders.

**An unordered receipt is visible as an exception**, on the same list as a short
bay or an unpriced load. You find out how often it really happens instead of
guessing.

### 6. One order line takes many loads. A truck is weighed once.

25 ton of corn arrives on two trucks on two days; each ticket becomes its own
`feed_receipts` layer against the same line. The scale ticket weight is the truth —
same principle as `shipment_loads`.

**Over-delivery is allowed, flagged, never blocked.** Ordered 25 ton, 26.4 arrived.
Refusing to record it does not un-deliver the corn. Same rule as going short on a
bay.

**A line closes two ways**: automatically when received ≥ ordered, or manually —
"that's all they're bringing." The manual close matters more than it sounds: a line
that never closes sits in "waiting on delivery" forever and trains everyone to
ignore the list.

### 7. Receiving goes through an RPC, not browser statements

`record_feed_delivery(...)`, `SECURITY INVOKER`, doing the `feed_receipts` insert
and the order-line rollup atomically. Correct regardless, and it means a field-app
caller later (decision 11) is a caller and not a reimplementation — the same reason
`loadOpenPastureInventory()` is shared between Moves and shipments.

---

## 4. Reorder

### 8. An item is low when on-hand ≤ the GREATER of a pound floor and a
### days-of-cover point. Either may be blank. Blank means silent.

`reorder point = greatest(floor_qty, daily_burn × (lead_time_days + safety_days))`

**Why not a static floor alone.** 441 head landed on 36-27 in August. A floor that
is right with cattle on feed is wrong the week they ship and wrong again when the
next set arrives — and wrong in the dangerous direction, firing late exactly when
burn is fastest. Floors would need re-typing every time a lot moves, which nobody
does, so they go stale and the alerts get ignored.

**Why not days-of-cover alone.** Burn is not always observable. A new item has no
history. **Mineral in particular** has no feeding record at all — per the 8/28
decisions its consumption is discovered at count time and allocated by head-days,
so its burn is a monthly step function, not a daily read. A plain pound floor is
the honest trigger for items like that.

**Blank is silent, and that is a feature.** *2024 Corn Silage* is 1,553,425 lb in
the Terrell pile, is not being fed, and is a named reconciling item. It must never
raise a reorder alert. No opt-out flag needed — leave both fields blank.

### 9. The reorder point is per ITEM, ranch-wide. On-hand stays per (item, location).

Corn low in one bay and full in another is a transfer, not a reorder. The alert
reads summed on-hand; the detail shows the bay split. A per-location override gets
added if a second ranch ever needs one — not before.

### 10. Burn rate comes off the same daily curve the cost allocation uses

Trailing window over `lot_feed_daily`'s spread of usage across
`[period_start, period_end]` — **not** off `usage_date`. A weekly ticket entered
Friday is not a Friday spike. Window is `least(21, days since that item's first
usage)`; **days-of-cover is suppressed below 7 days** of history. Twenty-one days
because a week is too jumpy against weekly entry and a month lags a new set of
cattle.

**Why not a second implementation.** There are already two head-day
implementations in this schema that disagree by 29%. Not making a third.

### 11. The reorder engine reads ONE input shape, so meds plug in unchanged

`(item_kind, item_id, on_hand_qty, unit, daily_burn, lead_time_days, safety_days,
floor_qty)`. Feed fills it from `feed_item_on_hand` and `lot_feed_daily`. The med
design fills the same columns from wherever it holds on-hand, and inherits the
alerts, the notifications and the worklist for free.

---

## 5. Alerts without noise

### 12. The alert is DERIVED. Only "what you have already been told" is stored.

A view answers "is it low", computed fresh, never stale. Beside it, one small row
per item: `was_low_at_last_check`, `last_notified_at`, `snoozed_until`,
`snoozed_by`.

- **Notify on the transition into low**, not while it sits there.
- **Re-notify every 7 days** while still low. Setting lives in `ranch_settings`;
  John's call 2026-08-31, to be revisited if it proves wrong.
- **"Mark ordered" suppresses it.** One tap writes an order line for that item and
  the alert goes quiet. For feed you then fill in vendor, quantity and price — the
  row decision 3 needs to cost the load. **For meds you tap and stop**, and that
  zero-effort row is exactly the reorder reminder John described. Same mechanism,
  two amounts of effort.
- **Any receipt for an item auto-closes that item's reminder-only order lines** —
  the ones with no quantity. A med reminder raised in September closes itself when
  the box arrives in October. Nothing to tidy.
- **Zero on hand breaks through a snooze.** Snoozing says "I know, it's handled."
  Being out says the handling failed.

**Why not stored alert rows with a lifecycle.** A stored row can disagree with
actual on-hand — a bay gets counted, the item is no longer low, and an open alert
still says it is. Closing alerts becomes a chore, unclosed ones accumulate, the
list becomes meaningless. Same failure as an order line that never closes.

**Why not stateless.** The same "corn is low" every morning for a week is how a
system gets muted, and the one time it says *mineral* it goes unread with
everything else.

**Display rule that carries real weight:** low and on-order are different states
and both must show — `Corn · 6,200 lb · 3 days · ordered 8/28, due 9/2`. A screen
with only "low" and "not low" cannot tell you whether a thing is handled, so you
either double-order or assume it is handled when it isn't.

---

## 6. Paperwork

### 13. "Watch for the weight ticket" is DERIVED from the empty field, with an
### explicit dismissal — not a note somebody remembers to type

`ticket_number` null → *awaiting weight ticket*. `invoice_id` null → *awaiting
invoice*. Typing the number clears the row. Plus a per-receipt **"nothing further
expected"** checkbox recording who ticked it and when, and a free-text note field
for the colour no schema captures.

**Why not a note field alone** (which is how John first described it). It depends
on somebody remembering to create the reminder, and the load where that is
forgotten is the load that goes missing. A reminder you must remember to set is a
reminder for the days you did not need one. And it never clears itself, so the list
fills with stale notes and gets skimmed.

**Why not pure derivation.** Some receipts genuinely have no paperwork coming — a
`count_adjustment` has no invoice, a `transfer_in` has no ticket, and occasionally
a vendor never sends a separate ticket. Pure derivation nags forever on those,
which is the same death by a different road.

**`source` auto-exempts.** `count_adjustment`, `transfer_in` and the new
`opening_balance` never expect a ticket or an invoice.

**Rows age visibly.** *Awaiting invoice — 34 days* is a different fact from
*— 3 days*, and it is the number that tells you when to call the mill. Count
staleness already works this way.

### 14. The bill is matched as a document: tie out first, allocate only on a
### difference

`supply_invoices` — vendor, invoice number, date, total. Receipts point at it. You
pick the vendor, type the number, date and total; the screen lists unmatched
receipts from that vendor in a date window with each load's expected cost; you tick
the loads on the bill.

- **If the total ties, you are done in one click.** No per-load amounts typed, no
  variance, nothing booked. `invoice_id` lands on each receipt and the "awaiting
  invoice" rows disappear.
- **If it does not tie**, the difference is shown and allocated — default
  **pro-rata by pounds**, which is right for the overwhelmingly common cause
  (freight or a surcharge landing different from estimate); or actuals typed per
  load. Then decision 3 applies per receipt.

**Why not invoice number per receipt** (today's field). Nothing ever compares the
paper to the books; you would be typing into a field nobody reads.

**What the document buys that per-receipt cannot:** a line on the bill with no
receipt to tick is **a delivery that happened and was never recorded** — the exact
failure this system exists to prevent, and the per-receipt version is blind to it.
It becomes its own row: *invoice 88214 has a load with no matching receipt.*

**Named `supply_invoices`, not `feed_invoices`** — one bill can cover both once
meds are in.

### 15. This is NOT accounts payable

Redwing pays the bill and owns the payable. What is recorded here is only enough to
reconcile **inventory cost**: which loads a bill covered and whether the money
agrees. No due dates, no payment status, no aging, no check numbers. If that line
moves it should move deliberately, not because the invoice screen quietly grew.

---

## 7. The one list

Everything above surfaces in **one derived view**, rendered as a sub-tab, a
dashboard badge with the top few rows, and the 7am email. One definition, three
renderings, no drift.

| Row | Source |
|---|---|
| Low — reorder | new (decisions 8–11) |
| Ordered, overdue | expected date passed, nothing received |
| Received, no weight ticket | new (decision 13) |
| Received, unpriced | `feed_receipts.cost_pending` — exists |
| Received, invoice not yet matched | new (decision 14) |
| Invoice differs from ordered price | new (decision 3) |
| Bay short | `feed_usage.is_short` — exists |
| Premix short | `feed_premix_shorts` — exists |
| Count overdue | `feed_location_count_status` — exists |
| Unallocated feed cost | `feed_cost_unallocated` — exists |

Four of the ten already exist and are merely ungathered.

---

## 8. Delivery

### 16. The app writes to an OUTBOX. A sender decides how it travels.

`notification_outbox` — recipient, channel, subject, body, `send_after`, `sent_at`,
`error`. The reorder logic's only job is deciding what needs saying and writing one
row.

**Why the extra table rather than calling Resend inline.**
1. **A failed send must not be silent.** John's own rejection of carrier
   email-to-SMS gateways — "a blocked report and a quiet day look identical" —
   applies exactly here. An outbox row with `error` set and `sent_at` null is a
   visible failure; a fire-and-forget call is not.
2. **It is the machinery OPEN-ITEMS #7 already needs.** The automatic daily report
   is blocked on precisely this: a cron, a sender, a recipients table. Built once
   here, the daily report becomes "write a different row."
3. Switching email on later touches no reorder code; switching SMS on after that is
   another config change.

### 17. In-app now, email next, SMS last

- **In-app** — badge and panel, zero infrastructure, ships with wave 2.
- **Email** — Edge Function on `pg_cron`, sending via Resend's API. **Resend from
  an Edge Function is not Supabase's auth mailer**; OPEN-ITEMS #1's restriction on
  delivering auth email outside the org is real and irrelevant here. Sends to any
  address once the domain is verified.
- **SMS** — behind A2P 10DLC registration. Until then the share sheet is the path.

**Timing: 7:00am CT, pinned to `America/Chicago`.** The daily report is 6:30pm
because it is a recap; a reorder alert is a to-do and wants to land before you would
call the mill. Pinned to Chicago for the same reason `ranch_today()` exists — UTC is
already tomorrow after 7pm here, and a UTC cron drifts an hour twice a year.

**Content: the whole needs-attention list, not only reorder rows.** John's call.

**Blocked on John, not on code:** a Resend account with a verified sending domain,
and `pg_cron` + `pg_net` enabled in the dashboard. Both are available on the
project and neither is installed.

---

## 9. Who, and where

### 18. Office and owner only. Field-app receiving is deferred until it is needed.

The whole Inventory tab carries `data-perm="office"`. Crew cannot see it.

**Why not field-app receiving now.** It means a new `entry_type` in
`pending_field_entries`, a new approval handler, a new path in `rollbackPosted()`
and a field screen — roughly doubling the surface area of a week-one rollout, in
the one place where a bug is expensive, because the approvals batch is
all-or-nothing and posts to the books.

**And the safety net already exists.** The fear field receiving addresses is a load
arriving unrecorded. That is the *ordered, overdue* row: due Tuesday, it is
Thursday, nothing received. A paper ticket sitting in a truck for two days is caught
whether or not a cowboy can type it in.

**Rolled out if it becomes necessary** (John, 2026-08-31). Decision 7 keeps it
cheap.

**Permissions**, matching the rest of feed: office and owner read and write; crew
nothing; **owner-only DELETE** on orders, receipts and invoices. Deletes stay the
narrowest privilege — an order line deleted with a receipt hanging off it is an
unrecoverable break in the chain; an accidental insert is not.

### 19. `vendors` becomes a table

Seeded from the distinct values already in `feed_receipts`, so there is nothing to
type. Free text cannot support "call Producers Cooperative" on an alert or
filter-by-vendor on invoice matching — both need the string to be the same every
time, which free text never is.

### 20. The `Feed` tab becomes `Inventory`. Sub-tabs are FUNCTION; a material chip
### filters both content and which sub-tabs show.

Top-level tab count does not grow — `Feed` is renamed, not added.

**Feed chip:** Needs Attention · Orders · Deliveries · Invoices · On Hand ·
Feed Out · Batches · Counts · Cost · Items · Locations

Less additive than it looks: **"Loads In" becomes "Deliveries"** and today's
"Inventory" sub-tab becomes "On Hand", so four new screens go in and the row grows
by three. On the Meds chip it is seven buttons.

**Why not materials as the sub-tabs** (John's first framing). Orders under Feed and
Orders under Meds are two screens, and a vendor billing both on one invoice has
nowhere to file it — the thing decisions 1 and 14 exist to prevent. It also needs a
third navigation level the app has no pattern for outside lot detail.

**The rule the layout states:** sub-tabs are what you are doing; the chip is what
you are doing it to. Adding fuel or parts or vet supply later is a lookup row and a
chip, not a screen.

**Recording a delivery has two doors and one implementation** — the button is on
Orders and on Deliveries, both opening the same modal calling the same RPC. Nobody
should have to remember which tab receiving lives in.

**The medications catalog stays under Animal Health.** Name, dose, `round_up_to`,
price, protocol membership — a doctoring tool, read by protocols and the field app's
pickers. What comes to Inventory → Meds is the *stock*. One drug, two screens, two
questions. Link them later if it chafes; do not merge.

**The header tab reorder John is contemplating is a separate change** — not tangled
into this migration, so a misbehaviour is attributable.

---

## 10. Day one

Queried live 2026-08-31:

- **`feed_usage`: 0 rows. `feed_counts`: 0 rows.** 17 active items, 4 active
  locations. Feed-out entry begins with the 9/1 cut-over, so **days-of-cover cannot
  compute for anything until roughly 9/21.**
- **All 11 existing `feed_receipts` are the 8/30 PB opening balance** — vendor
  `(opening balance)`, no ticket, no invoice, `source = 'purchase'`.

### 21. The 16 opening-balance rows are repointed to `source = 'opening_balance'`

Under decision 13 they would each raise *awaiting weight ticket* and *awaiting
invoice* on day one and never clear. Sixteen permanent false alarms is how a new
list gets ignored in week one. `'opening_balance'` is added to the
`feed_receipts.source` CHECK and auto-exempts exactly like `count_adjustment`. Done
in the wave 1 migration, idempotent, with an audit note appended to `notes`.

**Sixteen, not eleven — found the hard way.** The count above was taken early in
the session; by the time the migration ran, the books held 21 receipts under
*five* different vendor strings, and the first run crashed on
`vendors_name_uniq`:

| vendor string | rows | what it is |
|---|---|---|
| `(opening balance)` | 11 | the 8/30 PB reseed |
| `(count adjustment)` | 3 | written by `post_feed_count` |
| `beginning inventory` / `Beginning inventory` / `Beginning Inventory` | 5 | hand-entered opening balances, three capitalisations |
| `Legacy Commodities` | 1 | a real purchase |
| `Double T` | 1 | a real purchase |

Two lessons worth keeping:

- **`DISTINCT` is not `DISTINCT ON (lower(...))`.** The seed deduped exact strings
  against a unique index on `lower(name)`, so three capitalisations of the same
  marker survived and the INSERT collided with itself. Any seed feeding a
  case-insensitive index has to dedupe the same way the index does.
- **A marker list written from one sample of live data will be short.** The quiet
  half of this bug was not the crash: it was that five hand-entered opening
  balances would have stayed `source = 'purchase'` and nagged forever. Their own
  notes identified them — *"Enter and price beginning inventory from RW"*,
  *"Unused at this time moved in from Redwing inventory."* The verify block now
  asserts that no marker became a vendor, so the next spelling fails loudly
  instead of quietly becoming a supplier.

**Verified after applying:** 16 repointed, 5 needs-attention rows, 2 vendors
(Double T, Legacy Commodities). The 5 rows are Legacy Commodities DDG 8/17
(awaiting invoice, unordered) and Double T SoyHull 8/20 (awaiting ticket,
awaiting invoice, unordered) — two real purchases with real paperwork
outstanding, which is the module doing its job on day one. All six tables carry
RLS with four policies, all three views are `security_invoker`, and `anon` holds
SELECT on none of them.

### 22. Pound floors carry September; days-of-cover switches itself on per item

Nothing to flip by hand — decision 8's `greatest()` has a burn half that evaluates
to nothing while history is thin, and a floor half that works from day one.

**Why not hand-seed a starting burn rate.** Seventeen guessed numbers producing a
confidently wrong days-of-cover, which is worse than none because it looks
computed. A pound floor is a number John actually knows.

**Why not wait for history.** The first three weeks of a new system are when it is
most worth watching, because no habits have formed and the barn compounds a mistake
daily.

**Floors get set once feed-out has run a week** and real burn is visible. Expected
to matter for corn, DDG, cottonseed, hulls, molasses and the mineral; the rest stay
blank.

---

## 11. Build order

### 23. Three waves, each with one question it answers

**Wave 1 — the paperwork spine (this week).**
`vendors`, `supply_orders`, `supply_order_lines`, `supply_invoices`,
`feed_price_variance`; `feed_receipts` gains `order_line_id`, `invoice_id`, ticket
and paperwork columns and the `opening_balance` source; `record_feed_delivery()`;
tab rename and material chip; Orders, Deliveries, Invoices and Needs Attention
(paperwork rows only). Costing at ordered price and the variance account land here
— they are inseparable from receiving.
*Question it answers: did the paperwork chain hold?*
**Testable the day it lands** — the first real delivery after the cut-over runs
order → ticket → priced layer → invoice → tie-out end to end.

**Wave 2 — reorder (about a week later).**
Floor and lead-time fields, the burn view, low rows, the notification-state table,
the outbox.
*Question it answers: is the computed burn rate believable?*
It goes second because it **cannot be meaningfully tested before then**. Building it
now means writing an alert engine against zero rows and learning three weeks later
whether the math was right; building it after a week of real feed-out means John
can look at corn's lb/day and say "about right" or "nonsense."

**Wave 3 — the 7am email (once the two dashboard chores are done).**
Edge Function, `pg_cron`, Resend, reading the outbox wave 2 already fills. Nothing
earlier changes.
*Question it answers: did it arrive?*

---

## 12. Open — John's, not code's

1. **The med inventory design** — hand it over before wave 2 so the spine is checked
   against it (decision 2).
2. **Resend account + verified sending domain.** Also closes OPEN-ITEMS #1.
3. **Enable `pg_cron` and `pg_net`** in the Supabase dashboard.
4. **Pound floors and lead times** for the six or so items that matter, once a week
   of feed-out exists.
5. **Header tab order** — separate change, on request.
6. **A2P 10DLC registration**, if and when SMS is wanted.

---

## 13. Conventions this build inherits

- Migration is idempotent, guarded, with `begin;`/`commit;` for the SQL editor
  (stripped if ever applied via the CLI).
- Every new table gets RLS **and** policies. Every new view is created
  `WITH (security_invoker = true)`. `supabase/migrations/20260821000300_rls_verify.sql`
  runs after.
- Nothing is GRANTed to `anon`.
- `record_feed_delivery()` is `SECURITY INVOKER`, like every other head-math and
  ledger RPC.
- Any direct data correction appends an audit note to the row's `notes`.
- Dates that count days use `ranch_today()` / `ranchToday()`, never `CURRENT_DATE`
  or `toISOString()`.
- Reads of any `lot_status`-shaped view check `error` — a wrong key returns
  undefined data and fails silently.
- After app edits: `osascript -l JavaScript scripts/validate.jxa.js index.html`
  must pass both checks before shipping.
