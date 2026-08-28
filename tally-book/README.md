# Tally Book

Daily bullet journal + project status register. A separate PWA living in this
repo alongside `field-app/`, sharing the ranch's Supabase project and its
sign-in.

- **Live at** `https://johnfreagan.github.io/JFR-Ranch-cattle-management-office-app-/tally-book/`
- **Schema** `docs/sql/2026-08-28_tally_book.sql`
- **Tables** `tally_entries`, `tally_projects` — RLS-scoped to `auth.uid()`

## Deploy

Same as the rest of the repo: commit and push to `main`, GitHub Pages picks it
up in 1–3 minutes. There is no build step and no separate Pages configuration.

**Bump three things together on every deploy** or installed copies pair a new
page with old code:

1. `CACHE_VERSION` in `sw.js`
2. the `?v=` query strings in `index.html` (`app.js`, `styles.css`)
3. the matching strings in `sw.js`'s `APP_SHELL`

The shell is network-first, so a device that is online gets the new version on
the next load. The cache is only the offline fallback.

## Schema

Paste `docs/sql/2026-08-28_tally_book.sql` into the Supabase SQL editor. It is
idempotent and ends in a `DO` block that raises if RLS, the policies or the
grants did not land.

Not `supabase db push` — this remote has no CLI migration history (see
CLAUDE.md, "Migrations"), and the CLI is not installed on the Mac anyway.

Re-run `supabase/migrations/20260821000300_rls_verify.sql` afterwards, per
CLAUDE.md rule 7.

## Access

RLS scopes every row to the user who wrote it: `user_id` defaults to
`auth.uid()`, and both policies are `USING (user_id = auth.uid())` with a
matching `WITH CHECK`. Lauren is an owner on the ranch books and still cannot
see this book — a role is not a shared diary.

Widening it to all owners later is a policy swap, not a rewrite:

```sql
using (public.current_user_role() = 'owner')
```

Sign-in is shared. All three apps sit on one origin and use Supabase's default
storage key, so signing into the office app signs you into this one — and
signing out here signs you out of all of them. The button says so.

## What's built

- **Morning triage** — open loops (`status='open'`, dated before today) and the
  untriaged rapid-log bucket (`type IS NULL`, the landing zone for future
  Siri/Reminders/email capture), each with one-tap dispositions.
- **Rapid log entry** — type, content, priority stamp.
- **Today's log** — the day's entries; done is reversible with *undo*.
- **Project register** — tap a card to edit status, next action, blocked-on and
  target date.
- **Offline app shell** — service worker; Supabase calls stay network-only.

## What changed from the handed-over draft

Five things, all of which would have bitten:

- **RLS.** The draft shipped `-- no RLS - single-user app`. These tables live in
  the ranch database, whose `postgres` default ACL grants `authenticated` full
  DML on new public tables — so every crew cowboy could have read and written
  this journal through PostgREST.
- **`toISOString()`.** The whole app keys on one date value. In UTC that rolls
  over at 7pm Central: today's log empties and everything just written jumps
  into "open loops". Now pinned to `America/Chicago`, matching the office app
  and `public.ranch_today()`.
- **"→ today" lost the entry.** It set `status='migrated'`, but open loops
  query `status='open'` — a task pushed forward and not finished that day
  disappeared from the book for good. Status stays `open`; `migrated` describes
  how a bullet arrived, not whether it is still owed.
- **Cache-first service worker.** Fixed cache name, cache-first: every installed
  copy served the version it first saw. This is the bug `field-app/sw.js`
  already fixed the hard way, so this one is a copy of that.
- **Silent failures.** Every error went to `console.error`, which a phone cannot
  show. A refused write also returns an empty result and no error at all
  (docs/OPEN-ITEMS.md item 3), so every write here asserts on the returned rows
  and both paths surface in a banner.

Smaller: `projects` → `tally_projects` (`projects` is a broad name to squat in a
ranch schema); the seed's `on conflict do nothing` had no unique constraint to
conflict against, so re-running duplicated it; kill is a status rather than a
DELETE, because a mis-tap on a phone should not be unrecoverable; the CDN
`esm.sh` import is vendored to `supabase.min.js`, since an ESM import is the one
asset a service worker cannot cache and "offline" would have meant a blank page.

Added: inline project editing. A register that needs the SQL editor to update
is a decoration.

## Not yet built

- Weekly migration ritual, future log, monthly log (Phase 4)
- Search / index, trackers, collections (Phase 5)
- Siri Shortcut capture (Phase 3)
- Gmail triage write path (Phase 6)
- Apple Reminders capture (Phase 7)
- Cattle lot summary panel (Phase 8)

No offline write queue. Entries made with no signal are lost, unlike the field
app, which persists a queue. Worth adding before this is relied on out of cell
range — the pattern is already in `field-app/app.js`.
