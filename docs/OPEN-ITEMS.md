# Open items

Things known to need attention, and deliberately not done yet. Ordered by when
they will bite, not by size.

**Last reviewed:** 2026-08-25

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

## Closed

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
