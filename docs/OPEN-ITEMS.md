# Open items

Things known to need attention, and deliberately not done yet. Ordered by when
they will bite, not by size.

**Last reviewed:** 2026-10-01

Anything finished moves to the bottom under *Closed* with the date, so the
history of what was decided survives.

---

## 0. Crew doctoring in the OFFICE app does not reach the medicine ledger

**Status:** open, and John's call to make. Raised 2026-10-01 with the FIFO
medicine inventory build.

`med_consume()` is INVOKER, and every policy on the `med_*` tables goes
through `can_read_books()`, which excludes crew by design — a FIFO draw reads
what each layer cost. So a treatment **typed by a crew member in the office
app** saves correctly and never reaches inventory. The next count then finds
those doses missing and books them as shrink, which is the same wrong number
the approvals gate exists to prevent, arriving through a different door.

**The field app is not affected.** A field entry becomes a treatment when the
office approves it, and the office is the one that draws the stock.

**Latent today, not live:** every doctoring event on the books was entered by
the owner, and crew logins are not set up yet. So the gap is surfaced rather
than worked around — the treatment is kept, the person is told plainly that
the dose was not drawn out of inventory, and the office records it.

**The fix, when crew logins happen:** make `med_consume()` SECURITY DEFINER
and withhold the `total_cost` it returns from anyone who cannot read books.
The reason is the same one `lot_projected_weight` has been DEFINER for since
it was written — crew needs the number computed without being shown the
dollars behind it — and it would need a pinned `search_path` and a line in
`docs/database.md` rule 6. That is a change to the role model, so it waits
for a decision rather than being slipped in.

**What to do before then:** nothing, unless a crew login is created. If one
is, close this first — the alternative is a month of shrink that is really
just unrecorded doses.

---

## 0m. An office login reversing a treatment's medicine leaves the ledger row behind

**Status:** open, John's call. Found 2026-10-07 while building direct
medicine charges.

`med_reverse_txn()` is INVOKER. It puts the units back on the layers, then
deletes the `med_txns` row — and the `med_txns` delete policy is **owner
only**. For an office login RLS filters that DELETE to zero rows without an
error, so the units are back on the shelf **and** the usage is still booked:
the shelf reads high by the dose, and the next count calls the difference
shrink. `invReverseDoctoringUsage()` (delete or re-save a treatment, delete a
test lot) and `med_processing_reverse` (re-saved load out) both go through it,
and the doctoring path swallows errors on purpose.

**Latent, not live:** as of 2026-10-07 no `med_txns` row points at a deleted
doctoring event or delivery receipt, and reversals so far have been by an
owner. There is one active office login.

**Direct charges do not have the gap:** `delete_med_charge()` refuses anyone
but an owner and asserts afterwards that the ledger row is gone.

**The fix, either way round:** give office the `med_txns` / `med_txn_layers`
delete (a policy change), or make `med_reverse_txn()` SECURITY DEFINER with an
owner/office gate inside and a pinned `search_path`. Both change who may
remove ledger rows, so it waits for a decision. Until then the cheap guard is
the same assertion `delete_med_charge()` makes: raise if the row survived.

---

## 0b. A vendor rebate has nowhere to go once stock is costed

**Status:** open, raised 2026-10-01 with the opening count.

Enroflox's unit cost on the Redwing report runs 38.9% above this catalog's
last purchase price — $0.367130/mL against $0.264360, $1,079.09 across the
21 bottles on hand. John's explanation on 2026-10-01: **a rebate we might
get later.** So Redwing's figure is what the cash actually went out at and
is the right FIFO cost today; the catalog's lower figure is net of a rebate
that has not arrived.

**What this module cannot do about it.** A FIFO layer freezes its cost when
it is created, deliberately — that is what makes a reversal exact. When a
rebate lands months later, the stock it relates to has partly or wholly
been drawn into lots that are already costed, and possibly already closed.
There is no mechanism here to push a credit back through it.

**Do not "fix" it by lowering the catalog price.** Costing stock at a rebate
nobody has received yet understates the cost of every treatment until it
arrives, and overstates it afterwards if it never does.

**The options, when one actually lands:**

- treat the rebate as other income in the period received, and leave the
  layers alone — simplest, and what most operations do;
- or, if a rebate is ever large enough to distort a lot's animal-health
  cost, book a negative adjustment against the remaining stock only, and
  accept that the part already used keeps its original cost.

That is a wave-2 conversation and needs John's call. Nothing to do until a
rebate is actually received.

---

## 0c. CLOSED — the opening count posted and the ledger went live

**Closed 2026-10-01.** Both counts posted, `usage_from` set to 2026-10-01 on
both locations, and today's seven doctoring draws backfilled by hand because
they were typed before the ledger was live. Record and standing assertions in
`docs/sql/2026-10-01n_med_go_live.sql`.

| | opening | drawn 10/1 | on hand |
|---|---|---|---|
| Ranch | $20,081.64 | $91.12 | $19,990.51 |
| Jake Taylor | $2,668.56 | — | $2,668.56 |
| | **$22,750.19** | **$91.12** | **$22,659.07** |

The seven NULL `bottle_size` medications all counted zero, so none of them
blocked the post; they still cannot be stocked or counted until somebody reads
a label. Protivity posted as a decided zero.

---

## 0g. CLOSED — processing draws, and a count will not post ahead of it

**Closed 2026-10-02.** `docs/sql/2026-10-02_med_processing_draw.sql`.

A receipt now draws its protocol's medicine off the right shelf — the buyer's
when his `source_key` matches the lot's Source, Ranch otherwise (plan item 17).
The dose is **not** computed twice: `med_processing_dosed` carries the same
expression `lot_processing_cost_detail` has always used, so the shelf and the
closeout cannot drift apart by dosing differently.

Today's receipt (10/1, lot 32-26, 9 head) drew **8 lines, $109.72** — $102.42
of drugs off Jake Taylor's shelf, plus ID Tag and Lot Tag uncovered at catalog
cost ($7.30) because no tag stock has been counted yet. Three per-hundredweight
lines (Valcor, Macrosyn, Synanthic) are **awaiting weight** and were not
estimated.

**John's week-straddle question got the gate.** *"Invoices entered weekly. What
about month end that straddles a week!"* — processing happens, product leaves
the shelf, the invoice is not in yet so the per-weight lines have not drawn,
and the month-end count then books the difference as **shrink that never
happened**. That is the approvals-gate failure arriving through a fourth door,
so it gets the same answer: **a count will not post while any receipt in its
period is still waiting on a weight.** Tested end to end — a draft count dated
2026-10-31 at Jake Taylor refused with the three lines named.

**Still open, small:** two tag lines are uncovered until somebody counts tags
and enters the invoice, then `med_settle_uncovered()` clears them. John is
counting the med room tags and checking the lot-tag billing.

**Left behind:** one empty draft count at Jake Taylor dated 2026-10-31,
relabelled **"DELETE ME - test row"**. The Supabase tool refuses DELETE, so it
needs one click on the Counts screen. It holds no lines and created nothing.

---

## 0h. CLOSED — a posted count cannot be deleted, and drafts now can be

**Closed 2026-10-02**, same day it was found.
`docs/sql/2026-10-02b_med_count_delete_guard.sql`.

A `BEFORE DELETE` trigger on `med_counts` refuses a posted row and says to
un-post it instead, so the cascade can no longer throw away a count's lines
and orphan the layers it created. `med_purchase_lines.count_id` is indexed.

**And the Counts screen grew a Delete button for draft rows**, which it never
had. That gap is how this surfaced: a leftover test draft needed clearing and
there was no control to do it with. A draft has posted nothing, so deleting
one moves no stock and un-does nothing.

---

## 0i. Three processing lines on lot 32-26 are out of the barn and off the books

**Found 2026-10-02.** Needs John, because it moves real stock.

Lot 32-26's **1 Oct receipt, 9 head** drew 8 of its 11 lines, $109.72. Three
did not, and read `to draw` on `med_processing_lines`:

| medication | units waiting |
|---|---|
| Valcor | 63 |
| Macrosyn(Draxxin) | 36 |
| Synanthic | 36 |

All three are dosed **per hundredweight**. When the load out was saved the lot
had no weight of any kind, so the dose was unknowable and the draw skipped
them rather than guess. John then entered **355 lb** as the office estimate
(`2026-10-02c`), so the dose is now known — but a draw happens at save time,
not retroactively, which is the same rule that made the go-live backfill
deliberate rather than automatic.

So the drug is out of the barn and the shelf does not know it. The lot is not
under-costed — those lines price off the catalog in the meantime — but the
**on-hand is overstated** by what is sitting in the table above.

**The fix is one action:** open that load out and save it. The draw re-asks
every line, pulls the three, and the lot flips from implied to actual on them.
Jake Taylor is locked only through **30 Sep**, so a 1 Oct draw is allowed and
nothing has to be un-posted.

**Watch for it again at every month end.** Any per-cwt line on a receipt
entered before its weight will sit like this until somebody re-saves. The
count gate (`0g`) catches the straddle case — it will not let a count post
while a receipt in its period waits on a weight — but a weight that arrives
*after* the period closed cannot be drawn into it at all.

---

## 0j. CLOSED — the lot card and the processing report read one costing

**Found and closed 2026-10-02**, answering John: *"Is the processing cost card
correct in the lot page."* It was not. Applied on his go-ahead.
`docs/sql/2026-10-02e_lot_processing_costs_one_source.sql`.

There are two views and each carries its **own private copy** of the whole
processing-cost calculation:

| view | one row a | feeds |
|---|---|---|
| `lot_processing_costs` | lot | the **lot card** (Proc $/hd) and the closeout |
| `lot_processing_cost_detail` | medication | the Processing Cost report and the drilldown |

Both were written 2026-09-10 from the same text. The detail has had two changes
since and the summary neither — `2026-10-02c` (the office weight estimate) and
`2026-10-02d` (the FIFO draw preferred over the catalog). So the card reads a
calculation three weeks old.

| lot | card now | report now | gap |
|---|---|---|---|
| 32-26 | $512.01 | $778.17 | **+$266.16** |
| every other lot (9) | — | — | $0.00, to the cent |

The $266.16 is Valcor, Macrosyn and Synanthic dosed off John's 355 lb estimate.
One number on the report, another on the card, same screen — and **the card is
the one the closeout uses**.

**The fix, written and waiting:** `docs/sql/2026-10-02e_lot_processing_costs_one_source.sql`.
`lot_processing_costs` becomes an aggregate **over** `lot_processing_cost_detail`
— one costing, two shapes — so the summary has no copy of anything to forget.
Same lesson as the processing draw, which shares its dose expression with the
costing view on purpose. Column list unchanged; `med_line_count` and
`unpriced_line_count` go from counting (source × med) to (lot × med), and
nothing in the app reads the first or depends on the exact value of the second.

**Applied, and it moved exactly what was measured:** lot 32-26 from $512.01 to
$778.17, the other nine identical to the cent. Processing across the place went
$99,264.14 → $99,530.31, all of it that one lot. `receipt_count` and
`invoice_gap_head` came back unchanged, 37X still reporting its 361 head on
invoices no load out covers. The file's body was re-applied afterwards and
md5s identical to the deployed view. rls_verify: PASS.

One thing to know for next time: the cast in `invoice_gap_head` is load-bearing.
`head_count - bigint` is bigint and `sum(bigint)` is numeric, which
`CREATE OR REPLACE` refuses outright — *cannot change data type of view column*.
Summing the integer keeps it bigint.

---

## 0k. CLOSED — previously expensed stock stays at catalog, and it is a one-off

**Closed 2026-10-02 by John's call**, after the options went to him:

> "All of this is a one off first month problem as we work through this
> inventory. Only thing that will linger is the roughly six thousand tags at
> $.40 cost roughly. Kind of immaterial in the dollars and was always handled
> this way for ease of operation because no good system to handle."

**So: no flag, no reclassifying entry, nothing to track.** The stock sits at
catalog, which is the number that makes processing cost right — his own
objection to a zero. The dollars that are arguably counted twice are **~$2,429
of tags** entered this month and they drain as cattle get tagged; nothing new
joins them, because from here every layer arrives with an invoice behind it.

| what is on the shelf at catalog | |
|---|---|
| Ranch, ID Tag #1001-6000 | 5,000 · $2,028.00 |
| Jake Taylor, ID Tag #11-999 | 989 · $401.14 |

What was deliberately NOT built, and should not be built later without a new
reason: a `previously_expensed` flag, a dual FIFO/book value on the shelf, and
any capitalizing journal entry. The cost of carrying that machinery outweighs
the number it would track. **If this ever stops being a one-off** — another
bulk buy expensed outside the system — reopen this rather than quietly adding
more untracked stock.

**Lot tags are now in, and the tag story is closed.** John counted 167 at
Jake's on the morning of 1 Oct (`2026-10-02l`); the 9 his receipt drew that day
settled against them, repricing nothing, and **no tag usage is uncovered
anywhere** — Ranch ID 5,000 / $2,028.00, Jake ID 989 / $401.14, Jake Lot 158 /
$64.08. They were billed in bulk to cattle in September, and John's final call
(`2026-10-02m`) is that **the lot tags go in at ZERO cost** — the money is
already through September where it belongs, and cost starts with the next
purchase. **So there is no journal entry**; the memo drafted for Jayci and
Brenda is withdrawn in place. The 9 already drawn went to zero with the layer,
which took 32-26 from $778.17 to **$774.52**. ID tags stay at catalog, by his
earlier call. Both tags are now counted in **"each"**.

**The transfer he asked for in the same breath is built** —
`docs/sql/2026-10-02h_med_transfer.sql`, and the Checkouts screen now moves
stock between pools as well as handing it to a man.

---

## 0l. Synovex Primer has no container size — parked by John until the next buy

**Parked 2026-10-02.** John: *"No primer on hand so cost and size will be
updated if we buy more, ignore for now."* Nothing to do, recorded so the
`needs_container_size` flag on the on-hand screen is not re-investigated by
whoever sees it next.

**Its cost is NOT missing**, contrary to an earlier note in this chain. Primer
carries `cost_per_head` $2.02 and the lots are charged it — $3,308.76 across
six live lots, none unpriced. What is missing is `bottle_size`, so it cannot be
counted in bottles. Zero on hand, so there is nothing to count.

It stays on its **two active protocols** (`Summer Cutting Bulls/2026`,
`26 Summer X Steers/Bulls Receiving`) at 1 dose a head. John, 2026-10-02:
*"It will be purchased before the protocol is used again."* So the cattle do
get it, the shelf is simply empty, and nothing has to come off anything — there
will be a layer before the next receipt needs one.

### The trap on the day it IS bought

`medications.cost_per_unit` is a GENERATED column —
`bottle_cost / bottle_size` when the size is set, NULL otherwise. And the
costing prefers, in order: a priced draw, then `cost_per_unit × dose`, then
`cost_per_head`. Primer has no `cost_per_unit` today, which is the only reason
its $2.02 `cost_per_head` is what the lots read.

**Filling in BOTH bottle size and bottle cost on the Medications tab would
generate `cost_per_unit`, and that outranks `cost_per_head` on every receipt
with no priced draw — including the whole history.** 1,638 head have been
charged Primer at $2.02 across six live lots, so every $0.10 of difference
between the new per-dose price and $2.02 moves $163.80 of closed processing
cost.

So when the purchase lands:

| do | why |
|---|---|
| put the price on the **purchase line** | that is the layer; future draws price off it at the real cost |
| set **bottle size only** on the Medications tab | the shelf can then count it in bottles, and `cost_per_unit` stays NULL because `bottle_cost` is still blank |
| leave `cost_per_head` $2.02 alone | it is what pre-go-live receipts read, and the only price history has |

If the history *should* be re-priced to the real cost, that is a deliberate
decision with a number attached, not a side effect of typing a bottle cost into
the catalog. It is the same rule as CLAUDE.md's "never edit a drug price in
place to change cost from a date".

Looking at this turned up a real bug in the FIFO costing, now fixed:
`docs/sql/2026-10-02k_med_fifo_ignores_unpriced_draw.sql`.

---

## 0d. Three stock locations, against a design that deliberately has one

**Status:** DECIDED 2026-10-01 — Jake Taylor added now, the room/truck split
deferred to wave 2. The `invLedgerReady()` fix below is the part that is still
open, and it has to land **before** any second ranch row exists.

John on 2026-10-01: *"we will have three locations as of now but could grow in
future. Medicine Room, Cowboys, and Jake Taylor (will have processing meds)."*

**Jake Taylor is not the problem** — he is already in the design. A buyer's
shelf is a `med_stock_locations` row with `kind = 'buyer'` and `source_key`
matching `lots.source`, which is what the buyer-reconciliation view keys off
so a lot's processing draw knows whose account to pull from. **Done
2026-10-01** in `docs/sql/2026-10-01j_med_jake_taylor_location.sql`: the row
exists, keyed to the five lots carrying `source = 'Jake Taylor'`, with
`usage_from` NULL so nothing accrues against it until his count is posted.

**Medicine Room and Cowboys are the problem,** because the module was built on
the opposite decision and says so in two places:

- `med_stock_locations.kind` allows only `'ranch'` and `'buyer'`, and the
  Ranch row's own note reads *"Barn and crew boxes together — one pool.
  Custody is tracked per person, not per location."*
- `med_txns.direction` allows 0 for a checkout, with the comment *"a checkout
  does not move stock — the bottle is still ranch stock."* Custody points at a
  **crew member**, not at a location.

So today the room/truck split already exists, but as the four gathering boxes
on each count line — `barn_full`, `barn_open`, `crew_full`, `crew_open` — not
as separate pools. That is what produced the $2,419.56 crew figure in the
opening count.

**Two real defects if a second `kind='ranch'` row is simply inserted:**

1. `invLedgerReady()` in `index.html` resolves the location with
   `.eq('kind','ranch').eq('is_active',true).limit(1).maybeSingle()` — **an
   arbitrary row**. Every doctoring dose would draw from whichever one
   PostgREST returned first.
2. `med_consume()` orders layers `(location_id = p_location_id) DESC` and then
   falls through to other locations, so a draw against the wrong shelf
   **succeeds silently** off the right one. No error, wrong books.

And a third thing that is not a defect but is the actual work: with Cowboys as
a real pool, nothing ever moves stock into it, because a checkout is custody
only. The trucks would fill at the opening count and never drain, and every
subsequent count would read the whole truck as shrink. Making it work means a
`transfer` txn type, a `med_transfer()` that moves units between locations
layer by layer, and the screens for it.

**The options:**

- **Keep one ranch pool.** Medicine Room and Cowboys stay the two gathering
  boxes they already are, Jake Taylor becomes a buyer location today. Nothing
  to build, works this afternoon, and the reporting split John wants already
  exists. It does not extend to a fourth place.
- **Make them real locations.** Fix the two defects first, then build
  transfers. That is the design that grows, and it is a wave-2 piece of work,
  not an afternoon.

**John's decision, 2026-10-01:** Jake Taylor now, the real split in wave 2.
The opening count posts against the one ranch pool.

**What is left here, and it is not optional:** fix `invLedgerReady()` to
resolve the ranch location deterministically rather than with
`.limit(1).maybeSingle()`. Today there is exactly one ranch row so the bug is
latent, and the verify block in `2026-10-01j` now asserts that — it fails if a
second one appears. But the assertion only runs when somebody runs that file.
The fix is small and should land on its own, ahead of wave 2.

---

## 0e. Redwing should stop expensing medicine at issue

**Status:** proposed 2026-10-01, with Jayci and Brenda. Memo and worked
numbers in `docs/worksheets/2026-10-01_crew-medicine-accounting-memo.html`.

Redwing charges medicine to the cattle **when the bottle leaves the medicine
room**. This module expenses it **when the dose goes in an animal**. Those are
different months and different cattle, and the gap is whatever the crew is
carrying — $2,419.56 at 2026-09-30, about 12% of the medicine inventory.

**Method A (today):** charge at issue, then a hand-computed true-up entry
every month to put truck stock back. The size changes every month.

**Method B (proposed):** the bottle stays in 117500 when it goes to a truck;
one monthly journal entry credits 117500 and debits animal health by lot, off
`med_roll_forward`. Then 117500 **is** the counted value and the monthly
reconciliation is one line instead of a bridge.

Method B needs no new account — it changes *when* the entry is made, not
*where*. The $2,419.56 true-up being made now is its transition entry, once.

**What it depends on:**

- The opening count posting and `usage_from` being set. Until then the app
  records no usage, so there is no number to post.
- The trucks being counted monthly. `crew_carried` covers a month somebody
  does not report, by carrying the last figure and marking the count
  estimated rather than booking shrink that did not happen.
- Shrink becoming visible, which it is not today — a bottle lost out of a
  truck was expensed the day it left the room. The crew should hear that
  before the first count, not after.

**Running amounts beside dollars** on every reconciliation until the two
systems have agreed for a few months — John's call, 2026-10-01, and the
opening count is the argument for it: every entry on the sheet is a quantity
difference times that line's own rate **except two**, and those two are the
errors. Dollars alone could not separate them.

Jake Taylor's processing medicine is issued and used the same day, so A and B
land in the same place there. Nothing to change.

---

## 0f. Excede is on the place in two container sizes; the catalog holds one

**Status:** open, cosmetic today. Raised 2026-10-01.

The shelf has **24 x 100 mL and 1 x 250 mL**. `medications.bottle_size` can only
hold one, and it holds 250 mL ($519.35).

**Why it does not break anything.** `cost_per_unit` is per mL and is
size-independent, so dosing, FIFO layer cost and every dollar figure are right
whichever size the catalog carries. What moves is the word *bottles*: On hand
divides units by the catalog size, so Excede reads 12.50 bottles at 250 and
31.25 at 100, for the same 3,125 mL.

**Why it mattered once.** The count line carries its own `bottle_size`
snapshot, and at 250 the crew's 475 mL came to **1.9 bottles**. The count
grid's open-bottle inputs are `step="0.25" max="0.75"` — quarters, capped at
three quarters — so 0.9 could be written by an UPDATE but never typed by a
person. A row only a migration can produce is a row nobody can recount next
month. Fixed in `docs/sql/2026-10-01l_med_excede_bottle_size_100.sql` by
carrying the line on 100 mL: barn 26 + 1/2, crew 4 + 3/4, same 3,125 mL, same
$6,665.98. That file's verify block now also asserts **every open box on every
line is a quarter at or under 0.75**, which the database CHECK (`< 1`) does not.

**Partly settled 2026-10-01.** John, asked which size the catalog should hold:
*"some cowboys like 100 ml and some like 250 ml. We use a checkout sheet in med
room for what they get that should state size."* That turned out to be a bug
report — the Checkouts screen converted bottles to units off the catalog with
no override, so "2 x 100 mL" off the paper sheet recorded 500 mL instead of
200. Fixed in `docs/sql/2026-10-01m_med_checkout_bottle_size.sql` plus the
screen: `med_txns.bottle_size` snapshots what left the room, the same way
`med_purchase_lines` and `med_count_lines` already did, and `med_checkout_log`
divides by it. **The catalog is now only a default in a box somebody can
change**, which is what makes the question below low-stakes rather than
urgent. Left at 250 mL.

**The options, when somebody wants it right rather than merely harmless:**

- leave it, and read *bottles* as "250 mL equivalents" for Excede;
- set the catalog to 100 mL, the size there are 24 of, and let the single
  250 mL bottle read as 2.5;
- or carry the two as separate medications, which is honest but doubles the
  line on every screen and splits the FIFO pool for one drug.

Nothing to do until John decides. No dollar figure moves either way.

---

## 1. Custom SMTP — no email leaves the project today

**Status:** deferred by decision, 2026-08-24.

Supabase will not deliver auth email to any address that is not a member of the
project's organization. That is a refusal, not a rate limit — waiting does not
help, and the dashboard's "Send password recovery" silently fails to reach an
outside address.

**What this costs right now**

- No self-serve **forgot password** for anyone. John is the reset mechanism.
- No email invitations. Every account needs a password set by hand and passed
  along out of band.
- A user who forgets their password and cannot reach John is locked out until
  he acts.

**Why deferring is reasonable:** two users, and John can text a password. It is
genuinely simpler than running a mail provider.

**What changes the calculus:** more than about four users, cowboys who cannot
reach John quickly, or anyone who needs to reset their own password.

**When it is time:** Authentication → Emails → SMTP Settings, pointed at a
sending service (Resend, Postmark, SendGrid, or Google Workspace SMTP). Then
invitations, password resets, and forgot-password all work without John.

---

## 2. Two Supabase dashboard settings

**Status:** open. Both are a couple of clicks and neither has been done.

- **Leaked-password protection.** Authentication → Policies (password
  settings). Supabase checks new passwords against HaveIBeenPwned and rejects
  breached ones. Do it before handing out any more passwords.
- **Public signup.** Authentication → Sign In / Providers → check whether
  "Allow new users to sign up" is on. If it is, anyone with the app URL can
  create an account. They land inactive and can do nothing, so it is not a
  breach — but it lets strangers put rows in the auth table. The agreed
  posture is signup closed, invitation only.

---

## 3. A refused UPDATE or DELETE is silent

**Status:** known, mitigated in one place, not fixed generally.

PostgREST returns an empty result rather than an error when RLS filters every
row, so a save can report success while changing nothing.

The Users screen asserts on the returned row count and reports a refusal
properly. **Nothing else in the app does.** The role gate hides the controls
where this would bite, which is why it is not urgent — but any new write path
added without a `data-perm` will hit it.

The real fix is making every save check the returned rows. That is a broad pass
through `index.html` and has not been attempted.

---

## 4. Retire the old field-app repo

**Status:** waiting on a date — **on or after 2026-09-14**.

`johnfreagan/JFR-Ranch-Cattle-Field-App` still serves Pages. The retirement
commit is live, so any installed copy self-destructs on its next online load,
but that needs **one** online load. Three weeks from the 2026-08-24 switch was
the agreed wait.

John's steps, in the GitHub UI: old repo → Settings → Pages (disable), then
Settings → Archive.

Worth a nudge to anyone still on the old copy to open it once on signal first.

---

## 5. The guides exist in two places

**Status:** low priority, but it will cause a stale page eventually.

`docs/USER-ADMIN-GUIDE.md` and `docs/manuals/admin-manual.html` carry the same
content in two formats, as do the two field guides. They have to be edited
together or the published artifact goes stale.

Options when it becomes annoying: generate the HTML from the markdown, or drop
the markdown and treat the HTML as the only source.

---

## 6. SECURITY DEFINER advisor warnings are expected

**Status:** no action needed — recorded so a future advisor run is not alarming.

Re-verified 2026-08-25: `public` holds **seven** `SECURITY DEFINER` functions,
and **all seven carry a pinned `search_path`** —  `current_user_role`,
`admin_list_users`, `guard_last_owner`, `handle_new_user`,
`cleanup_attachment_storage`, `lot_projected_weight`, `lot_weighted_arrival_date`.

The first three are deliberate and guarded — `current_user_role()` filters on
`is_active`, `admin_list_users()` checks for owner inside the query and is
revoked from `anon`, and `guard_last_owner()` is a trigger. All fail closed. The
two lot functions predate this work and have not been reviewed.

Also verified 2026-08-25: the head-math RPCs (`record_death_with_pasture`,
`record_move_with_pasture`, `delete_death_event`, `delete_move_event`) are all
`SECURITY INVOKER`, which is correct — they must run under the caller's RLS.

Also expected: `auth_leaked_password_protection` — that is item 2 above.

---

## 7. Automatic daily send of the daily report

**Status:** report built 2026-08-25, delivery not started. Agreed order is
email first, then SMS.

Reports → Daily Report composes the day's doctoring, moves and deads and can
be printed, texted as a PDF through the share sheet, emailed or copied. All of
that needs the app open. Sending it on a schedule does not, so it needs a
Supabase Edge Function on a cron — `pg_cron` and `pg_net` are available on the
project but **not installed**.

**Decision that gates the build.** The function has to compose the report with
no browser: either the report logic is written a second time in TypeScript, or
a SQL function becomes the single source of truth and both the app and the
function read it. The rules that would drift if duplicated are the test-lot
filter, the death dedupe between `doctoring_events` and `lot_events`, the
carcass-not-hauled detection, and recovering the cowboy's name through
`approved_ref`. The second option means refactoring the screen that was just
shipped and verified.

**Blocked on John either way:**

- A Resend account and a verified sending domain. The same account closes
  item 1 above — custom SMTP for password resets — so it is worth doing once
  for both.
- Enabling `pg_cron` and `pg_net` in the dashboard.

**SMS is a separate hurdle.** US A2P 10DLC registration is mandatory for
automated texts on a normal number; the sole-proprietor path is a few dollars
a month plus a few days for approval. Until it clears, texting the PDF from
the share sheet is the path. Carrier email-to-SMS gateways were considered and
rejected: they are free but drop messages silently, and a blocked report and a
quiet day look identical.

**Agreed settings, not yet built:** 6:30pm CT, pinned to `America/Chicago` so
DST does not move it; recipients in an owner-managed table with a Settings
screen; short recap in the text, full PDF in the email.

---

## 8. Cost assumptions are missing or wrong on live lots

**Status:** partly fixed 2026-08-25.

Found while building the closeout rebuild:

- **37X-1 had labor at $35.00/head/day** with mode `per_day`, so the screen
  multiplied it by 223 days — $7,805/head against cattle that cost about
  $900. Corrected to $0.35 by John's call
  (`docs/sql/2026-08-25_37X-1_labor_rate.sql`).
- **47-26 and 60X carry no cost assumptions at all** — no COG, labor, med,
  death loss or interest. They project on purchase price only. Still open.
- **36-27 is at $2.00/head/day COG**, double every other lot (0.75–1.00).
  Asked; not yet answered. May well be correct for that set.

Nothing validates these on entry. A rate that is off by 100× produces a
confident, wrong projection, and the only signal is that the number looks
strange. Worth a sanity band on the input (warn outside, say, $0.10–$5.00
per head per day) rather than a hard limit.

---

## 9. Merging lots and transferring cattle between lots

**Status:** DESIGNED AND BUILT 2026-09-02 — see `lot-transfers-design.md` for
the fourteen decisions and `sql/2026-09-02_lot_transfers.sql` for the schema
(written, not yet applied). The notes below are kept because they framed the
problem correctly; two of their conclusions did not survive contact with the
schema, and the design record says which and why. In short: the sale-out /
receipt-in framing proposed at the end cannot be used (a synthetic receipt
re-charges receiving meds through `receiving_protocol_id`, a synthetic invoice
inflates `head_in`, a synthetic sale reads as revenue), and the head math was
already built — `lot_events` has permitted `transfer_in` / `transfer_out` all
along, and both `lot_status` and `lot_daily_head` already read them.

Original note, 2026-08-26:

Two related operations the app cannot do at all today:

- **Merge two lots** into one — e.g. a remnant of 20 head folded into the lot
  it now runs with.
- **Transfer cattle between lots** without them leaving the ranch.

The head math is the easy half. `lot_pasture_assignments` would move, and
`lot_movements` already models a move within a lot; the same shape extends to
a move between lots.

The accounting is the hard half, and it is why this needs a decision before
any code:

- **Cattle cost travels with the animal.** A lot's `total_cost_in` comes from
  its invoices. Move 20 head out of a lot and some share of that cost has to go
  with them — at what value? The lot's average cost per head is the obvious
  answer and is wrong for a lot whose loads were bought at different prices.
- **Head-days do not travel.** `lot_daily_head` is built from the receiving
  and death/sale events of one lot. Cattle transferred in on day 120 did not
  eat that lot's grass for 120 days, so their cost of gain must not be charged
  as if they had. Either the receiving lot's head curve gains a mid-life
  arrival, or the transfer is modelled as a sale out and a purchase in.
- **`lot_budgets` is frozen.** A lot that gains 20 head is no longer the lot
  the budget was written for, and the budget cannot be edited by design.
- **Tags recycle across fiscal years** and "current animal for a tag" is
  resolved through open lots, so a transfer has to keep `lot_tags` honest or
  tag lookup starts pointing at the wrong animal.
- **Closeout would need to show it.** A lot that gave up cattle mid-life has a
  discontinuity that neither budget, actual nor projection currently models.

The cleanest framing is probably to model a transfer as a **sale from one lot
at an internal price and a receipt into the other at the same price**, which
reuses machinery that already exists and keeps both lots' books
self-consistent. That makes the internal price the single decision to make,
and it is a real one — it sets which lot books the margin.

Not started. Needs John's call on the valuation basis first.

---

## 10. Commodity feed inventory — data still to settle

**Status:** open, raised 2026-08-27 the day phases 1, 2 and 4 went live.

The module works; these are the numbers and decisions that have to land
before next week's office process means anything. All of them are cheap
today because `feed_usage` is still empty — nothing has consumed a layer, so
no cost has frozen yet.

**Fix before feed is entered:**

- **The opening balance is dated 2026-08-27, not backdated.** John's intent
  was to back-date to the start of 36-27, whose cattle hit the ground
  2026-08-11. Feed entered for a period starting before the layer's date
  finds nothing to draw on, goes short, costs at the item's last known price
  and flags itself — correct behaviour, wrong answer.
- ~~**"Corn hopper bin" and "Corn" are separate items."**~~ **Resolved
  2026-08-28: keep them separate.** PB encodes the bay in the commodity name,
  and that is the only signal telling an import which pile was fed. Merging to
  match Redwing's single `Corn $` box would destroy it. Instead several items
  map to one Redwing box. See `feed-design-decisions.md` #2.
- **The four PB negatives have no real number.** Corn −1,393, Deccox −756,
  RTU Silage Tran 1 −29,918, RTU Silage Premix 2025 −1,109,171 lb. A negative
  opening balance is PB saying it fed something it was never told existed,
  not a quantity to seed. Each needs a physical count. The large one is PB
  feeding a premix never recorded as made — the hole `make_feed_batch` fills.
- **Corner Silage Pile holds 0 lb** and no bay carries a ranch.

**Decisions:**

- **`lots.assumed_nonfeed_cog_per_day` is NULL on all 9 open lots.** That is
  the designed default: while NULL the Closeout charges assumed COG unchanged,
  shows feed beside it and says the two OVERLAP. Set it per lot when the split
  is known. Nothing recomputes retroactively. Overlaps item 8 above.
- **Redwing coding is blank on all 17 items** — account, profit center,
  production center. Phase 5 cannot post without it.
- **Batch yield is the sum of the inputs** (John's call, against the
  recommendation to weigh the output). `output_qty_lb` is stored rather than
  derived, so weighing later is a form field, not a migration. Shrink lands
  as a bay variance rather than a yield loss.

**Built but unguarded:**

- **Nothing stops a lot being fed a premix AND its own ingredients.** The
  ingredients were consumed when the batch was mixed; feeding both
  double-counts, and the dollars still allocate cleanly so no screen looks
  wrong. Only UI guidance text defends against it today. A guard would flag a
  lot fed both a premix and one of its inputs over overlapping periods.
- **`pasture_feed_allocation` weights by `lot_pasture_assignments`**, which
  this app already treats as unreliable for whole-life head-day math (37X's
  history starts 2026-04-27 against a first invoice of 2025-12-04). Lot-level
  allocation is unaffected — it goes through `lot_daily_head`. Only bites once
  mineral is put out by pasture.

**Superseded 2026-08-28.** A working session settled 25 design decisions that
change several items above — the cut-over is 9/1 and barn-only, silage is
deferred, the COG boundary is a ranch-level date rather than the per-lot flag
phase 4 shipped, and a count variance means shrink for commodities but
consumption for mineral. Read `docs/feed-design-decisions.md` before acting on
this item.

**Not built:** phase 3 (PB import — designed, waiting on a CSV; its real
hazard is an OVERLAPPING import, not a duplicate one, since `pb_row_key`
upserts a re-run but Aug 17-26 then Aug 20-31 double-feeds four days under
different keys), phase 5 (Redwing export), phase 6 (field-app mineral
put-out).

---

## 11. Tally Book - the port is unverified against the live database

**Status:** ported to the artifact UI 2026-08-28. Two things block a real
end-to-end run, and both need John.

- **`docs/sql/2026-08-28_tally_book_v2.sql` has not been applied.** It drops
  `tally_entries` / `tally_projects` (guarded: it refuses if either holds
  real rows) and creates `tally_days` + `tally_book`. Until it runs, the app
  signs in and then every sync fails - loudly, in a toast. Re-run
  `rls_verify.sql` afterwards per rule 7.
- **Nothing has been signed in.** Unverified: the push/pull round trip, the
  dirty-diff picking the right days, the locally-dirty-wins conflict rule,
  the RLS scoping, and purge-on-user-change.

What IS verified, in a browser, on the ported build: the book boots and
paints; the date reads 28 August from the ranch clock; capture works and the
natural-language parser still files "tomorrow 7am" to the next day at 07:00;
the bullet cycle open -> done -> migrated strikes the old entry at `st:2` AND
copies a fresh one to tomorrow; all six tabs render; the sync dot goes amber
on unsaved changes and a sync with no session refuses with a visible toast
rather than pretending. Two real layout bugs were found and fixed this way -
the collapsed grid and the truncated date.

**The data migration, once the schema is in:** John opens the artifact,
More -> Export, copies the JSON; then in the app, More -> Restore, pastes it.
The shape is preserved end to end, so delegation, sub-steps, trackers and
collections all survive - there is no hand-written mapping to get wrong.
**His book is still only in one browser's localStorage until he does this.**

Deliberately not built:

- **No offline write queue.** Entries survive offline in `localStorage` and
  go up on the next sync, which covers the ordinary case. What is missing is
  a dead-letter path for a write the database later refuses.
- Nothing links the tally book to ranch data. The artifact's Lots tab reads
  a pasted export; wiring it to the real views is a separate job.

---

## 12. Only two accounts exist, and both are owner

**Status:** open. Surfaced 2026-08-28 by the RLS roster. **John's call: Lauren
stays owner.** Office and crew accounts to be added 2026-08-31.

`user_profiles` holds exactly two rows — John and Lauren, both `owner`, both
active. Nothing is misconfigured; the consequence is that **the entire crew and
office boundary has never been exercised by a real login**:

- "Crew can't see any dollars", the office-only Closeout and Feed tabs, the 65
  `data-perm` controls, and every RLS denial that returns zero rows rather than
  an error — all of it is theoretical.
- The field PWA went live 2026-08-25 and no cowboy has an account, so the
  offline queue replaying under later authorization (open item 3's sibling) has
  never been seen against a real crew user either.

The privilege that actually matters: **owner is the only role that can delete**,
and `lot_movements`, `lot_events` and `lot_pasture_assignments` are audit trails
where an accidental delete is unrecoverable in a way an accidental insert is
not. That is why the privilege is narrow. `office` covers everything the books
need — invoices, cost, margin, corrections — minus that.

Asked and answered 2026-08-28: Lauren keeps owner. Recorded here so the reason
the role exists is not lost, and so the first office and crew accounts get
tested against the boundary rather than assumed to work.

Note for whoever adds them: `ranch_settings.feed_direct_from` is owner-only to
UPDATE by design — it moves money between periods — so an office user cannot
change the feed cut-over date.

---

## 13. Tally Book has two orphan tables

**Status:** open, cosmetic. **John's call: clean up on the next tally build.**

`docs/sql/2026-08-28_tally_book_v2.sql` supersedes `..._tally_book.sql` and
moved storage to `tally_days` (one row per day) and `tally_book` (one row per
long-tail key). The first cut's tables were never dropped:

| table | rows | |
|---|---|---|
| `tally_days` | 1 | live |
| `tally_book` | 8 | live |
| `tally_entries` | 0 | orphan |
| `tally_projects` | 2 | orphan |

Harmless — they carry RLS and policies like everything else. The hazard is
purely that the next person reading the schema sees four tally tables and
cannot tell which two are real, and `tally_projects` having rows in it makes
that mistake easy. Look at those 2 rows before dropping.

---

## 21. Nineteen functions are EXECUTE-able by `anon` (found 2026-09-10)

**Status:** found while verifying the strays migration. Not caused by it — its
own four functions were checked and are clean.

Postgres grants function `EXECUTE` to `PUBLIC` by default, and `anon` inherits
through `PUBLIC`. Nineteen functions in `public` still carry the default ACL
(`{=X/postgres,...}` — the leading `=X` is PUBLIC), so a caller holding only the
embedded publishable key can invoke them. This is **CLAUDE.md access-control
rule 4** — *"Revoke from `PUBLIC`, not just `anon`"* — and the newer migrations
that never wrote a REVOKE are where it crept back in.

The list includes real write RPCs: `record_feed_pen_removal`,
`close_feed_pen_year`, `delete_feed_pen_removal`, `feed_pen_freeze_costs`,
`feed_pen_allocate_proceeds`, `feed_pen_split_head`, plus the trigger functions
and guards (`pfe_guard_settled`, `lot_budgets_frozen`, `feed_load_guard`, …)
and `futures_contract_lb`.

**How bad is it, honestly:** all nineteen are **SECURITY INVOKER**, so anon
still hits RLS on every table they touch and gets `42501`. Nothing here is an
open door on its own. But it is one missing `INVOKER` away from being one, and
a trigger function called directly is a shape nobody has thought about. This is
defence-in-depth that the rule exists to keep.

**The fix** is one guarded `DO` block revoking `ALL ... FROM PUBLIC` and
`FROM anon` on each, re-granting `authenticated` and `service_role` — the same
loop section 7 of `2026-09-07d_strays_and_missing.sql` already runs for its
four. Cheap, but it touches nineteen live functions, so it needs John's say-so
and a pass afterwards confirming the app and field app still work.

Worth adding to `rls_verify` at the same time: it checks table grants to `anon`
but does not check function `EXECUTE`, which is why this sat unseen.

---

## 21. Cost of gain: eleven decisions, build order set (2026-09-11)

**Status:** built and applied 2026-09-11, all eight items. Full record with
the reasoning: `docs/cog-design-decisions.md`. Still open from it: the
$0.50 non-feed placeholder, and the ledger allocation rules (October).

Actuals replace the COG rate month by month once the Redwing ledger lands
(October); until then the closeout labels COG and Labor as `rate × real
head-days`. Realized ADG prices the unsettled gain once 25% of sold head
carry pay weights; whole-lot weighings count, samples never. Unweighed sales
flag the closeout and block Close Lot. Feed boundary switches on now with a
$0.50/head-day placeholder non-feed rate (ranch default, excludes labor).
Finish weight comes off the anchored projection. Modes collapse to per_lb.
Assumptions log on Save only, with an unsaved what-if marker. Two drift
checks on Anomalies. Ledger allocation rules deferred to the October deep
dive.

---

## Closed

- **2026-08-27 — The RLS verify script now exists.** `CLAUDE.md` rule 7 and
  `docs/security-model.md` had cited
  `supabase/migrations/20260821000300_rls_verify.sql` as mandatory since
  August while no `supabase/` directory existed at all, so every migration
  since had either skipped the sweep or inlined its own partial checks. Written
  to the documented contract and run against production: it asserts no grant to
  `anon` or `PUBLIC`, `security_invoker` on every view, RLS enabled with real
  policies on every table, and a pinned `search_path` on every
  `SECURITY DEFINER` function. It found one live hole on the first run —
  `anon` could EXECUTE `SECURITY DEFINER public.guard_last_owner()`, the exact
  rule-4 PUBLIC-grant trap, since Postgres grants function EXECUTE to PUBLIC by
  default and `revoke ... from anon` alone does nothing. Revoked from `PUBLIC`;
  proved first on a scratch database that this is safe, because Postgres checks
  EXECUTE at CREATE TRIGGER time and not at fire time. The script's own
  assertion that every table carries all four commands was downgraded to
  informational: it flagged `user_profiles` for missing INSERT and DELETE
  policies, which are deliberately absent — profiles are created by
  `handle_new_user()`, and a client INSERT is the signup-escalation hole. A
  missing policy denies, so the gap is fail-closed.

- **2026-08-25 — Closeout rebuilt as budget / actual / projection.** Roadmap
  item 4 phase 1. `lot_budgets` (frozen, immutable by trigger),
  `lot_daily_head` and `lot_head_days_by_month` added and verified against
  production — the head curve lands on `head_current` for all eight lots.
  Fixed in the rebuild: the death-loss double count, interest charged only on
  the purchase price, cost of gain never reaching cattle that already
  shipped, the Closeout tab being visible to crew, and the tab rendering
  before `loadSales` so it showed the previously viewed lot's sales. The
  "Hd-days" tile now reads the receipt-anchored view instead of the
  invoice-anchored function. Cost ledger categories and pasture cost are
  deliberately still out — John enters a cost of gain rate for now.
- **2026-08-25 — Part B: the field app writes to the books.** Roadmap item 3,
  done. The field app authenticates against Supabase and writes to
  `pending_field_entries`; the office **Approvals** tab reviews and posts into
  the books. Eleven real doctoring entries went through on 2026-08-25 with
  frozen cost and zero drift. Deaths and moves are built, RPC-backed and
  rollback-tested, but no real one has been approved yet — John will flag the
  first of each. See "Field → books approval path" in `CLAUDE.md`.
- **2026-08-25 — `delete_death_event` double-counted head on reversal.** When
  the death closed an assignment outright, the reversal reopened it *and* added
  the head back. Fixed alongside the new `record_move_with_pasture` /
  `delete_move_event`.
- **2026-08-25 — Lot 37X carried −3 drift.** Sixteen deaths predated the lot's
  first pasture assignment (April import). Reduced Steele–Front Native 244→241
  with an audit note, John's call. All lots verified at zero drift after.
- **2026-08-25 — Lauren's account.** She signed in, works the books as `owner`,
  and has pulled data on both her Windows machine and the field app.
- **2026-08-24 — Crew write directly to the books.** Crew are now read-only
  everywhere; verified all 27 non-SELECT policies across nine tables.
- **2026-08-24 — `doctoring_event_meds` had no ownership check.** Subsumed by
  the above; crew cannot write to it at all.
- **2026-08-24 — Login screen ignored `is_active`.** Now refuses inactive
  accounts by name on both fresh sign-in and restored session.
- **2026-08-24 — UI was not role-aware.** 65 controls carry `data-perm`; the
  role gate hides what a role cannot use.
- **2026-08-24 — No way to administer users without SQL.** Settings → Users,
  owner-only, does names, roles, and activation.
- **2026-08-24 — Nothing prevented locking yourself out.** `guard_last_owner()`
  refuses to remove the last active owner.

## 14. Ranly is an ADDITIVE, and Redwing has it in two places (2026-08-31)

**Take this to the accountant.** Redwing's own two screens disagree about
what Ranly is:

- The **RM Inventory report** carries `Ranly TMR Mineral` under
  **Feed RM 118004**.
- The **entry form** puts `Ranly Mixing Min` on the **Mineral Application**
  template, which posts to **Mineral - WIP**.

Those are different accounts. Feed it through the Mineral screen and it
leaves an account it was never in. John's call 2026-08-31: **Ranly stays an
additive** - the app has it as `item_type = 'additive'` and that is correct;
the Redwing entry form is where it is misplaced. Nothing in the app changes.

Until it is settled, Ranly's `redwing_template_field` decides which of our
two reports it lands on, so whichever way the accountant rules, the fix is
one field on one item and no code.

Related retirements the same day: the `One Grass` box is retired, and the
`RTU Silage Premix 2025` / `RTU Silage Tran 1 2025` items are to be archived
- premixes start fresh this year. Redwing's Premix RM 118010 already carries
all three of its products at $0.00, which agrees.

## 15. Cross-system name changes still outstanding (2026-08-31)

The office app is DONE - all 21 items renamed to Redwing's product names,
`pb_name` set to match, premixes and the ghost `Corn` archived. What is left
is in the other two systems.

### Performance Beef - rename to match
| PB today | becomes |
|---|---|
| Corn hopper bin | Corn (Feed) |
| 2024 Corn Silage | Corn Silage 2024 |
| Deccox- Corrid Crumbles | Corrid Crumbles 2.5% |
| Limiter- Calcium Chloride | Limiter - Calcium Chloride |
| Pennchlor 50G | Penchlor 50gm |
| Ranly mixing mineral | Ranly TMR Mineral |
| ADM Mastergain | ADM MasterGain |
| Redmond Iodide Salt | Redmond Bag Salt |

`pb_name` is the import match key. The app already holds the NEW names, so a
PB import will not match until PB is renamed. No import runs before this is
done.

### Redwing - two changes
1. **Move Ranly to the Feed Application template.** It is an additive, not a
   mineral (John, 2026-08-31). Redwing's own two screens already disagree
   about it: the RM Inventory report carries `Ranly TMR Mineral` under Feed
   RM 118004 while the entry form posts it through Mineral Application to
   Mineral-WIP. The inventory report is right. Until the box exists on the
   Feed screen, the app maps Ranly to `Ranly Mixing Min`, so it prints on the
   Mineral report - one field on one item to change once Redwing moves it.
2. **`Redman` -> `Redmond` on the Mineral Application box label.** The product
   is `Redmond Bag Salt`; only the form field is misspelled. Redmond is the
   real brand. The app's mapping honours the typo on purpose so posting works
   today; fix the box and the mapping row changes with it.

## 16. Feed screen polish (2026-08-31)

- **Feed on hand: drag to reorder.** Grouping by bay is DONE. What John wants
  next is press-and-drag to set the order items appear WITHIN a bay, so the
  list matches the order the barn is physically walked. Needs a persisted
  `sort_order` on `feed_items` (or per item+location, if the walk order
  differs by bay - decide which before building). It should drive the printed
  COUNT SHEET too, which is the real payoff: counting in walk order instead
  of alphabetical order is what makes a count go quickly and stops lines
  being skipped.
- **Too many buttons at the top of the Feed screens.** DONE for the sub-tab
  bar 2026-09-01, to John's sketch: twelve flat tabs grouped to six. Still
  open on the CARDS themselves - Current Inventory carries By bay, Tie-out,
  Print, PDF and Refresh; Counts carries a location picker, a first-count
  checkbox, Count sheet and + Count a bay. A kebab for the print-and-export
  set would leave only the action that matters on each screen.

## 17. Feed-out dry run — PASSED 2026-09-01

Run against a replica of the live Commodity Barn (production's exact
layers, quantities and unit costs) rather than the live books, because the
opening prices are still provisional and a feed-out FREEZES cost against
whatever price is standing. The replica exercises the same RPCs on the same
schema, so the only thing it does not prove is the browser form.

1. **Future period refused.** `post_feed_usage` rejected 9/1-9/7 on 9/1:
   *period_end has not happened yet*. The guard works.
2. **FIFO drew by DATE, not by price.** DDG had two layers - 8/17 at
   $0.1250 and 8/30 at $0.1225. Feeding 60,000 lb took the OLDER and more
   expensive layer first: 51,660 @ $0.1250 = $6,457.50, then 8,340 @
   $0.1225 = $1,021.65. Total $7,479.15 across two layers.
3. **Cost froze correctly.** Corn 44,100 lb @ $0.07907499873 = $3,487.21.
4. **Routed to the right boxes.** 36-27 / `Corn` / 44,100 lb / $3,487.21 and
   36-27 / `DDGS` / 60,000 lb / $7,479.15 on the Feed Application report.
5. **The reversal restored a layer consumed to EXACTLY ZERO.** The DDG 8/17
   layer went to 0.00 and came back to 51,660 - not 103,320. That is the
   `delete_death_event` trap in feed form and it is the single most
   important line in this test.
6. Every layer back to its starting figure; 0 usage rows, 0 cost rows.

Still unproven: the browser form itself (this went through the RPCs
directly). The first real week is that test.

## 18. Purchases merged to one screen (2026-09-01)

Orders, Deliveries and Invoices were three tabs. They are not three
subjects - they are three states of ONE load, and split across three
screens the question "where is that corn?" could not be answered
anywhere. Now one list, filtered by state:

  Expected · Unpriced · Awaiting invoice · Complete

An order line not yet delivered is a row, so the list reads FORWARD in
time rather than only backward from arrival. The two old checkboxes
("Unpriced only", "Paperwork outstanding") became states in the same
filter, which is what they always were.

**Only bought loads appear.** An opening balance, count adjustment,
transfer or batch output is a layer that arrived without anybody buying
it; on the fixture they were 8 of 15 rows and buried the ones needing
action. They live on Current Inventory and Counts.

The three modals are untouched - only the lists merged - so the risk
was in the reading, not the writing.

FIXED SAME DAY: merging to one list dropped opening balances and count
adjustments from Purchases — correct, nobody bought them — but that left
them unreachable, and an opening balance is exactly what needs correcting
at cut-over. Current Inventory rows now open the layers behind them. On
hand IS the sum of the layers, so that is where they belong; putting them
back on Purchases would have re-muddied the screen the merge cleaned up.

STILL TO DECIDE after John's first real order: whether the loss of a
standalone invoice LIST matters. An invoice is visible per-load in the
Invoice column and opens from there, but "show me every bill we have
entered" now has no home. Left out deliberately to find out if it is
missed.

## 19. Cost centres — feed that no lot eats (2026-09-01)

Migration: `docs/sql/2026-09-01_cost_centers.sql`.

Commodities go to the cowherd, the bulls, the horses. The pounds are gone
and the money is spent, but there is no stocker lot to carry it and
Redwing wants a journal entry against its own account.

- **NOT `destination_type = 'adjustment'`.** That is the variance account,
  whose balance answers "how good are the shrink allowances". Real
  deliberate feeding put there destroys the only number that measures
  shrink accuracy — the same argument that keeps found feed out of it.
- **NOT `'pasture'`.** A cowherd is not a pasture and a pasture carries no
  Redwing account.
- **What came free:** `lot_feed_daily` and `feed_cost_unallocated` both read
  ONLY `destination_type = 'lot'`. A cost-centre usage draws its FIFO layer
  and freezes its cost without either view being touched, and contributes
  nothing to any lot's cost of gain. Verified: 0 rows in both.
- `post_feed_usage` was DROPPED and recreated with `p_cost_center_id`, not
  overloaded — PostgREST resolves by argument name. The verify block
  asserts exactly one exists.
- The shape CHECK pins `cost_center_id` to NULL on every other destination,
  so a lot feed-out cannot carry a stray centre and land on two reports.
- **The orphan guard.** The Redwing screen now lists any usage whose
  destination no section covers, instead of dropping it. Feed must never
  leave inventory and appear nowhere; this is the same promise
  `feed_cost_unallocated` makes on the other side.

STILL OPEN: the range-cube allocation (John is studying it). The shape is
count-based consumption like mineral, but `post_feed_count` spreads across
EVERY open lot with head-days and cubes only go to cattle on grass — so
consumption allocation needs a scope before that can be used.

---

## 20. Redwing tie-out at 9/1 — 11 of 18 lines tie (2026-09-01)

Applied: `docs/sql/2026-09-01_corn_to_redwing_0901.sql`. Corn now reads
866,380 lb / $74,298.39 at **$171.51/ton**, matching Redwing.

**The corn round trip is worth remembering.** The 8/31 alignment moved corn
to 854,832.50 lb off Redwing's sheet of that date. Redwing has since
superseded that with 866,380.00 — which is where the app already was — so
that step moved corn AWAY from Redwing rather than toward it. The dollars
were never in dispute: a cent apart the whole way. **A figure read off a
report dated the same day you act on it can still be stale.** Tie the
DOLLARS first — they were the stable side here — and treat a quantity that
disagrees while the money agrees as a units or timing question, not a
valuation one.

Where it stands, with 18 lb and $21,019.33 between the two systems:

| difference | amount | whose |
|---|---|---|
| Corn Silage 2026 | $19,154.60, no pounds | Redwing — John fixing this month |
| Salt | $1,864.19 on a **blank** Feed RM line | Redwing |
| Four barn-count adjustments | 18 lb net | Redwing should move to us |
| Corrid Crumbles | 54¢ | rounding, no entry |

- **Salt is the same typed-box cause as the silage.** Quantities agree at
  1,000 lb; the value sits on a nameless row at the top of the Feed RM
  section because the $ and lb boxes were typed separately. Redwing's own
  stated totals include that blank line, which is why its Feed RM total ties
  to this comparison while the Salt row does not.
- **The 18 lb is DDG +8, SoyHull +11, Whole Cottonseed +2, Peanut Hulls −3**
  — the 8/31 barn walk. The count is the physical fact; Redwing has not taken
  them up.

Comparison PDF built 2026-09-01 from the live books against the Redwing RM
Inventory to 9/1/2026.
