# Tally Book

A daily bullet journal. Separate PWA living in this repo alongside
`field-app/`, sharing the ranch's Supabase project and its sign-in.

- **Live at** `https://johnfreagan.github.io/JFR-Ranch-cattle-management-office-app-/tally-book/`
- **Schema** `docs/sql/2026-08-28_tally_book_v2.sql`
- **Tables** `tally_days`, `tally_book` — both RLS-scoped to `auth.uid()`

The app is John's "JFR Tally Book" artifact, ported. Day page, migration
ritual, delegation, sub-steps, collections, repeats, trackers, month and
future logs, natural-language dates ("tomorrow 7am", "every friday"), voice
capture. All of that is the artifact's own code, unchanged. What the port
replaced is where it keeps things.

## Moving your existing book across

The artifact kept the book in its own published page, rebuilding and
republishing its HTML with the state baked in. **That sync never once
succeeded** — the published copy reads `days:{}` with `updatedAt` at the
epoch — so the whole book has been living in one browser's `localStorage`
with no copy anywhere.

To bring it over, once the schema is applied:

1. Open the artifact, **More → Export**, copy the JSON.
2. Open this app, sign in, **More → Restore**, paste it.

The state shape is preserved end to end, so delegation, sub-steps, trackers
and collections all survive. There is no hand-written mapping to get wrong.

## Storage

`localStorage` is the local cache — it paints instantly and keeps the book
usable with no signal. Supabase is the record.

```
tally_days   one row per day    { entries: [...], reflect: "..." }
tally_book   one row per key    colls · months · rules · people · inbox
                                trackers · track · settings · lots
```

Per day rather than one document because that is the conflict boundary. One
blob is last-writer-wins over the whole book: a phone out of signal all day
syncs on the way home and silently overwrites what you did on the laptop.
Per day, a sync only touches the days that actually changed.

**What gets pushed is found by diffing** against a snapshot of the last
successful sync, not by having each of `touch()`'s ~50 call sites say what it
changed. A call site that forgot would be an entry that never leaves the
phone, and you would not find out until you looked for it somewhere else.

**A locally dirty day is never overwritten by the remote copy.** You are
typing on this device; discarding that to honour a row written elsewhere is
the one outcome that loses work you can see. Local wins and is pushed
straight after.

The dot beside the date is the sync state — green when the book is up, amber
when this device is holding changes. Tap it to sync now.

## Deploy

Commit and push to `main`; GitHub Pages picks it up in 1–3 minutes. No build
step, no separate Pages configuration.

**Bump these together on every deploy** or an installed copy pairs a new page
with old code:

1. `CACHE_VERSION` in `sw.js`
2. the `?v=` query strings in `index.html`
3. the matching strings in `sw.js`'s `APP_SHELL`

The shell is network-first, so an online device gets the new version on the
next load; the cache is only the offline fallback.

## Schema

Paste `docs/sql/2026-08-28_tally_book_v2.sql` into the Supabase SQL editor.
Idempotent, and it ends in a `DO` block that raises if RLS, the policies, the
grants or the `updated_at` triggers did not land.

Not `supabase db push` — this remote has no CLI migration history (CLAUDE.md,
"Migrations"), and the CLI is not installed on the Mac.

Re-run `supabase/migrations/20260821000300_rls_verify.sql` afterwards, per
CLAUDE.md rule 7.

## Access

Every row is scoped to whoever wrote it: `user_id` defaults to `auth.uid()`,
and both policies are `USING (user_id = auth.uid())` with a matching
`WITH CHECK`. Lauren is an owner on the ranch books and still cannot see this
one — a role is not a shared diary.

Sign-in is shared: all three apps sit on one origin and use Supabase's
default storage key, so signing into the office app signs you into this one,
and signing out here signs you out of all of them. Both local stores are
purged on sign-out and whenever a different account signs in on the same
device — `localStorage` knows nothing about RLS.

## Not built

- **No offline write queue.** Entries survive offline in `localStorage` and go
  up on the next sync, which covers the ordinary case. What is missing is a
  dead-letter path for a write the database later refuses.
- The Lots tab still reads a pasted export. Wiring it to the real ranch views
  is a separate job.
