# Cost of gain on the closeout — decisions of 2026-09-11

The critique that started this is summarised at the foot. Everything here
was settled with John in one sitting, one branch at a time. All eight items built and applied 2026-09-11, in the order at the end.

The frame for every decision: the Redwing cost ledger (roadmap item 4,
"will happen in October") is the only thing that turns cost of gain from a
typed rate into a cost. Until then the closeout's COG and Labor lines are
`rate × real head-days`, and the screen has to say so.

## 1. End state: actuals replace the rate month by month

Once the ledger posts a month, that month's head-days switch from the assumed
rate to the actual $/head-day. Days the ledger has not covered stay on the
assumption. Same pattern doctoring and feed already follow. The per-lb
machinery therefore survives and is worth fixing; it is not scaffolding to be
torn down.

John's words: *"cost per head day at the point we have actual cost is most
accurate way to present info. Then have a presumed cog # from estimated avg
daily gain. The avg daily gain number trues up as weights are entered."*

## 2. The ADG that converts $/lb into a cost

For head-days not yet covered by a real weigh-out, use the lot's **realized**
ADG once **25% of sold head carry pay weights**; the target ADG before that.
A 6-head cull sale must not re-base a 369-head lot. Doctoring and feed already
switch to the lot's own number once there is history; COG was the one line
that did not.

**What trues ADG:** sale pay weights and **whole-lot weighings**
(`weights.coverage = 'whole_lot'`, the anchor rule). **Never samples.** A
20-head trap draft is the gentle cattle full of grass, the same reason it
cannot anchor projected weight.

## 3. Sales without a pay weight

Flag on the closeout in amber: *"N head sold with no pay weight — gain still
estimated."* **Close Lot refuses** until every sale carries a pay weight or is
marked `no scale ticket` deliberately. A closed lot on an estimated cost of
gain is a finished number that is not finished.

37X-1 (189 of 255 sold head unweighed) and 47-26 (none, closed) are being
fixed from the buyer sheets in a parallel session (2026-09-11).

## 4. Feed boundary: switch it on now

Barn feed has been fed direct since 2026-09-01 and 60X carries $527 of it as
a memo while its COG charges $0.70/lb as if feed were inside. The boundary
code (`feedDirectFrom`, `hdAfter`, `nonFeedCog`, `cogSplit`) has never run on
data. **Switch it on for lots fed since Sept 1.** It is the month-by-month
replacement pattern of §1, exercised on one category with real dollars before
the ledger arrives — find the bugs on $527, not on $50,000.

**Non-feed rate:** one **ranch-level default in $/head-day**, overridable per
lot, **excluding labor** (which has its own line) and feed. No hard number
exists yet, so it is a **placeholder: $0.50/head-day**, marked *placeholder*
in amber on the settings screen until a real figure is typed. The reasoning:
the COG rates imply about $1.00/head-day all-in (0.5556 × 1.8); 60X's real
barn feed alone runs $2.24/head-day since Sept 1, so the old rate never held
barn feed anyway; $0.50 for pasture, mineral, fuel and overhead is a round
guess the ledger replaces.

## 5. Finish weight

The closeout prefills from the **anchored projection walked to the ship date**
(`lot_projected_weight_detail`, anchor + `lot_adg_phases`), not from weight
in + days × ADG. One weight projection in the app; a whole-lot weighing moves
the closeout's revenue on the head left the same day it moves the tile. The
box stays editable for a deliberate override.

## 6. COG modes

Migrate every lot and frozen budget to `per_lb` in one guarded statement
(37X-1 is the only lot still stored `per_day`; its converted rate is already
on screen) and **delete the `per_day` and `per_head` branches** from
`closeoutActual`, `cogAt`, `closeoutBudget` and `ltStoredRates`. The transfer
basis then cannot disagree with the screen.

## 7. Assumption log — on Save only

The closeout inputs are John's scratch pad: typing recalculates live and is a
what-if, not a change of expectation. So: **log on Save only**, old and new
for every `assumed_*` / `target_*` column, who and when, into
`lot_assumption_history` via a trigger on `lots`, shown on the Audit log tab.
The screen shows an **"unsaved what-if"** marker whenever a box differs from
the stored value, with a **Reset to saved** button.

## 8. Drift checks on the Anomalies report

Two low-severity findings: **COG or ADG more than 25% off the open-lot
median** (47-26 and 60X at $0.70 against $0.50–0.56), and **a frozen budget
more than 25% off the working rate** (60X's budget says $1.00/lb). Quiet as
soon as the number is deliberate.

## 9. The gain tile

Rename to **"Operating cost per lb gained"**. One gain number,
`actual.gainToDateLb`, the same pounds the COG row prints. Numerator is
doctoring + feed + labor + the COG charge; **processing comes out** (per head
in, spent at the chute). A second line reads *"of which assumed COG $x.xx/lb"*
so the guessed share is visible and shrinks as ledger months post.

## 10. Honesty items

- COG and Labor rows carry a **`rate × real head-days`** tag, which becomes
  *"ledger to <month>"* as actuals post.
- The ADG warning fires **both directions**, with the dollar effect on the
  COG line. 37X is 18% below its assumption and got silence.
- **Gain is clamped at zero**, and the note says so when it happens.

## 11. Ledger shape — deferred to October

Decided when the import is built, with a deep dive on real inputs. Everything
above is built so that a `(lot, month, category, dollars)` table can slot in
without disturbing the typed assumptions, but the allocation rules (head-days
only, or ranch-specific costs to the lots standing there) are NOT decided.

## What we live with until October

- COG and Labor are rates, not costs. The tag in §10 says so on screen.
- The non-feed rate is a $0.50 placeholder.
- The estimated gain on unsettled head-days uses an ADG, realized or target,
  not a scale weight. Every weigh-out shrinks that slice.

## Build order

1. §10 honesty items + §9 gain tile + §3 flag (one commit: nothing changes
   the numbers except the clamp; everything gets labelled).
2. §2 realized-ADG rule (changes COG on 37X, 37X-1, 37X-F).
3. §6 mode migration (SQL + code deletion).
4. §5 finish weight from the anchor.
5. §4 feed boundary on: ranch default setting, placeholder, per-lot override
   wired, verified on 60X.
6. §7 assumption history (trigger + audit tab + what-if marker).
7. §8 anomalies.
8. §3 Close Lot refusal (last, after the parallel session lands the pay
   weights, so it does not fire on the day it ships).

## The critique this answers (2026-09-11)

COG was a typed rate presented in a column called Actual; the gain estimate
ignored the lot's realized ADG; the ADG warning was one-directional; unweighed
sales left the estimate in place silently; two gain figures on one screen; a
circular gain tile; finish weight disagreed with the anchored projection;
negative gain unclamped; an estimate frozen into a transfer basis; three COG
modes for one input; the feed boundary unrun; assumptions rewriting Actual
with no trail; no drift checks across lots.
