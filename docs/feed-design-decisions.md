# Feed inventory — design decisions

Twenty-five decisions taken 2026-08-28 in one working session with John, reached
in dependency order. Each one records what was decided **and why the alternative
lost**, because the reason is the part that stops it being re-litigated in six
months.

Companion documents: `commodity-feed-inventory-plan.md` (the original design and
reasoning), `sql/2026-08-27_feed_inventory.sql` and
`sql/2026-08-27_feed_phase4_premix.sql` (what is built).

**Status:** decided, not yet built. Section 8 lists what changes.

---

## 1. Foundations

### 1. The office app is the system of record for feed on hand

Bays get counted and the count is truth. PB supplies usage pounds only. Redwing
receives our dollars.

**Why not PB or Redwing.** PB's inventory screen carries four negative
quantities; Redwing carries Salt at −5,457 lb with **+$1,999.18** of value and
Corn Silage 2026 at $19,154.60 with no quantity at all. Both are impossible for
a physical commodity — they are what a system produces when it tracks
consumption but not custody. The app is the only one of the three that
structurally cannot produce them, because it consumes named layers and flags
when it runs out.

**The obligation this creates.** Counts have to actually happen. Everything in
section 2 exists to keep that promise.

### 2. Many app items map to ONE Redwing template box

`feed_items` gains a template-field key. Several items may point at the same
Redwing box; the export sums them. Every item names exactly one box.

**Why not one item per box.** This reverses earlier advice to merge "Corn" and
"Corn hopper bin" because Redwing has a single `Corn $` box. **PB encodes the
bay in the commodity name** — that is the only signal telling the import which
pile was fed, and with two crop years at two prices in two bays it is not a
rounding difference. Merging to satisfy Redwing would destroy the one piece of
information the import depends on. Redwing has no concept of a bay and never
wanted the split.

---

## 2. Shrink, counts and the variance account

### 3. Silage shrink is haircut at ENTRY, not discovered later

Book gross chopped × (1 − allowance) as the FIFO layer, holding the full harvest
cost. $/lb rises on day one and every pound fed carries its share of the shrink.

This is already John's practice; it had not been named. It means **no
revaluation mechanic is needed** — the earlier `cost_basis` proposal (hold total
cost, recompute $/lb at count time) is dropped. The haircut happens at the one
moment there is real information.

### 4. Calibrate on GROSS, never on booked

The receipt stores three figures: **gross chopped**, **allowance %**, **booked**
(= the layer). Actual shrink is `(gross − total fed) / gross`.

**Why it matters.** If booked tonnage was already haircut by last year's
estimate, the end-of-pile residual is the *error in the estimate*, not the
shrink. Calibrating on booked compounds each year's error into the next and the
allowance drifts off reality with nothing showing it.

### 5. Barn shrink goes to a two-sided variance account, never to a lot

**Why not to lots.** Shrink is discovered at a bay-zeroing event, a date with no
relationship to which cattle were on feed. Charging it to whichever lot is
standing there hands one set of cattle six months of everybody's shrink —
arbitrary, and it destroys lot-to-lot comparison.

**Why a variance account and not an expense account.** A plain shrink expense
account only grows and says nothing. A variance account **should hover near
zero**: drifting up means the allowance is too low, down means too high, and the
balance is the accuracy of the estimates. That signal only exists if both
directions land there (see 8).

### 6. Do not build allowance machinery for barn commodities yet

Zero the bays a few times, watch the account, then decide.

**Why.** For a scale-ticketed purchased load, haircutting quantity at entry
**breaks the tie to the invoice and to Redwing** — the exact gap the tie-out
work is closing. Silage gets away with it because there is no invoice to tie to.
Doing it to a load of DDG costs the reconciliation to buy a number nobody has
measured.

### 7. Track shrink BY COMMODITY from day one; make the haircut switchable per item

Per-item default allowance %, null everywhere except silage. Turning a commodity
on later is a settings change, not a migration — at which point its shrink is
baked into cost of gain the way silage's already is.

Premix is the first candidate after silage: it carries more shrink from
handling, and a batch has a known input weight and a known output weight, which
makes it the cleanest test case.

### 8. Found feed is a count, priced at the bay's own last cost, credited to the same account

Book says zero and the bay is not empty: type the estimate into the count sheet.
`post_feed_count` creates a receipt for the difference at the last known cost
**for that item in that bay** (falling back to any bay). Nothing is ever free.

### 9. Silage over-recovery is left standing rather than revalued

Over-haircut a pile and it runs long; the found feed books at the pile's $/lb
and cattle are over-charged. On an 8.2M lb chop haircut to 6.9M and actually
feeding 7.4M, that is **$10,994 on a $166,820 pile** — fractions of a cent per
head-day, spread over everyone who ate off it.

**Why not build an exact revaluation.** That $10,994 sitting as a credit in the
variance account *is* the signal: the allowance was too high by about 6.6%, here
is the dollar size, use it next year. Making it exact trades a readable signal
for a silent correction, and reopens rewriting cost after it froze — the
processing-cost trap.

### 10. Overdue counts are flagged per bay, never blocked

Target interval per bay (~90 days for the barn, "at pile close" for silage).
Days since last count on the Inventory tab; overdue bays on Anomalies.

**Why not block usage from an overdue bay.** Refusing does not un-feed the
cattle — same principle that made going short a flag. And it would stop the
office on a Monday over a bookkeeping deadline.

### 11. The count sheet needs a "bay is empty — zero every line" action

The modal today says *"anything you leave blank is skipped — not treated as
zero."* Right default for a normal count, **wrong for the workflow John actually
runs several times a year**: walk up to an empty bay and declare it empty. A
skipped line means that commodity's shrink is silently not captured, the book
balance survives, and FIFO keeps drawing on feed that is not there.

### 12. A count on a bulk bay is labelled an estimate

The location already knows it is bulk. The count line says so and the resulting
adjustment is tagged estimated rather than counted, so the variance account can
later be read for which entries were a tape measure and which were a look.

### 13. How shrink actually surfaces — corrected

Physical **less** than book means the bay **runs empty while book still shows
pounds**. You never go short; you just cannot get it to zero, and the residual
at physical-zero *is* the shrink, per commodity. Going short is the **opposite**
signal — physical more than book, which means a delivery was never entered.

Two different problems. The module handles both correctly today.

---

## 3. The 9/1 boundary

### 14. Cut over 2026-09-01. No backdating.

August and prior stay on the cost allocation. From 9/1 every lot charges actual
feed directly, and feed comes out of the allocation.

**Why not backdate to 36-27's arrival (8/11).** Would require grossing the
opening quantities back up and entering the window's usage **for every lot**,
because the bay is shared. Considered and declined; 36-27's first twenty days
stay on the allocation.

**Rejected outright:** back-dating the opening quantities but skipping the
usage, letting the count absorb it. That manufactures three weeks of feeding as
a fake shrink number into the variance account on its first cycle.

### 15. `feed_direct_from` is a RANCH-LEVEL DATE, not a per-lot flag

The closeout splits every lot's head-days on it: days before charge
`assumed_cog_per_day` unchanged; days on or after charge
`assumed_nonfeed_cog_per_day` plus actual feed.

**Why not the per-lot switch phase 4 shipped with.** That switch has no date and
rewrites a lot's **entire life** retroactively. Setting it on 36-27 on 9/1 would
re-price August from $2.00 to ~$1.00/head/day with no actual feed to replace it
— about **6,441 head-days**, roughly **$6,400 of August cost of gain
evaporating** on the one lot this was built to measure.

Build the split so it is not feed-specific: roadmap item 4 has eighteen cost
categories and every one will eventually make this same move.

### 16. The 9/1 cut-over covers the BARN ONLY

Silage is not currently being fed, so it is not on the clock. It stays in
Redwing untouched and is reconciled before the piles are opened.

| | Redwing | App | Gap |
|---|---|---|---|
| Barn commodities | 1,279,352 lb · $138,543.57 | 1,219,029 lb · $116,961.06 | **$21,582.51** |
| Silage 2024/25/26 | 8,158,760 lb · $225,155.27 | 1,553,425 lb · $45,111.46 | *deferred* |

Feed RM 118004 holds both, so the account will not tie to the subledger. That
leaves one **named reconciling item** — "corn silage, $225,155, not yet in the
subledger" — which is a normal, defensible state for a control account. An
unexplained $21K variance is not. A footnote in place of a mystery.

### 17. A missing `assumed_nonfeed_cog_per_day` charges ZERO and warns loudly

On the lot and on Anomalies.

**Why not fall back to the full assumed rate.** That silently double-counts
against actual feed — the exact overlap the 9/1 date exists to remove. A zero is
visibly incomplete; a double-count looks fine.

Filling them in is mostly not a judgment call. Lots with no commodity feed keep
their existing rate, because it never contained commodity feed:

| lot | assumed COG now | non-feed rate |
|---|---|---|
| 36-27 | 2.00 | ~1.00 — the delta *is* the feed assumption |
| 37X · 37X-1 · 59X | 1.00 | 1.00 (unchanged) |
| 37X-F | 0.75 | 0.75 (unchanged) |
| **47-26 · 60X** | *none set* | **needs a number from scratch** |

---

## 4. The weekly operation

### 18. Monday hand entry from PB reports; assigned to LOTS, not pastures

A PB API is in the works; phase 3 becomes an import path added later, not a
dependency. The entry screen has to be good enough to live on for months.

Charging to lots rather than pastures **retires the `pasture_feed_allocation`
risk** — it leans on `lot_pasture_assignments`, which this app does not trust
for whole-life head-day math.

### 19. Batches post before usage within a Monday entry

Premix is entered first, then drawn down. Same shape as the approvals rule where
doctoring posts before deaths and moves. Enforced, not trusted.

### 20. Premix is recorded at mix time; a premix short gets its own anomaly

`make_feed_batch` consumes the ingredients FIFO and lays one premix layer.

**Why it needs a distinct anomaly.** A commodity going short means a delivery
was missed — one error. A premix going short means **the ingredients are still
sitting in the bay book** — two errors, opposite directions, and the feed still
allocates cleanly so nothing on screen looks broken. That is exactly how PB
reached **−1,109,171 lb** of RTU Silage Premix 2025.

Premixes are dormant (that figure is historical from the 2025 silage season), so
the anomaly sits armed rather than working on day one.

**Rejected:** reconstructing batches from PB usage and a recipe. Recipes only
pre-fill — a recipe read at cost time rewrites what every past batch was made
of.

### 21. Overlapping periods: one summary warning now, a period table with the API

Hand entry has no protection against entering 9/1–9/6 and then 9/1–9/13 — four
days feed twice, the dollars allocate cleanly, every screen balances, and the
only symptom is a cost of gain quietly too high.

It cannot be a uniqueness rule: the same lot fed the same corn out of two
different bays in one week is legitimately two rows.

**Decided:** the overlap check runs **once on the save of the whole weekly
entry** — one summary naming the rows and lots, not one dialog per row, since
the real failure mode is a whole week re-entered and forty warnings is the same
as none. When the API lands this becomes a recorded-period table, and the same
query it uses today carries over.

---

## 5. Cost of gain

### 22. Per-pound is a DISPLAY metric and an input convenience — never a projection driver

Accrual stays on head-days: feed is fed daily and from 9/1 those are real dollars
out of the module. You cannot accrue per pound of gain because the gain is not
known until a weigh, so cost would appear in lumps on scale days.

**Why this is a real correction, not caution.** John's assumed ADG is
**deliberately biased low** to carry a margin of error. The projection carries to
a **ship date**, so days are fixed and ADG has no business touching cost. Convert
a per-pound cost rate through a low ADG and the cost projection goes optimistic:

| 300 lb in, 250-day ship, COG $0.75/lb gain | assumed ADG 1.75 | realized ADG 2.25 |
|---|---|---|
| Projected gain | 437 lb | 562 lb |
| COG | **$328** | **$422** |

**$94/head of cost disappearing** purely because the ADG was conservative.
Conservative on revenue *and* optimistic on cost is the one combination that
makes a margin projection unreliable in both directions at once.

**The rule:** assumed ADG drives weight and revenue. **Realized ADG drives
anything that touches cost.** Never convert a cost rate through a deliberately
biased number.

### 23. Realized ADG drives the projection once it exists; assumed seeds it; both show

The conservative number does its job at purchase and then gets out of the way.
The screen shows *assumed 1.75 · realized 2.31*, so the margin being carried is
visible rather than buried — and **the gap accumulating across lots is the
calibration data** that makes the next assumption better.

**Why $/lb of gain cannot be trusted on a young lot.** 36-27 landed 8/11; at 2.0
ADG it has put on roughly 34 lb a head, against a *projected* weight rather than
a weighed one. Divide any cost by a small estimated gain and a 10% weight error
becomes a 10% cost-of-gain error, at the moment the number is least reliable and
most likely to be looked at.

This is the second instance of the same calibration loop in this module —
assumption → measured actual → next assumption. The first is the shrink
allowance. It is the argument for un-parking the lot comparison report.

---

## 6. Silage

### 24. Location per physical pile, item per crop year

Terrell and Corner are locations; "2024 Corn Silage" and "2025 Corn Silage" are
items. Matches PB's naming and Redwing's separate `24Corn/Sorg Silage` and
`25Corn Silage` boxes. A pile you can walk up to is a pile you can count, which
matters now that counting is the truth mechanism.

**The operating rule that makes it safe:** feed one pile to empty, then refill.
Never pack a new crop on top of an old one in the same pile — you feed the face,
newest first, and FIFO would consume the older layer first. Backwards, silently,
on the most expensive item on the place. John already works this way, so it
enforces itself.

Terrell currently holds mixed years; FIFO mostly covers it and it ages out the
next time the pile empties. **Silage is not being fed, so this is a cleanup job
with months on it, not a deadline.**

---

## 7. Mineral

### 25. The monthly count variance IS consumption, not shrink

Mineral is not in PB — nobody weighs sacks into a ration, and assigning bags to
pastures as fed fails every month because something is always missed. So the
monthly count *is* the usage record: count what is left, the drop from book is
what went out. **You cannot miss a bag you never had to write down.**

**The build is one word.** `post_feed_count` already computes this number. Today
the variance posts as an `adjustment` — shrink, charged to nobody. For mineral it
posts as a lot-allocated usage instead. One per-item setting decides which:

- **Barn commodities** — we know what was fed, so the residual is **shrink**.
- **Mineral** — we have no feeding record, so the residual is **consumption**.

**Allocated by head-days across every open lot** (test lots excluded), not by
pasture. The pallet measures *issuance*, not consumption — sacks sit in a feeder
for weeks — but the error is timing, not amount, and John's call is that it
washes over the life of a lot. Setting the usage period to the whole month lets
the head-day spread smooth it further.

Four items do not exist yet: ADM MasterGain, MLS Tub, Purina Mineral, Redmond Bag
Salt — **$9,089.13** in Redwing's Mineral RM 118008, currently $0 in the app.

---

## 8. What this changes

Nothing below is built yet.

**Schema**

- `feed_items`: Redwing template-field key; default shrink allowance %; count-variance
  meaning (shrink | consumption).
- `feed_receipts`: gross qty, allowance %, booked qty (booked stays the layer).
- `feed_storage_locations`: count target interval, last counted at.
- A one-row ranch settings table holding `feed_direct_from` (2026-09-01).
- `post_feed_count`: branch on the item's count-variance meaning; tag estimates
  from bulk bays.

**App**

- Count sheet: "bay is empty — zero every line"; estimate labelling on bulk bays.
- Weekly entry: one overlap summary on save.
- Anomalies: overdue bays; premix short with the ingredients-still-on-books wording;
  missing non-feed COG rate.
- Closeout: head-day split at `feed_direct_from`; zero non-feed COG with a warning
  when unset; $/lb of gain shown; assumed vs realized ADG both shown, realized
  driving the projection once it exists.

**Still open**

1. **The variance account** — John and the accountant, Monday 8/31.
2. **47-26 and 60X carry no cost assumptions at all.** Open since August; stops
   being cosmetic on 9/1, when they would project on actual feed and nothing else.
3. **Redwing template field mapping per item** — to propose, then confirm. Not
   blocking 9/1.

---

## 9. Monday 8/31

No feeding that day, so inventory is static across the changeover.

| what | who |
|---|---|
| Post feed to Redwing from PB — the normal weekly posting | Lauren |
| Walk the barns and count | John |
| PB ↔ office app tie, from John's numbers | Claude |
| Decide the variance account | John + accountant |
| **9/1** — direct charging starts, allocation stops carrying feed | — |
| **9/7** — first real weekly entry, covering 9/1–9/6 | Lauren |

**Numbers needed on the day:**

1. Counted pounds per item per bay — this becomes the opening balance. The
   existing 8/27 layers keep their PB-derived $/lb and the count corrects only the
   quantities, so nothing is re-priced.
2. PB's on-hand for the same items as of 8/31.
3. Real numbers for the five that have never had one: Corn, Deccox / Corrid
   Crumbles, the two RTU premixes, and Salt — which Redwing carries at −5,457 lb
   with $1,999.18 of value.
