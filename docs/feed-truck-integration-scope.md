# Feed truck: design record (interview of 2026-09-04)

**Status:** Twenty-one decisions taken by John in one sitting. **Phase 1
BUILT 2026-09-04** (migration `sql/2026-09-04_feed_truck.sql`, office screens
under Inventory → Truck ▾). **Phase 2 BUILT the same day** (`feed-app/`, see
its README for the scale bridge contract). Phase 3 (Flutter shell) designed,
not built; waits on the Apple developer account. Performance Beef stays in use for ration, bunk call and truck-scale
capture until the tie-out (D17) holds and a cut-over date is set.

**Phase 1 note on posting (refines D11):** a load posts what left the bays
(its lines) over the lots it dropped to, pro-rata by dropped pounds. Left-in-box
is charged to that load's lots; the next load draws less because Distribute cut
its targets. See the migration header and CLAUDE.md "Feed truck".

Earlier scoping (sizes, Scale-Tec template, why native is now cheap) is at the
bottom under "Sizing history".

## Hard rules John set

- **Straight to Bluetooth. No hand capture of weights.** The scale is the only
  source of pounds; humans may override a captured number, never type one first.
- **Nothing advances without a tap.** No auto-advance on stable weight, ever.
- **No feed until mixed.** The drop screen is LOCKED until the ration's mix
  timer reaches zero. No override.
- **Parallel with PB first, cut over later** (D1).
- **Simple and efficient.** Every screen is PB's, slimmed.

## Decisions

### D1. Parallel run: truck pounds never touch the books until cut-over
Truck loads and drops land in their own tables (`feed_loads`, `feed_drops`,
`feed_drop_lots`) and never write `feed_usage` while PB's Monday entry is still
being posted. A ranch-level **cut-over date** flips it: loads on/after that date
post; the weekly PB entry screen warns past it. Same shape as the 9/1 barn
cut-over.

### D2. Ration = percent as-fed per ingredient, in load order, plus mix time
New `rations` / `ration_lines`. `feed_recipes` is not reused: it must produce a
premix item, a ration produces nothing. A line = `feed_item_id`, `pct_as_fed`,
`load_order`, `default_location_id` (D11). The ration carries `mix_minutes`
and `max_load_lb` (D6/D14). One ranch-wide tolerance percent; PB's loading
screen turns yellow inside it and red at zero, copied as-is. An ingredient can
be a premix item batched earlier.

### D3. Bunk read first thing, then the truck runs. Own pages and setup.
Per pasture the call is **as-fed lb/hd × head standing there** (all lots in the
pasture combined — a bunk feeds a pasture). **Bulk feeder** pastures are total
pounds. Setup page per pasture: feeder type (bunk / bulk), ration (change is
date-stamped — that is a step-up), route order, active.

### D4. Bunk read records score + lb/hd, prefilled from yesterday
Score 0–3 one tap; lb/hd with −/+ stepper (quarter-pound, hold to run, tap to
type). Pasture total and head shown, never typed. Bulk feeders: total-lb box,
no score. Saved with date so history shows what the bunk looked like against
what was delivered the day before. Dry matter, DMI, BW%, breed, sex, death loss
from PB's page are dropped. Two charts reserved at the bottom (D18).

### D5. One feeding a day, occasional second run, rare third
One call per pasture per day, one ration per pasture. A second (or third) run is
another drop record against the same day's call; the day's delivered is the sum.
No drop slots, no per-drop ration.

### D6. Planner: balanced loads, route order from the bunk reader, driver override
Loads needed = ceil(total ÷ cap); each sized total ÷ count. Walk route order:
fits → whole; split-OK pasture that doesn't fit → remainder now, rest opens the
next load; **one-pass pasture** (setup flag: hard to drive through the cattle
twice) that doesn't fit → close this load early. Minimum split pounds is a
setting. Route order is editable on the bunk page by the reader; the driver may
move a pasture between loads on the plan screen without changing the saved
route. Plan is proposed, never enforced. **A call is frozen into a load when
loading starts on that load**; until then the bunk read may change and only
not-yet-started loads re-plan.

### D7. Loading: head stays in gross, Done tap per ingredient, no auto-advance
The app never sends Tare while loading; each ingredient = rise in gross since it
was selected, so cab indicator and iPad agree and a missed Tare cannot wreck a
load. Driver taps **Done** on each ingredient; overshoot is recorded as loaded,
not clipped, with over/under per ingredient on the load. **Timer starts on the
last ingredient's Done.** Tiles can be tapped to load out of order.

### D8. Mix timer: hard block
Countdown after last Done, chime at zero, keeps counting elapsed. Drop screen
locked until zero. Load stores mix start, ration mix time, first drop time.

### D9. Drop = fall in gross between Start and Done, per pasture
Next planned pasture highlighted, any can be tapped. Start reads gross, countdown
to the pasture target (same colours), Done reads gross. Actuals recorded, never
targets; plan re-shows box remaining vs still owed. No GPS pick, no auto-detect.
**Distribute** (PB's meaning, confirmed by John): leftover stays in the box and
the next load of the same ration cuts every commodity target proportionally so
the box ends at its planned total. Leftover is assumed at its ration's own
percentages; if the next load is a different ration it still carries and counts
at the old mix, shown on the plan as "N lb of <ration> in box".

### D10. Which lot: pro-rata by head, stored per drop
Split across the lots on the pasture's open assignments that day, largest-
remainder, one `feed_drop_lots` row per lot. Read later, never recomputed.

### D11. Bays: default on the ration line; composition frozen on the load
Tile shows the bay, tap changes it for this load only. Load stores per
ingredient actual lb + bay. Commodity-by-lot rows are COMPUTED at posting from
the load's composition × drop lb × lot split and frozen in `feed_usage`; nothing
stored per drop per commodity. The tie-out (D17) does the same computation live.

### D12. Posting: auto, no Approvals; editable until posted; unpost to edit after
Truck writes only `feed_loads` / `feed_drops` (no dollars, crew-safe). RPC
`post_feed_load` → `post_feed_usage` per commodity per lot, FIFO, frozen cost.
Office app calls it for unposted loads **from prior ranch days** whenever the
Inventory tab opens (one-day grace: today's loads stay editable in the cab).
Before posting the truck may move a drop to another pasture or retype its
pounds; `scale_lb` is kept beside `lb` with who/when/reason. **No deleting a
drop, no cancelling a load**: a wrong drop is moved or set to 0 lb with a
reason; a load that ends early is closed with what it did and the rest is
left-in-box. After posting the truck sees the load locked; office **unpost**
reverses via `delete_feed_usage`, reopens the load, rows stay, re-posts next
morning. Void exists for a load that never happened (office/owner).

### D13. Hardware: two trucks, two Scale-Tec heads, none on the loader
Setup maps head id → truck name. Shell remembers the last head, reconnects
direct-by-id with scan fallback (Scale-Tec core); picker with live weight only
when both are in range. **Zero from the iPad is guarded**: if the app believes
leftover is in the box it asks first. Load records head id and link state at
each Done.

### D14. Load cap: on the ration, optional capacity on the truck, smaller wins
Trucks are different but similar; the driver picks the truck on the plan screen
and loads re-cut.

### D15. Signal: good at the barn, spotty in pastures
Everything for the day is pulled once at loading (calls, plan, ration, bays,
head per pasture); the barn is the one place signal is required and the app says
so if it can't sync there. Every Done writes locally first, client-id upsert.
Bunk read needs signal to save and says so. Two trucks = two plans.

### D16. Roles, and a SEPARATE feed app
Crew included on bunk read and truck; rations, setup, trucks, settings, unpost,
void and the tie-out are office/owner. Load history in pounds is visible to
crew. **A third PWA, `feed-app/`**, beside `field-app/` and `tally-book/`: same
sign-in, same queue pattern; keeps the field app uncluttered — cowboys
generally don't feed. The Flutter shell hosts this app.

### D17. Tie-out vs PB: lb per lot per commodity per PB week
Office app → Inventory → "Feed truck tie-out", beside the weekly entry. Truck
computed pounds vs typed PB rows, difference and %, green/amber on a set
tolerance. Second line per lot: head-days fed vs head-days on the books.

### D18. Reporting v1: three views, then "a complete set of feed metrics"
Bunk page: delivered lb/hd and score, last 15 days. Feed app: load history
(ration, truck, total, mix honoured, left in box; ingredients target/actual/
over-under; drops target/actual/edits). Office: daily feed by lot, lb and
lb/hd/day, dollars from existing lot feed views after cut-over; anomalies for
over-tolerance ingredients, skipped mix, short loads, human overrides. Parked by
name: DMI, 7am feeding email, cost per lb gain from actual feed. John wants the
full metric set once running.

### D19. Build order
1. SQL + office side (setup, tie-out, posting/unpost/void RPCs, settings).
2. `feed-app/` in the browser with a **simulated scale** (slider) so every
   screen is worked end to end on any iPad/iPhone in Safari before a truck.
3. Flutter shell: Scale-Tec template + WebView + bridge. Dart written here;
   **iOS compile/sign/upload needs a Mac with Xcode and John's Apple login**
   (Claude Code on his Mac, or four commands handed over). Android needs none.
4. Parallel run until D17 stays green → cut-over date.

### D20. Apple: individual developer account in John's name, started this week
Approved in days, enough for an unlisted App Store app. Organization enrolment
(D-U-N-S, weeks) rejected. Xcode onto the Mac the office app is validated on.

### D21. Same person loads and drives; the device rides in the loader cab
iPad, and **often iPhone — John's preference**. Screens are phone-first: big
countdown, ingredient strip scrolling under it; iPad gets room. Live weight off
advertisement packets is exactly the loader-cab-reads-truck-scale case. One
Flutter build for iPhone and iPad.

### D22. Two orders; drag with a lock; PB screens (2026-09-05/06)
Bunk reading order and feed route order are separate columns on
`pasture_feed_setup` (`read_order`, `route_order`); crew may drag either from
the feed app (trigger-guarded), office drags either under Pastures & route.
Every reorder is drag-and-drop behind a lock button. Ration lines: drag to
reorder, no bay column. Bunk page: one pasture per page, arrows, reading order
down the side. Plan page: PB's Delivery overview (load card, pens Target/Fed,
Total, feed Target/Loaded).

### D23. SDSU bunk calling with a fast/slow rule (2026-09-06)
Scores 0, ½, 1, 2, 3 per SDSU (Pritchard). Ration carries dry matter % and
expected DMI (lb DM/hd/day). Below expected intake: bump after 2 clean days
(0 or ½) by 0.75 lb DM; at or above: after 3 clean days by 0.5 lb DM (SDSU's
0.25-0.75 band). Score 1 holds. **Cuts became PERCENTAGES the same day** (John: "I want to
cut percentages, 3 usually means a big cut") - score 2 −10%, score 3 −25%
of yesterday's call, because a cut is proportional to what the pen was
offered while a bump closes a gap to a target intake in pounds. SDSU
publishes the DIRECTION (increment 0 and ½, hold 1, decrement 2 and 3),
not the magnitude; the magnitude is the yard's. All six numbers on
Truck › Settings. The app applies the suggestion when the score is tapped,
shows the reason and a DMI bar, and records suggested vs called.
Sources: SDSU Extension "Feed Bunk Management"; Feedlot Magazine "Scoring for
better bunk management"; Drovers "Feed Bunk Management"; UNL BeefWatch.

### D24. Intake off estimated weight, weather beside consumption (2026-09-06)
John: "ration should have a expected dry mater intake but software sets dry
mater intake off estimated weight as it increases vs the expected daily gain",
and "defenintly want a weather included and tracked to compare against
consuption."

- **Expected DMI is now a PERCENT OF BODY WEIGHT on the ration**
  (`rations.expected_dmi_pct_bw`), turned into pounds against each pasture's
  head-weighted estimated weight from `lot_status.projected_current_weight`
  (weight in + target ADG x days on feed). The target therefore climbs every
  day the cattle grow, which a flat lb/hd could not do. `expected_dmi_lb`
  stays as the fallback for a lot with no weights yet, and the screen says
  which basis it used. The call itself is unchanged: the bump rules from D23
  compare today's DM intake against this number.
- **Weather is pulled per ranch day and stored** (`daily_weather`, one row per
  date, from Open-Meteo - free, no key, no account), the last week plus two
  days ahead, refreshed by the feed app at the barn where there is signal. It
  is a table and not a display call because the point is to read consumption
  against it later; a forecast that is never stored cannot be compared with
  what the cattle actually ate. `ranch_settings.ranch_lat/ranch_lon` carry the
  location (defaults are Kosse).
- **The bunk page gained the trend matrix from John's research**: six days of
  weather, pounds actually delivered (from the drops, not the call), lb/hd,
  score and head, with today on top. A day that was called but never dropped
  prints the call in grey with an asterisk, so a skipped pasture is visible.
- **Quick adjust is a percentage of YESTERDAY'S call**, not of today's edited
  number, so tapping twice cannot compound. -10/-5/-2/Hold/+2/+5/+10.
- **The 10% shock guardrail asks once, at save**, naming every pasture whose
  total moves more than a tenth from its own last three days. It catches an
  extra zero, not a considered bump, and it does not block.
- **Flags and a note** (mud, sick pull, waterer, storm) sit on the read, so the
  reason a call looks odd is recorded beside the call rather than remembered.
- Not built: the two charts under the trend matrix, and the consumption vs
  weather report itself - both want a few weeks of real reads first.
- The three-strike slick escalation in John's research is deliberately NOT
  built: the fast/slow rule from D23 already bumps on consecutive clean days,
  and a second escalation ladder on top of it would fight the first.
- Automatic head-count adjustment already happens: every call and every drop
  split reads the open assignments that morning, so a death or a sale moves
  the pounds the next day with nobody typing anything.

### D25. Bulk feeders: call, mix, deliver by allocation (2026-09-06)
John: "Right now we go to pastures that need feed, enter amount usually two
mixers of 17,500 go into grain cart for delivery, feeders hold around 10000
#s of current bulk feed rations." No scales on the cart; "will call feed and
allocated the actual mix prorated against the call." One bucket per pasture.

The shape is the buyer's write-up again: **weighed once, split by declared
shares, sums exactly.** The mixer scale is the only weight in the chain.

1. **Call.** Bulk pastures are called in pounds on the days they are fed -
   10,000 / 8,000 / 7,000 - not scored, and not called every morning.
2. **Mix.** Each mixer batch is an ordinary load: ingredients weighed against
   the countdown, mix timer, hard block. Two 17,500 batches is two loads.
3. **Deliver.** Nothing is weighed at the feeder. The load's ACTUAL mixed
   pounds (sum of its lines) allocate across the pastures actually delivered,
   **pro-rata to the call**, largest-remainder so the parts sum exactly to
   what left the barn. Call 25,000, mix 25,400, and every feeder carries its
   share of the extra 400.
4. **Then it is an ordinary drop:** pasture to lots pro-rata by head, posted
   through `post_feed_load` unchanged. Head math and cost of gain need no
   special case, which is the whole reason for allocating into the existing
   drop rows rather than inventing a parallel ledger.

Decisions inside it:

- **The cart is not an entity.** It holds no cattle, has no scale, and every
  pound in it is already accounted for by the mixer. Modelling it would add a
  vessel that only ever restates the load. Feed that comes home in the cart
  uses the leftover the box already has (`left_in_box_lb` /`carried_in_lb`),
  labelled "left in cart" on a cart run; it is an ESTIMATE and is flagged as
  one, because nothing weighs it.
- **A drop records HOW it was measured** (`feed_drops.method` = `scale` |
  `allocated`, with `called_lb` beside it). Looking back at a number, you
  must be able to tell whether a scale said it or a rule did. This is the
  same instinct as `scale_lb` sitting beside an edited `lb`.
- **`feed_loads.delivery_mode`** = `direct` | `cart`. Explicit, not derived
  from "are all its drops bulk pastures" - the truck screen runs a different
  flow and history has to say which one happened.
- **A pasture the driver skips is excluded from the allocation**, and its
  share goes to the pastures that were actually filled - because the cart did
  empty into them. If it came home part full instead, that is the leftover.
- **Bulk pastures come off the daily bunk read** and onto a short list of
  feeders with their last fill, pounds and days since. A feeder filled every
  week or two does not want a call every morning.
- **`pasture_feed_setup.feeder_capacity_lb`** (total across the feeders in
  that pasture) so a call that overfills what is out there can be flagged,
  and a mix that lands more than 10% off the total call asks once before it
  allocates - the same shape as the bunk shock guardrail. Both catch the
  case where a feeder physically could not take its share while the books say
  it did.

**Next, not now:** empty-date estimate and a refill notice. Pounds delivered
over (head x lb/hd/day) gives days to empty, and the burn rate can be learned
from how long the last fills actually lasted rather than assumed. It becomes
a row on `inventory_needs_attention` - *Corner / 4 - filled Sep 2, about 3
days left* - and rides the notification outbox the 7am email needs anyway.
Deliberately after the first few real fills, so the rate is calibrated
against something instead of guessed.

### Stated assumptions (not asked)
Settings card: tolerance %, minimum split lb, tie-out tolerance %, cut-over
date. Bulk feeders: total lb, no score. A third feeding is a third load. Head
for call and split = open assignments that morning, cached at the barn.

## Tables (new)
`rations`, `ration_lines`, `pasture_feed_setup`, `feed_trucks`, `bunk_reads`,
`feed_loads`, `feed_load_lines` (ingredient actual + bay), `feed_drops`,
`feed_drop_lots`, `daily_weather`, plus the truck, bunk-rule and
location settings on `ranch_settings`. RPCs:
`post_feed_load`, `unpost_feed_load`, `void_feed_load`. All views
`security_invoker`; crew INSERT/UPDATE on the truck tables only;
`rls_verify` run after.

---

## Sizing history (2026-09-04, earlier the same day)

- Scale-Tec publishes an MIT Flutter template with the BLE protocol PDF
  (Point `Point-`, Core `SJB-`); live weight off advertisements, GATT gross
  stream, Zero/Tare/Gross/`tareStopWithRecord`. Reverse-engineering risk gone.
- iPad rules out the browser for Bluetooth (WebKit); native is now a THIN SHELL
  (template + WebView on the feed app + JS bridge), not a second app.
- Sizes: feed app ~5 build-days; shell ~3 + a day in the cab + Apple admin;
  full native rewrite 15+ (rejected). Android tablet / Web Bluetooth option
  dropped — the shell covers Android on the vendor's supported path.
- Risk: WKWebView runs the service worker only for `WKAppBoundDomains`; test on
  a real iPad in a pasture with no signal before the truck depends on it.
