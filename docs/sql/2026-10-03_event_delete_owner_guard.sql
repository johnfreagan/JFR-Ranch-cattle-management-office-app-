-- STATUS: Applied 2026-10-03 on John's approval ("Option 1", then "A"; move
-- guard added on his "1. Yes"). apply_migration timed out twice without
-- reaching the database, so John ran this file himself in the Supabase SQL
-- Editor. Verified afterwards (05:27 CT): md5(prosrc) matches this file for
-- all three (delete_death_event a42f2d0edbefabddaf780d78c99b4965,
-- delete_head_adjustment 739d4b0a7681f71f3f4508da42c989eb, delete_move_event
-- 38d077d4a6c18a18aa92c4300c252a79); all still SECURITY INVOKER with
-- search_path public, pg_catalog; EXECUTE only authenticated, postgres,
-- service_role; rls_verify passes; lot_head_tieout 8 of 8 open lots tie.

-- Owner-only DELETE guard for the three reversal functions: delete_death_event,
-- delete_head_adjustment (lot_events) and delete_move_event (lot_movements).
--
-- Problem (office tap audit, 2026-10-03, confirmed against the live catalog):
--   lot_events DELETE is owner-only under RLS (lot_events_delete:
--   current_user_role() = 'owner'). delete_death_event and
--   delete_head_adjustment are SECURITY INVOKER (docs/database.md rule 6 says
--   they must stay that way). Each one first puts head back on the pasture,
--   then runs DELETE FROM lot_events and RETURNs true without checking that a
--   row went. When office calls them, RLS turns the DELETE into a silent
--   no-op: the head is credited back but the death or adjustment stays on the
--   books, so head is counted twice and the app says "Death record deleted." /
--   "Head adjustment reversed."
--   Checked 2026-10-03: every open lot ties on lot_head_tieout, so it has not
--   happened yet.
--
-- Fix: after every DELETE FROM lot_events, read ROW_COUNT. If it is 0, raise.
-- The exception rolls back the head already credited, so nothing changes and
-- the app shows the message. Nothing else in either function changes; both
-- bodies are the live prosrc as of 2026-10-03 (md5 f0ea6d197604dbd31f8923ab116ba3d0
-- and 2e2fa7d11befafaba2886f097f2784e8) plus the guard. Still INVOKER, same
-- signature, same search_path; CREATE OR REPLACE keeps the existing grants.
--
-- Run supabase/migrations/20260821000300_rls_verify.sql afterwards.

begin;

CREATE OR REPLACE FUNCTION public.delete_death_event(p_event_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_lot_id UUID;
    v_pasture_id UUID;
    v_head INTEGER;
    v_event_date DATE;
    v_event_type TEXT;
    v_assignment_id UUID;
    v_assignment_head INTEGER;
    v_assignment_moved_out DATE;
    v_recorded_by UUID;
    v_deleted    INTEGER;  -- 2026-10-03: rows the DELETE removed (0 = RLS refused it)
BEGIN
    SELECT lot_id, pasture_id, ABS(head_count), event_date, event_type, created_by
      INTO v_lot_id, v_pasture_id, v_head, v_event_date, v_event_type, v_recorded_by
    FROM public.lot_events
    WHERE id = p_event_id;

    IF v_event_type IS NULL THEN
        RAISE EXCEPTION 'Death event % not found.', p_event_id;
    END IF;
    IF v_event_type != 'death' THEN
        RAISE EXCEPTION 'Event % is not a death event (type=%).', p_event_id, v_event_type;
    END IF;

    -- No pasture attribution: nothing was decremented, so nothing to add back.
    IF v_pasture_id IS NULL THEN
        DELETE FROM public.lot_events WHERE id = p_event_id;
        GET DIAGNOSTICS v_deleted = ROW_COUNT;
        IF v_deleted = 0 THEN
            RAISE EXCEPTION 'Not deleted: only the owner can delete this event. Nothing was changed.'
                USING ERRCODE = '42501';
        END IF;
        RETURN true;
    END IF;

    SELECT id, head_count INTO v_assignment_id, v_assignment_head
    FROM public.lot_pasture_assignments
    WHERE lot_id = v_lot_id AND pasture_id = v_pasture_id AND moved_out IS NULL;

    IF v_assignment_id IS NOT NULL THEN
        -- Still open: the death decremented it, so add back.
        UPDATE public.lot_pasture_assignments
           SET head_count = v_assignment_head + v_head
         WHERE id = v_assignment_id;
    ELSE
        SELECT id, head_count, moved_out
          INTO v_assignment_id, v_assignment_head, v_assignment_moved_out
        FROM public.lot_pasture_assignments
        WHERE lot_id = v_lot_id AND pasture_id = v_pasture_id AND moved_out >= v_event_date
        ORDER BY moved_out ASC
        LIMIT 1;

        IF v_assignment_id IS NOT NULL THEN
            -- THE FIX: reopen with exactly the head coming back. The stored
            -- head_count was left behind when the row was closed and must
            -- not be added to.
            UPDATE public.lot_pasture_assignments
               SET moved_out = NULL,
                   head_count = v_head
             WHERE id = v_assignment_id;
        ELSE
            INSERT INTO public.lot_pasture_assignments (
                lot_id, pasture_id, head_count, moved_in, notes, recorded_by
            ) VALUES (
                v_lot_id, v_pasture_id, v_head, v_event_date,
                'Auto-created on death-event reversal', v_recorded_by
            );
        END IF;
    END IF;

    DELETE FROM public.lot_events WHERE id = p_event_id;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    IF v_deleted = 0 THEN
        RAISE EXCEPTION 'Not deleted: only the owner can delete this event. Nothing was changed.'
            USING ERRCODE = '42501';
    END IF;
    RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_head_adjustment(p_event_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
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
    v_deleted    INTEGER;  -- 2026-10-03: rows the DELETE removed (0 = RLS refused it)
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
        GET DIAGNOSTICS v_deleted = ROW_COUNT;
        IF v_deleted = 0 THEN
            RAISE EXCEPTION 'Not deleted: only the owner can delete this event. Nothing was changed.'
                USING ERRCODE = '42501';
        END IF;
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
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    IF v_deleted = 0 THEN
        RAISE EXCEPTION 'Not deleted: only the owner can delete this event. Nothing was changed.'
            USING ERRCODE = '42501';
    END IF;
    RETURN true;
END;
$function$;

-- delete_move_event: same bug, added 2026-10-03 on John's approval. Its two
-- DELETEs (lot_pasture_assignments, lot_movements) are both owner-only under
-- RLS (lpa_delete, lot_movements_delete). Live prosrc md5 before this file:
-- 3fd05350b8fc6bf4f8267b0a319e3120.
CREATE OR REPLACE FUNCTION public.delete_move_event(p_movement_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_lot_id     UUID;
    v_from_id    UUID;
    v_to_id      UUID;
    v_head       INTEGER;
    v_move_date  DATE;
    v_recorded   UUID;
    v_assign     UUID;
    v_assign_head INTEGER;
    v_moved_in   DATE;
    v_deleted    INTEGER;  -- 2026-10-03: rows the DELETE removed (0 = RLS refused it)
BEGIN
    SELECT lot_id, from_pasture_id, to_pasture_id, head_count, move_date, recorded_by
      INTO v_lot_id, v_from_id, v_to_id, v_head, v_move_date, v_recorded
    FROM public.lot_movements WHERE id = p_movement_id;

    IF v_lot_id IS NULL THEN
        RAISE EXCEPTION 'Movement % not found.', p_movement_id;
    END IF;

    -- --- undo the destination ---
    SELECT id, head_count, moved_in INTO v_assign, v_assign_head, v_moved_in
    FROM public.lot_pasture_assignments
    WHERE lot_id = v_lot_id AND pasture_id = v_to_id AND moved_out IS NULL;

    IF v_assign IS NULL THEN
        RAISE EXCEPTION 'Cannot reverse move %: no open assignment at the destination.', p_movement_id;
    END IF;
    IF v_assign_head < v_head THEN
        RAISE EXCEPTION 'Cannot reverse move %: destination holds % head, fewer than the % moved.',
            p_movement_id, v_assign_head, v_head;
    END IF;

    IF v_assign_head = v_head AND v_moved_in = v_move_date THEN
        -- This move created the row; remove it rather than leave a zero.
        DELETE FROM public.lot_pasture_assignments WHERE id = v_assign;
        GET DIAGNOSTICS v_deleted = ROW_COUNT;
        IF v_deleted = 0 THEN
            RAISE EXCEPTION 'Not deleted: only the owner can delete a move. Nothing was changed.'
                USING ERRCODE = '42501';
        END IF;
    ELSE
        UPDATE public.lot_pasture_assignments
           SET head_count = v_assign_head - v_head
         WHERE id = v_assign;
    END IF;

    -- --- put the head back at the source ---
    IF v_from_id IS NOT NULL THEN
        SELECT id, head_count INTO v_assign, v_assign_head
        FROM public.lot_pasture_assignments
        WHERE lot_id = v_lot_id AND pasture_id = v_from_id AND moved_out IS NULL;

        IF v_assign IS NOT NULL THEN
            UPDATE public.lot_pasture_assignments
               SET head_count = v_assign_head + v_head
             WHERE id = v_assign;
        ELSE
            -- The move emptied and closed the source. Reopen it, same as
            -- delete_death_event does.
            SELECT id, head_count INTO v_assign, v_assign_head
            FROM public.lot_pasture_assignments
            WHERE lot_id = v_lot_id AND pasture_id = v_from_id AND moved_out >= v_move_date
            ORDER BY moved_out ASC LIMIT 1;

            IF v_assign IS NOT NULL THEN
                -- Reopen with exactly the head coming back, NOT the stored
                -- value plus it. When an assignment is emptied it is closed
                -- with its last head_count left in place as a historical
                -- record, so that number is stale the moment moved_out is
                -- set. Adding to it double-counts the herd.
                UPDATE public.lot_pasture_assignments
                   SET moved_out = NULL, head_count = v_head
                 WHERE id = v_assign;
            ELSE
                INSERT INTO public.lot_pasture_assignments (
                    lot_id, pasture_id, head_count, moved_in, notes, recorded_by
                ) VALUES (
                    v_lot_id, v_from_id, v_head, v_move_date,
                    'Auto-created on move reversal', v_recorded
                );
            END IF;
        END IF;
    END IF;

    DELETE FROM public.lot_movements WHERE id = p_movement_id;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    IF v_deleted = 0 THEN
        RAISE EXCEPTION 'Not deleted: only the owner can delete a move. Nothing was changed.'
            USING ERRCODE = '42501';
    END IF;
    RETURN true;
END;
$function$;

commit;
