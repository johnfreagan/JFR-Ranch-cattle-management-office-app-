-- =====================================================================
-- Strays and missing head — a write-off that is not a death, and a way
-- back for the ones that turn up
-- =====================================================================
-- Design record with every decision and the rejected alternatives:
--   docs/stray-cattle-design.md
--
-- THE PROBLEM, from the live books. Lot 47-26 was closed on 2026-09-03 by
-- writing off 2 head as a DEATH, cause 'missing from shipping', note
-- "unaccounted for at shipping removed to close lot. jfr". Nothing died.
-- Filing a missing animal as a death:
--   * puts it in the mortality rate, the death-timing card and the
--     pull-failure denominators of the Doctoring & Deaths report;
--   * charges it to the closeout's death-loss line; and
--   * leaves deleting a death that never happened as the ONLY way to
--     bring the animal back if it walks out of a thicket in October.
--
-- The feed pen settled exactly this question on 2026-09-07 — butchered
-- and missing are negative 'adjustment' events with a cause, never new
-- event types and never deaths — and that ruling simply never reached
-- ordinary lots. This migration takes it there, and adds the symmetric
-- entry for a head that comes back.
--
--   missing out   ->  negative adjustment, cause 'missing'
--   stray back in ->  positive adjustment, cause 'stray_return'
--
-- NO NEW EVENT TYPE AND NO NEW TABLE. 'adjustment' is already signed,
-- already summed by lot_status.head_current and lot_daily_head, and
-- already reversible. A new type would mean teaching both of those views
-- — which every dollar in the app is built on — a new word.
--
-- WHAT THIS DOES NOT DO: it never reopens a closed lot. A stray off a lot
-- that is closed, or off no lot anyone can name, goes into the FEED PEN at
-- a $0 basis through record_feed_pen_opening, which already exists and
-- whose source lot is already nullable for precisely this case. Reopening
-- a closed lot moves lot_daily_head's end_date off closed_at and
-- un-finalises a fiscal year that has already been reported.
--
-- Idempotent. Paste into the SQL editor WITHOUT the begin/commit lines
-- (the editor swallows them and reports success without applying).
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. record_missing_head — head that left the lot without dying
-- ---------------------------------------------------------------------
-- Decision 1. Shaped deliberately like record_death_with_pasture: same
-- pasture drawdown, same "close the assignment when it empties, leaving
-- head_count where it was" behaviour, so delete_head_adjustment below can
-- reverse it with the same logic delete_death_event uses — including the
-- fix that a REOPENED assignment takes exactly the head coming back and is
-- never added to (2026-08-25; 3 head died, the reversal gave back 6).
--
-- INVOKER, like every other head-math RPC. Office and owner hold the
-- INSERT and UPDATE policies on lot_events and lot_pasture_assignments;
-- crew and accountant are refused by RLS and get a real error, not a
-- silent no-op.
CREATE OR REPLACE FUNCTION public.record_missing_head(
    p_lot_id      UUID,
    p_pasture_id  UUID,
    p_head        INTEGER,
    p_event_date  DATE DEFAULT NULL,
    p_tag_number  TEXT DEFAULT NULL,
    p_notes       TEXT DEFAULT NULL,
    p_recorded_by UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_lot_no    TEXT;
    v_closed    TIMESTAMPTZ;
    v_is_pen    BOOLEAN;
    v_date      DATE;
    v_assign    UUID;
    v_assign_hd INTEGER;
    v_event     UUID;
BEGIN
    SELECT lot_number, closed_at, is_feed_pen
      INTO v_lot_no, v_closed, v_is_pen
      FROM public.lots WHERE id = p_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Lot % not found.', p_lot_id;
    END IF;
    IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Lot % is closed. Re-open it before writing head off.', v_lot_no;
    END IF;

    -- The pen has its own exit path, which freezes the pen cost against the
    -- source lots BEFORE the head math lands and writes the attribution
    -- ledger. A bare adjustment here would skip both.
    IF COALESCE(v_is_pen, FALSE) THEN
        RAISE EXCEPTION 'Cattle leave the feed pen through Record removal (method "missing"), not a head adjustment.';
    END IF;

    IF COALESCE(p_head, 0) <= 0 THEN
        RAISE EXCEPTION 'Head must be positive (got %).', p_head;
    END IF;

    v_date := COALESCE(p_event_date, public.ranch_today());
    IF v_date > public.ranch_today() THEN
        RAISE EXCEPTION 'Date % is in the future (ranch today is %).', v_date, public.ranch_today();
    END IF;

    SELECT id, head_count INTO v_assign, v_assign_hd
      FROM public.lot_pasture_assignments
     WHERE lot_id = p_lot_id AND pasture_id = p_pasture_id AND moved_out IS NULL;
    IF v_assign IS NULL THEN
        RAISE EXCEPTION 'No open pasture assignment for lot % at that pasture.', v_lot_no;
    END IF;
    IF p_head > v_assign_hd THEN
        RAISE EXCEPTION 'Cannot write off % head from a pasture holding only %.', p_head, v_assign_hd;
    END IF;

    INSERT INTO public.lot_events (
        lot_id, event_date, event_type, head_count, tag_number, cause,
        pasture_id, notes, created_by
    ) VALUES (
        p_lot_id, v_date, 'adjustment', -p_head, p_tag_number, 'missing',
        p_pasture_id,
        COALESCE(p_notes, 'Unaccounted for. Written off as missing, not as a death.'),
        p_recorded_by
    ) RETURNING id INTO v_event;

    -- Close the assignment when it empties and LEAVE head_count intact —
    -- the same contract record_death_with_pasture keeps, and what the
    -- reversal depends on.
    IF v_assign_hd - p_head = 0 THEN
        UPDATE public.lot_pasture_assignments SET moved_out = v_date WHERE id = v_assign;
    ELSE
        UPDATE public.lot_pasture_assignments SET head_count = v_assign_hd - p_head WHERE id = v_assign;
    END IF;

    RETURN v_event;
END;
$fn$;

COMMENT ON FUNCTION public.record_missing_head IS
    'Head unaccounted for: a NEGATIVE adjustment with cause ''missing'', plus the pasture drawdown, atomically. Deliberately not a death — a death lands in the mortality rate, the death-timing card and the pull-failure denominators. INVOKER.';


-- ---------------------------------------------------------------------
-- 2. record_stray_return — a head that turns up again
-- ---------------------------------------------------------------------
-- Decision 2. The mirror image: a POSITIVE adjustment dated the day the
-- animal was found, plus the pasture it is standing in.
--
-- WHY NOT JUST DELETE THE WRITE-OFF. Deleting it is right when the entry
-- was simply wrong and the mistake is fresh — that is what
-- delete_head_adjustment (and delete_death_event) are for, and the app
-- offers it. It is WRONG once time has passed, because lot_daily_head
-- would hand the lot every head-day back to the date of the write-off,
-- silently re-pricing feed, cost of gain, labor and treatment on every day
-- since for an animal nobody was feeding. A stray that comes back after
-- months is a new fact on a new date, not a correction of an old one.
--
-- WHY THE HEAD ARRIVES AT NO COST. The lot has already spent everything it
-- is going to spend on this animal; the invoice that bought it is
-- unchanged and head_in never moves. Nothing is added to cattle cost, so
-- the returning head is carried at $0 — the same posture the feed pen
-- takes, and the reason a lot's closeout carries a Missing line that the
-- return credits back.
--
-- A CLOSED LOT IS REFUSED, BY DESIGN. See the header.
CREATE OR REPLACE FUNCTION public.record_stray_return(
    p_lot_id      UUID,
    p_pasture_id  UUID,
    p_head        INTEGER,
    p_event_date  DATE DEFAULT NULL,
    p_tag_number  TEXT DEFAULT NULL,
    p_notes       TEXT DEFAULT NULL,
    p_recorded_by UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_lot_no  TEXT;
    v_closed  TIMESTAMPTZ;
    v_is_pen  BOOLEAN;
    v_start   DATE;
    v_date    DATE;
    v_assign  UUID;
    v_event   UUID;
BEGIN
    SELECT lot_number, closed_at, is_feed_pen
      INTO v_lot_no, v_closed, v_is_pen
      FROM public.lots WHERE id = p_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Lot % not found.', p_lot_id;
    END IF;

    IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Lot % is closed and its fiscal year has been reported. Re-opening it would move lot_daily_head''s end date off closed_at and re-open books that are finished. Put the stray in the feed pen at $0 instead, naming % as the lot it came off.',
            v_lot_no, v_lot_no;
    END IF;

    IF COALESCE(v_is_pen, FALSE) THEN
        RAISE EXCEPTION 'Head found in the feed pen go in through the pen''s own opening entry, which writes the attribution ledger this would skip.';
    END IF;

    IF COALESCE(p_head, 0) <= 0 THEN
        RAISE EXCEPTION 'Head must be positive (got %).', p_head;
    END IF;

    v_date := COALESCE(p_event_date, public.ranch_today());
    IF v_date > public.ranch_today() THEN
        RAISE EXCEPTION 'Date % is in the future (ranch today is %).', v_date, public.ranch_today();
    END IF;

    -- lot_daily_head bounds a lot by LEAST(first receipt, first invoice,
    -- first transfer_in) and CLAMPS anything earlier up to that day. A
    -- return dated before the lot existed would therefore be silently moved
    -- and charged feed from day one for an animal that was not there. The
    -- same guard record_feed_pen_opening carries, for the same reason.
    SELECT LEAST(
        COALESCE((SELECT min(r.receipt_date) FROM public.delivery_receipts r WHERE r.lot_id = p_lot_id), DATE '9999-12-31'),
        COALESCE((SELECT min(i.invoice_date)  FROM public.invoices        i WHERE i.lot_id = p_lot_id), DATE '9999-12-31'),
        COALESCE((SELECT min(e.event_date) FROM public.lot_events e
                   WHERE e.lot_id = p_lot_id AND e.event_type = 'transfer_in'), DATE '9999-12-31')
    ) INTO v_start;

    IF v_start < DATE '9999-12-31' AND v_date < v_start THEN
        RAISE EXCEPTION 'Date % is before lot % had any cattle (%). lot_daily_head would clamp it up to that day and charge feed from then on.',
            v_date, v_lot_no, v_start;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.pastures WHERE id = p_pasture_id) THEN
        RAISE EXCEPTION 'Pasture % not found.', p_pasture_id;
    END IF;

    INSERT INTO public.lot_events (
        lot_id, event_date, event_type, head_count, tag_number, cause,
        pasture_id, notes, created_by
    ) VALUES (
        p_lot_id, v_date, 'adjustment', p_head, p_tag_number, 'stray_return',
        p_pasture_id,
        COALESCE(p_notes, 'Stray back on the books. Carried at $0 — the lot already spent what it spent.'),
        p_recorded_by
    ) RETURNING id INTO v_event;

    SELECT id INTO v_assign FROM public.lot_pasture_assignments
     WHERE lot_id = p_lot_id AND pasture_id = p_pasture_id AND moved_out IS NULL;
    IF v_assign IS NULL THEN
        INSERT INTO public.lot_pasture_assignments (
            lot_id, pasture_id, head_count, moved_in, notes, recorded_by
        ) VALUES (
            p_lot_id, p_pasture_id, p_head, v_date,
            'Opened by stray return ' || v_event::text, p_recorded_by
        );
    ELSE
        UPDATE public.lot_pasture_assignments
           SET head_count = head_count + p_head WHERE id = v_assign;
    END IF;

    RETURN v_event;
END;
$fn$;

COMMENT ON FUNCTION public.record_stray_return IS
    'A stray back on an OPEN lot: a POSITIVE adjustment dated the day it was found, at $0, plus the pasture assignment. Refuses a closed lot — that stray goes to the feed pen. INVOKER.';


-- ---------------------------------------------------------------------
-- 3. delete_head_adjustment — the one reversal for all three
-- ---------------------------------------------------------------------
-- Decision 3. Missing, stray return and the feed pen's opening entry are
-- all signed adjustments carrying a pasture, so they all reverse the same
-- way and there is ONE implementation rather than three that drift.
--
-- The sign decides the direction and both directions carry a trap:
--
--   NEGATIVE (missing, like a death): head come BACK. If the event closed
--   the assignment outright, REOPEN it with exactly the head returning —
--   never add to the stored head_count, which was deliberately left where
--   it stood when the row closed. That is the delete_death_event bug, and
--   it doubled a pasture in production.
--
--   POSITIVE (stray return, pen opening): head LEAVE again. Refuse when
--   the assignment no longer holds them — they have since been moved,
--   sold or died, and silently taking the count negative would put the lot
--   into drift that surfaces days later on a report nobody connects to
--   this delete.
--
-- A pen opening's feed_pen_ledger row is removed by the FK cascade added
-- in section 5, so the pen's attribution ledger cannot be left holding
-- head the books no longer carry. feed_pen_reconciliation would catch it
-- afterwards; not creating it is better.
CREATE OR REPLACE FUNCTION public.delete_head_adjustment(p_event_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_lot_id     UUID;
    v_pasture    UUID;
    v_delta      INTEGER;   -- signed, as stored
    v_head       INTEGER;   -- absolute
    v_date       DATE;
    v_type       TEXT;
    v_cause      TEXT;
    v_by         UUID;
    v_closed     TIMESTAMPTZ;
    v_lot_no     TEXT;
    v_assign     UUID;
    v_assign_hd  INTEGER;
BEGIN
    SELECT e.lot_id, e.pasture_id, e.head_count, e.event_date, e.event_type,
           e.cause, e.created_by, l.closed_at, l.lot_number
      INTO v_lot_id, v_pasture, v_delta, v_date, v_type, v_cause, v_by, v_closed, v_lot_no
      FROM public.lot_events e
      JOIN public.lots l ON l.id = e.lot_id
     WHERE e.id = p_event_id;

    IF v_type IS NULL THEN
        RAISE EXCEPTION 'Event % not found.', p_event_id;
    END IF;
    IF v_type <> 'adjustment' THEN
        RAISE EXCEPTION 'Event % is a %, not a head adjustment. A death is reversed with delete_death_event.', p_event_id, v_type;
    END IF;
    IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Lot % is closed. Re-open it before reversing a head adjustment.', v_lot_no;
    END IF;
    IF COALESCE(v_delta, 0) = 0 THEN
        RAISE EXCEPTION 'Adjustment % carries no head.', p_event_id;
    END IF;

    v_head := abs(v_delta);

    -- No pasture attribution: nothing was moved, so there is nothing to put
    -- back. Same early exit delete_death_event takes.
    IF v_pasture IS NULL THEN
        DELETE FROM public.lot_events WHERE id = p_event_id;
        RETURN true;
    END IF;

    SELECT id, head_count INTO v_assign, v_assign_hd
      FROM public.lot_pasture_assignments
     WHERE lot_id = v_lot_id AND pasture_id = v_pasture AND moved_out IS NULL;

    IF v_delta < 0 THEN
        -- Head come back.
        IF v_assign IS NOT NULL THEN
            UPDATE public.lot_pasture_assignments
               SET head_count = v_assign_hd + v_head WHERE id = v_assign;
        ELSE
            SELECT id INTO v_assign
              FROM public.lot_pasture_assignments
             WHERE lot_id = v_lot_id AND pasture_id = v_pasture AND moved_out >= v_date
             ORDER BY moved_out ASC LIMIT 1;
            IF v_assign IS NOT NULL THEN
                -- Exactly the head coming back. The stored count is stale.
                UPDATE public.lot_pasture_assignments
                   SET moved_out = NULL, head_count = v_head WHERE id = v_assign;
            ELSE
                INSERT INTO public.lot_pasture_assignments (
                    lot_id, pasture_id, head_count, moved_in, notes, recorded_by
                ) VALUES (
                    v_lot_id, v_pasture, v_head, v_date,
                    'Auto-created reversing head adjustment ' || p_event_id::text, v_by
                );
            END IF;
        END IF;
    ELSE
        -- Head leave again.
        IF v_assign IS NULL THEN
            RAISE EXCEPTION 'The % head this entry put in that pasture are no longer standing there — the assignment has since closed. Reverse whatever moved them out first.', v_head;
        END IF;
        IF v_assign_hd < v_head THEN
            RAISE EXCEPTION 'That pasture holds only % head of lot %, and this entry added %. They have been moved, sold or died since; reverse that first.',
                v_assign_hd, v_lot_no, v_head;
        END IF;
        IF v_assign_hd - v_head = 0 THEN
            UPDATE public.lot_pasture_assignments
               SET moved_out = v_date WHERE id = v_assign;
        ELSE
            UPDATE public.lot_pasture_assignments
               SET head_count = v_assign_hd - v_head WHERE id = v_assign;
        END IF;
    END IF;

    -- feed_pen_ledger.opening_event_id cascades (section 5).
    DELETE FROM public.lot_events WHERE id = p_event_id;
    RETURN true;
END;
$fn$;

COMMENT ON FUNCTION public.delete_head_adjustment IS
    'Reverses a signed head adjustment — missing, stray return, or a feed pen opening — restoring the pasture assignment. Refuses when a positive entry''s head are no longer standing there. INVOKER.';


-- ---------------------------------------------------------------------
-- 4. The feed pen ledger learns the word 'stray'
-- ---------------------------------------------------------------------
-- Decision 4. A stray off a lot that has closed is not the same fact as a
-- calf that was standing in the pen and had never been carried anywhere,
-- and the pen's cost-by-source report is the place that difference shows.
-- Lumping them repeats the Doctoring report's lesson: three kinds of
-- missing paperwork filed as one made the gap look four times its size.
ALTER TABLE public.feed_pen_ledger DROP CONSTRAINT IF EXISTS feed_pen_ledger_entry_kind_check;
ALTER TABLE public.feed_pen_ledger
    ADD CONSTRAINT feed_pen_ledger_entry_kind_check
    CHECK (entry_kind = ANY (ARRAY['transfer_in','rollover_in','rollover_out','removal','opening','stray']));


-- ---------------------------------------------------------------------
-- 5. The ledger row learns which event created it
-- ---------------------------------------------------------------------
-- Decision 5. An opening writes a lot_events row AND a feed_pen_ledger
-- row, and until now nothing tied the two together — so an opening typed
-- wrong could not be undone without leaving the ledger holding head the
-- head math no longer carries, which is precisely the drift
-- feed_pen_reconciliation exists to shout about.
--
-- ON DELETE CASCADE rather than a DELETE inside the RPC: the guarantee
-- then holds for anyone who removes the event by any route, including a
-- future one nobody has written yet.
ALTER TABLE public.feed_pen_ledger
    ADD COLUMN IF NOT EXISTS opening_event_id UUID
        REFERENCES public.lot_events(id) ON DELETE CASCADE;

COMMENT ON COLUMN public.feed_pen_ledger.opening_event_id IS
    'The lot_events adjustment that created this opening/stray row. Cascades, so reversing the event cannot leave the attribution ledger out of step with head math.';

-- Backfill the openings written before this column existed. Matched on the
-- pen, the date, the head and the kind, and only where exactly ONE
-- candidate event exists — a guess here would attach the cascade to the
-- wrong row and delete a ledger entry that belongs to another entry.
DO $bf$
DECLARE
    r_led  RECORD;
    v_ids  UUID[];
    v_done INTEGER := 0;
    v_skip INTEGER := 0;
BEGIN
    FOR r_led IN
        SELECT id, pen_lot_id, entry_date, head_delta
          FROM public.feed_pen_ledger
         WHERE entry_kind IN ('opening','stray') AND opening_event_id IS NULL
    LOOP
        -- array_agg, not min() — there is no min(uuid) in Postgres, and the
        -- count is the point anyway: link only when the match is unambiguous.
        SELECT array_agg(e.id) INTO v_ids
          FROM public.lot_events e
         WHERE e.lot_id = r_led.pen_lot_id
           AND e.event_type = 'adjustment'
           AND e.event_date = r_led.entry_date
           AND e.head_count = r_led.head_delta
           AND COALESCE(e.cause, '') IN ('opening','stray')
           AND NOT EXISTS (SELECT 1 FROM public.feed_pen_ledger g
                            WHERE g.opening_event_id = e.id);
        IF array_length(v_ids, 1) = 1 THEN
            UPDATE public.feed_pen_ledger SET opening_event_id = v_ids[1] WHERE id = r_led.id;
            v_done := v_done + 1;
        ELSE
            v_skip := v_skip + 1;
        END IF;
    END LOOP;
    RAISE NOTICE 'feed_pen_ledger opening backfill: % linked, % left unlinked (ambiguous or no matching event).', v_done, v_skip;
END
$bf$;


-- ---------------------------------------------------------------------
-- 6. record_feed_pen_opening gains the kind, and the link
-- ---------------------------------------------------------------------
-- DROP and CREATE, never an overload. PostgREST resolves an RPC by its
-- ARGUMENT NAMES, and two candidates make that ambiguous — the lesson
-- post_feed_usage taught when it gained p_batch_id. The verify block
-- asserts exactly one remains.
-- BOTH signatures, so a re-run drops the version this migration itself
-- created. Dropping only the old one leaves the new one standing and the
-- CREATE below fails with "already exists with same argument types" — which
-- is how this file failed its own idempotency test the first time.
DROP FUNCTION IF EXISTS public.record_feed_pen_opening(UUID, UUID, INTEGER, UUID, DATE, TEXT, UUID);
DROP FUNCTION IF EXISTS public.record_feed_pen_opening(UUID, UUID, INTEGER, UUID, DATE, TEXT, UUID, TEXT);

CREATE FUNCTION public.record_feed_pen_opening(
    p_pen_lot_id    UUID,
    p_pasture_id    UUID,
    p_head          INTEGER,
    p_source_lot_id UUID,
    p_event_date    DATE DEFAULT NULL,
    p_notes         TEXT DEFAULT NULL,
    p_recorded_by   UUID DEFAULT NULL,
    p_entry_kind    TEXT DEFAULT 'opening'
) RETURNS UUID
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
    v_is_pen   BOOLEAN;
    v_closed   TIMESTAMPTZ;
    v_pen_no   TEXT;
    v_arrival  DATE;
    v_src_no   TEXT;
    v_date     DATE;
    v_kind     TEXT;
    v_assign   UUID;
    v_event    UUID;
BEGIN
    v_kind := COALESCE(NULLIF(btrim(p_entry_kind), ''), 'opening');
    IF v_kind NOT IN ('opening', 'stray') THEN
        RAISE EXCEPTION 'Entry kind must be ''opening'' (found in the pen, never carried) or ''stray'' (came back off a lot). Got %.', p_entry_kind;
    END IF;

    SELECT is_feed_pen, closed_at, lot_number, arrival_date
      INTO v_is_pen, v_closed, v_pen_no, v_arrival
      FROM public.lots WHERE id = p_pen_lot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Feed pen lot % not found.', p_pen_lot_id;
    END IF;
    IF NOT COALESCE(v_is_pen, FALSE) THEN
        RAISE EXCEPTION 'Lot % is not a feed pen. Head cannot be conjured onto an ordinary lot — correct its receipts or invoices, or use a stray return.', v_pen_no;
    END IF;
    IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Feed pen % is closed for the fiscal year.', v_pen_no;
    END IF;
    IF COALESCE(p_head, 0) <= 0 THEN
        RAISE EXCEPTION 'Head must be positive (got %).', p_head;
    END IF;

    -- A source lot is OPTIONAL. Some head genuinely came off no lot: they
    -- were never entered anywhere because there was no feed pen to put them
    -- in. Naming a lot they did not come from would be inventing a fact, so
    -- NULL is allowed and gets its own group on the cost report. A lot that
    -- IS named must exist, though — a typo'd uuid must not become a silent
    -- unattributed row. A CLOSED lot is perfectly valid here and is in fact
    -- the common case for a stray: that is the whole reason the pen takes
    -- these rather than the lot being re-opened.
    IF p_source_lot_id IS NOT NULL THEN
        SELECT lot_number INTO v_src_no FROM public.lots WHERE id = p_source_lot_id;
        IF v_src_no IS NULL THEN
            RAISE EXCEPTION 'Source lot % not found. Leave it null if these cattle came off no lot at all.', p_source_lot_id;
        END IF;
    END IF;

    v_date := COALESCE(p_event_date, public.ranch_today());
    IF v_date > public.ranch_today() THEN
        RAISE EXCEPTION 'Date % is in the future (ranch today is %).', v_date, public.ranch_today();
    END IF;
    IF v_date < v_arrival THEN
        RAISE EXCEPTION 'Date % is before feed pen % existed (%). lot_daily_head would clamp it up to the pen''s first day and charge it feed for cattle that were not there.',
            v_date, v_pen_no, v_arrival;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.pastures WHERE id = p_pasture_id) THEN
        RAISE EXCEPTION 'Pasture % not found.', p_pasture_id;
    END IF;

    INSERT INTO public.lot_events (
        lot_id, event_date, event_type, head_count, cause, pasture_id, notes, created_by
    ) VALUES (
        p_pen_lot_id, v_date, 'adjustment', p_head, v_kind, p_pasture_id,
        COALESCE(p_notes,
                 CASE WHEN v_kind = 'stray'
                      THEN 'Stray recovered after its lot had closed. In at $0; the lot it came off is an attribution, not a charge.'
                      ELSE 'Found standing in the feed pen and carried nowhere in the books. '
                           || CASE WHEN v_src_no IS NULL
                                   THEN 'Came off no lot; pen cost is reported unattributed.'
                                   ELSE 'Attributed to ' || v_src_no || ' for cost tracking only.' END
                 END),
        p_recorded_by
    ) RETURNING id INTO v_event;

    SELECT id INTO v_assign FROM public.lot_pasture_assignments
     WHERE lot_id = p_pen_lot_id AND pasture_id = p_pasture_id AND moved_out IS NULL;
    IF v_assign IS NULL THEN
        INSERT INTO public.lot_pasture_assignments (
            lot_id, pasture_id, head_count, moved_in, notes, recorded_by
        ) VALUES (
            p_pen_lot_id, p_pasture_id, p_head, v_date,
            'Opened by feed pen opening entry ' || v_event::text, p_recorded_by
        );
    ELSE
        UPDATE public.lot_pasture_assignments
           SET head_count = head_count + p_head WHERE id = v_assign;
    END IF;

    INSERT INTO public.feed_pen_ledger (
        pen_lot_id, source_lot_id, entry_date, head_delta, entry_kind,
        notes, created_by, opening_event_id
    ) VALUES (
        p_pen_lot_id, p_source_lot_id, v_date, p_head, v_kind,
        CASE WHEN v_kind = 'stray'
             THEN CASE WHEN p_source_lot_id IS NULL
                       THEN 'Stray recovered; nobody could say which lot it came off.'
                       ELSE 'Stray recovered off a lot that had already closed. Attribution, not a charge.' END
             ELSE CASE WHEN p_source_lot_id IS NULL
                       THEN 'Found in the pen, never carried in inventory and off no lot.'
                       ELSE 'Found in the pen, never carried in inventory. Source lot is an attribution, not a charge.' END
        END,
        p_recorded_by, v_event
    );

    RETURN v_event;
END;
$fn$;

COMMENT ON FUNCTION public.record_feed_pen_opening IS
    'Head onto the pen that no transfer brought: found standing there (''opening'') or a stray recovered after its lot closed (''stray''). Positive adjustment + assignment + ledger row, atomically. INVOKER. The source lot is attribution only and is never charged.';


-- ---------------------------------------------------------------------
-- 7. Grants — authenticated only, never anon, never PUBLIC
-- ---------------------------------------------------------------------
-- Postgres grants function EXECUTE to PUBLIC by default, so revoking from
-- anon alone silently does nothing. RLS on lot_events and
-- lot_pasture_assignments is what actually decides who may write; these
-- are INVOKER, so crew and accountant get a real 42501 rather than a
-- silent success.
DO $g$
DECLARE
    fn TEXT;
    fns TEXT[] := ARRAY[
        'public.record_missing_head(UUID,UUID,INTEGER,DATE,TEXT,TEXT,UUID)',
        'public.record_stray_return(UUID,UUID,INTEGER,DATE,TEXT,TEXT,UUID)',
        'public.delete_head_adjustment(UUID)',
        'public.record_feed_pen_opening(UUID,UUID,INTEGER,UUID,DATE,TEXT,UUID,TEXT)'
    ];
BEGIN
    FOREACH fn IN ARRAY fns LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', fn);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
            EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', fn);
        END IF;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', fn);
        END IF;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn);
        END IF;
    END LOOP;
END
$g$;


-- ---------------------------------------------------------------------
-- 8. Verify
-- ---------------------------------------------------------------------
DO $v$
DECLARE
    v_n INTEGER;
    v_bad TEXT;
BEGIN
    -- One function per name. Two would make PostgREST ambiguous.
    FOR v_bad IN SELECT unnest(ARRAY['record_missing_head','record_stray_return',
                                     'delete_head_adjustment','record_feed_pen_opening'])
    LOOP
        SELECT count(*) INTO v_n FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = v_bad;
        IF v_n <> 1 THEN
            RAISE EXCEPTION 'Expected exactly 1 % , found %. PostgREST resolves an RPC by argument names and cannot choose between overloads.', v_bad, v_n;
        END IF;
    END LOOP;

    -- All four INVOKER. Every head-math RPC in this app is, deliberately:
    -- SECURITY DEFINER here would let crew write head math through the API.
    SELECT string_agg(p.proname, ', ') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('record_missing_head','record_stray_return',
                         'delete_head_adjustment','record_feed_pen_opening')
       AND p.prosecdef;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'These must be SECURITY INVOKER and are not: %', v_bad;
    END IF;

    -- Pinned search_path on each, per rule 6 of the access-control section.
    SELECT string_agg(p.proname, ', ') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('record_missing_head','record_stray_return',
                         'delete_head_adjustment','record_feed_pen_opening')
       AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) c
                        WHERE c LIKE 'search_path=%');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'These carry no pinned search_path: %', v_bad;
    END IF;

    -- Nothing granted to anon.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        SELECT string_agg(p.proname, ', ') INTO v_bad
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname IN ('record_missing_head','record_stray_return',
                             'delete_head_adjustment','record_feed_pen_opening')
           AND has_function_privilege('anon', p.oid, 'EXECUTE');
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'anon can execute: %. Rule 4 — never GRANT anything to anon.', v_bad;
        END IF;
    END IF;

    -- The ledger kind and the cascade.
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.feed_pen_ledger'::regclass
           AND conname = 'feed_pen_ledger_entry_kind_check'
           AND pg_get_constraintdef(oid) LIKE '%stray%') THEN
        RAISE EXCEPTION 'feed_pen_ledger.entry_kind does not accept ''stray''.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'feed_pen_ledger'
           AND column_name = 'opening_event_id') THEN
        RAISE EXCEPTION 'feed_pen_ledger.opening_event_id was not added.';
    END IF;

    -- The ledger must still tie to head math after the backfill. This is
    -- the same question feed_pen_reconciliation answers; assert it now so a
    -- mis-linked backfill cannot ship quietly.
    SELECT count(*) INTO v_n FROM public.feed_pen_reconciliation WHERE COALESCE(variance, 0) <> 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'feed_pen_reconciliation reports % pen(s) out of step with head math. Investigate before applying.', v_n;
    END IF;

    RAISE NOTICE 'Strays and missing head: 3 new RPCs, feed pen opening widened, ledger linked. All verified.';
END
$v$;

commit;

-- =====================================================================
-- OPTIONAL, NOT PART OF THIS MIGRATION — reclassifying 47-26
-- =====================================================================
-- The 2 head written off on 2026-09-03 to close lot 47-26 are filed as a
-- death (cause 'missing from shipping'). Under the rule above they are a
-- missing adjustment. Reclassifying moves that lot's death rate from
-- 8/187 (4.28%) to 6/187 (3.21%) and takes 2 head out of the Doctoring &
-- Deaths mortality denominators.
--
-- IT IS DELIBERATELY NOT RUN HERE. 47-26 is closed and sits in FY 2026,
-- which has been reported; and the reversal below cannot use
-- delete_head_adjustment (it refuses a closed lot, correctly). Run it ONLY
-- on John's explicit say-so, and note that it rewrites a prior year.
--
--   UPDATE public.lot_events
--      SET event_type = 'adjustment',
--          cause      = 'missing',
--          notes      = COALESCE(notes, '') ||
--                       ' / 2026-09-__: reclassified from death to a missing '
--                       'adjustment. Nothing died — these head were unaccounted '
--                       'for at shipping. Removes them from the mortality rate '
--                       'and the pull-failure denominators; head_current is '
--                       'unchanged because lot_status sums adjustments signed.'
--    WHERE id = '5ca30f84-4833-4cc2-a2ca-47e7286b9a81';
--
-- head_count is already -2 and stays that way: lot_status subtracts a
-- death's absolute value and ADDS an adjustment's signed value, so the
-- arithmetic lands in the same place and head_current stays 0.
-- =====================================================================
