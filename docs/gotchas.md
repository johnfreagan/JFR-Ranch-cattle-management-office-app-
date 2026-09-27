# Gotchas: costly lessons

_Moved word for word from `CLAUDE.md` on 2026-09-27, when CLAUDE.md became a short index. Nothing here was rewritten; section dates are the dates the rules were written._

Each of these cost real time or real books to learn. More are kept beside the feature they bit, in the other docs.

## Schema landmines (verified by painful trial and error — trust these)

- `doctoring_events.tag_number` is TEXT. `lot_tags.tag_number` is INTEGER.
  **Tag format (2026-09-27, `docs/sql/2026-09-27c_tag_format.sql`):** the four
  TEXT tag columns (`doctoring_events`, `lot_events`, `pending_field_entries`,
  `feed_pen_removals`) carry a CHECK: NULL, plain digits with no leading zero,
  or `NT<n>` — `^([1-9][0-9]*|NT[0-9]+)$`. NT<n> numbers an untagged animal
  per lot and `no_tag` is set with it. **Match a text tag to `lot_tags` only
  through `public.tag_to_int()`** (SQL) or `tagToInt()` (both apps): digits →
  integer, anything else → NULL, so an NT tag never matches — correct, they
  are the untagged head. Never `parseInt` a tag (`'12abc'` → 12). The
  office's NT checkbox used to write the placeholder `NT?`, which saved as-is;
  it now fills the lot's next NT<n>, and approvals post an empty / bare `NT`
  tag the same way. The one live `NT?` (37X, 2026-01-05) became NT1.
  **Open:** the field app's NT button numbers from the phone's own records,
  not per lot, so two phones can both hand out NT1 on one lot.
- `doctoring_events` uses `recorded_by_user_id`; has NO updated_at.
- `lot_events` uses `created_by`; has NO updated_at.
- `lot_pasture_assignments` uses `recorded_by`.
- Meds junction table is `doctoring_event_meds` (NOT doctoring_medications).
- `load_out_destinations` FK to receipts is `receipt_id`.
- `sales` has BOTH gross_weight_lb and net_weight_lb — realized ADG and pay
  weights use **net**.
- `field_protocols` has default_med_1/2/3_id but NO dose columns.
- `lot_pasture_assignments` uses `moved_in` / `moved_out` — NOT date_in/date_out.
  An OPEN assignment is `moved_out is null`.
- `pastures.name` — NOT pasture_name. `lots` has no `status` column; open means
  `closed_at is null`. Head counts live on the `lot_status` VIEW, not on `lots`.
- **`lot_status` is keyed on `lot_id`, NOT `id`.** Getting this wrong does not
  throw in the app: PostgREST returns an error, the destructured `data` comes
  back undefined, and the code quietly does nothing. Two live instances were
  found 2026-08-26 — one in the shipment save and one that had been sitting in
  the single-lot sale form, which is why its "this lot is empty, close it?"
  prompt had apparently never fired. In SQL it throws honestly
  (`column ls.id does not exist`), which is how the shipment reversal's
  version was caught. Always check `error` on a `lot_status` read.
- **The database runs UTC; the ranch does not.** `CURRENT_DATE` becomes
  tomorrow at 7pm Central (6pm in CST), so anything that counts days must use
  `public.ranch_today()` instead. `lot_daily_head` shipped with `CURRENT_DATE`
  and gained a whole extra day of head-days each evening — 441 on 36-27,
  $882 at its rate, for a day Texas had not had. The app matches it with
  `ranchToday()`, pinned to `America/Chicago` rather than the viewer's clock.
  Same trap as `toISOString()` in the field app.
- **There are TWO head-day implementations and they disagree.** The FUNCTION
  `lot_head_days(uuid, date)` anchors on `lot_weighted_arrival_date()`, which
  is built from INVOICE dates. The VIEW `lot_head_days_by_month` (over
  `lot_daily_head`) walks arrivals by RECEIPT date. Where invoices follow
  receipts closely they agree within ~1%; on 36-27 the function read 2,646
  against the view's 3,424, 29% low, because the cattle landed Aug 11 and the
  invoices weighted to Aug 19. **Use the view for anything involving cost** —
  cattle eat from the day they hit the ground.
- `lot_daily_head` reconciles to `lot_status.head_current` by construction and
  is verified to do so on every lot. Head-day math must NOT be built on
  `lot_pasture_assignments`: 37X's assignment history starts 2026-04-27
  against a first invoice of 2025-12-04, so it would silently drop 144 days.
- `pending_field_entries` has `reviewed_at`/`reviewed_by` and an `approved_ref`
  jsonb (`{kind, id}`) — there is no `approved_at`.
- Supabase PostgREST caps results at 1000 rows — PAGINATE lot_tags and any
  large fetch. **PostgREST query builders are single-use** — a pager must take
  a builder *function* and call it fresh per page, not reuse one object.
- `lots.start_tag` / `end_tag` describe the FIRST receipt only, not the lot's
  whole tag range. To resolve a tag to a lot, go lot_tags → receipt ranges →
  and only then fall back to lots.start_tag/end_tag.
- **The Supabase SQL editor swallows `begin;`/`commit;`** — a wrapped script
  can report "Success. No rows returned" without applying anything. Omit the
  wrapper when pasting into the editor; keep it in files meant for the CLI.
- **The MCP Supabase connector is READ-WRITE as of 2026-09-10** (it ran as
  `postgres` with `transaction_read_only = off`; the processing-protocol
  migration was applied through it). It was read-only before, failing DDL
  and DML with `25006`. Writes still need John's explicit approval first —
  show findings, propose, wait — and a multi-statement batch runs as ONE
  transaction, so a type error in the last view rolls back the first
  UPDATE too (seen 2026-09-10; verify state before re-running). When the
  connector is read-only again, give John pasteable SQL in chat — not a
  file attachment, not a path. He has said so twice.
  **Transcription is the new risk when a migration goes through
  `apply_migration`.** The SQL reaches the tool as a typed parameter, not as a
  file, so a long migration is retyped by hand and a one-character slip is
  silent. `apply_migration` also supplies its OWN transaction, so strip
  `begin;`/`commit;` first — the inner `commit;` closes the wrapper early, the
  same trap the CLI has. After applying, prove it: build the same file on a
  scratch PostgreSQL (`initdb` as the `postgres` user; server binaries live in
  `/usr/lib/postgresql/16/bin`) and compare `md5(prosrc)` per function against
  the live database. Equal hashes mean the transcription was exact — that check
  is what cleared the strays migration on 2026-09-10.
- When unsure of a column name, QUERY information_schema — do not guess.
  Schemas evolved inconsistently across tables.
  **Exception: do NOT trust information_schema for GRANTS or PRIVILEGES.**
  `role_table_grants` only shows roles the *querying* user belongs to, so on
  hosted Supabase it returns an empty set for `anon` while `anon` in fact holds
  full grants. Use `has_table_privilege()` / `pg_class.relacl` for privileges.
  Columns and types are fine.
