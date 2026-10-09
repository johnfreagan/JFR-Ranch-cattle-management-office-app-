-- 2026-10-09c  Load-out tickets staged from a photo, approved in the office.
--
-- John, 2026-10-09: the seller's paper load-out ticket (Bar T Bar Cattle Co,
-- Jake Taylor) arrives as a text-message photo. He pastes it into a Claude
-- session; Claude reads it and stages it; the office approves it in
-- Approvals > Load outs, which opens the normal load-out form filled from
-- the ticket. Nothing reaches the books until that form is saved.
--
-- The staging row is a pending_field_entries row with entry_type
-- 'load_out', so it gets the queue's existing status guard
-- (pfe_guard_settled: pending -> approved | rejected, approved is terminal),
-- RLS and reviewer stamps. This migration only widens the entry_type check.
--
-- Shape of a load_out row (docs/architecture.md, "Load-out tickets"):
--   client_id       'ticket:<order#>:<YYYY-MM-DD>:<tag_start>-<tag_end>'
--                   (the upsert key, so re-staging the same ticket is a no-op)
--   raw             what was read off the ticket, never edited afterwards
--   lot_id          the lot the order # maps to
--   head_count      head on the ticket
--   event_datetime  ticket date, noon Central
--   resolved_detail { ticket_photo: data URL } until approval moves the
--                   photo to the load out's attachments and clears it
--   approved_ref    { table: 'delivery_receipts', id } once saved
--
-- The field app reads every staged row for its day report; it skips
-- load_out rows (field-app v25). The photo is kept out of raw for the same
-- reason: phones download raw, not resolved_detail.

begin;

alter table public.pending_field_entries drop constraint if exists pfe_entry_type_check;
alter table public.pending_field_entries add constraint pfe_entry_type_check
    check (entry_type = any (array['doctoring'::text, 'move'::text, 'count'::text,
                                   'weight'::text, 'load_out'::text]));

commit;
