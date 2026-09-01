# Open items

Things known to need attention, and deliberately not done yet. Ordered by when
they will bite, not by size.

**Last reviewed:** 2026-08-28

Anything finished moves to the bottom under *Closed* with the date, so the
history of what was decided survives.

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

**Status:** wanted, not designed. Raised by John 2026-08-26.

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
