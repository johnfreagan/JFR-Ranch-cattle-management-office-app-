# Open items

Things known to need attention, and deliberately not done yet. Ordered by when
they will bite, not by size.

**Last reviewed:** 2026-08-26

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

## 8. The RLS verify script does not exist

**Status:** open, and it is cited as mandatory in two places.

`CLAUDE.md` rule 7 and `docs/security-model.md` §4 both used to cite
`supabase/migrations/20260821000300_rls_verify.sql` as a thing you run.
**There is no `supabase/` directory in the repo at all**, and there never was
one here. Both files were corrected on 2026-08-26 to say so; the list of
assertions in `security-model.md` §4 is now the *specification* for the script
rather than a description of one that exists. Every migration since has either
skipped the check or, as with `2026-08-25_budget_and_head_days.sql`, inlined
its own assertions.

Inline assertions are better than nothing but they only cover the objects
that migration touched. Nothing sweeps the whole schema for a view missing
`security_invoker`, a table with RLS enabled and no policy, or a fresh grant
to `anon`.

**The fix:** write it once as a standalone script that asserts rules 1–6
across every object in `public`, and run it after each migration. Until then
every new migration must carry its own checks.

A manual sweep on **2026-08-26** came back clean — 28 tables all RLS-enabled
and all carrying policies, 12 views all `security_invoker = true`, zero objects
in `public` readable by `anon`, seven `SECURITY DEFINER` functions all with a
pinned `search_path`. That is exactly the sweep the script should automate, and
running it by hand is exactly why it keeps not getting run.

---

## 9. Cost assumptions are missing or wrong on live lots

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

## Closed

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
- **2026-08-24 — UI was not role-aware.** Controls carry `data-perm` and the
  role gate hides what a role cannot use. **77 as of 2026-08-26** — 69
  `office`, 8 `owner`; it was 65 when this was closed, and it grows with every
  new write control, which is the point.
- **2026-08-24 — No way to administer users without SQL.** Settings → Users,
  owner-only, does names, roles, and activation.
- **2026-08-24 — Nothing prevented locking yourself out.** `guard_last_owner()`
  refuses to remove the last active owner.
