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
