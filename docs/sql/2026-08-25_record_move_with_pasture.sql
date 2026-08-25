-- =====================================================================
-- record_move_with_pasture / delete_move_event
-- =====================================================================
-- Moving head between pastures touches three things: a lot_movements
-- audit row, the source assignment and the destination assignment. Doing
-- that from the client means three round trips with no transaction, and a
-- failure between them leaves head counted in two places at once, or in
-- neither - drift, which the Anomalies report catches only after the fact.
--
-- These mirror record_death_with_pasture / delete_death_event, which
-- already solve the same problem for deaths. Same conventions: plain
-- INVOKER (no SECURITY DEFINER - the caller's RLS still applies), pinned
-- search_path, raise rather than half-apply.
--
-- delete_move_event exists so the approvals screen can roll a batch back.
-- Approval is all-or-nothing, and a move that cannot be undone would make
-- that a lie.
--
-- Idempotent: CREATE OR REPLACE, no data touched.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Record a move
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_move_with_pasture(
    p_lot_id          UUID,
    p_from_pasture_id UUID,
    p_to_pasture_id   UUID,
    p_head_count      INTEGER,
    p_move_date       DATE DEFAULT CURRENT_DATE,
    p_notes           TEXT DEFAULT NULL,
    p_recorded_by     UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_move_id     UUID;
    v_from_assign UUID;
    v_from_head   INTEGER;
    v_to_assign   UUID;
BEGIN
    IF p_head_count IS NULL OR p_head_count <= 0 THEN
        RAISE EXCEPTION 'Head count must be positive (got %).', p_head_count;
    END IF;
    IF p_to_pasture_id IS NULL THEN
        RAISE EXCEPTION 'A destination pasture is required.';
    END IF;
    IF p_from_pasture_id IS NOT NULL AND p_from_pasture_id = p_to_pasture_id THEN
        RAISE EXCEPTION 'From and to pasture are the same.';
    END IF;

    -- A NULL source means head arriving from outside the pasture system
    -- (the office uses this for receipts). Nothing to decrement then.
    IF p_from_pasture_id IS NOT NULL THEN
        SELECT id, head_count INTO v_from_assign, v_from_head
        FROM public.lot_pasture_assignments
        WHERE lot_id = p_lot_id
          AND pasture_id = p_from_pasture_id
          AND moved_out IS NULL;

        IF v_from_assign IS NULL THEN
            RAISE EXCEPTION 'No active pasture assignment for lot % at the from-pasture.', p_lot_id;
        END IF;
        IF p_head_count > v_from_head THEN
            RAISE EXCEPTION 'Cannot move % head out of a pasture holding %.', p_head_count, v_from_head;
        END IF;
    END IF;

    INSERT INTO public.lot_movements (
        lot_id, move_date, from_pasture_id, to_pasture_id, head_count, notes, recorded_by
    ) VALUES (
        p_lot_id, p_move_date, p_from_pasture_id, p_to_pasture_id, p_head_count, p_notes, p_recorded_by
    )
    RETURNING id INTO v_move_id;

    -- Source: close it when the last head leaves, matching the death path.
    IF v_from_assign IS NOT NULL THEN
        IF v_from_head - p_head_count = 0 THEN
            UPDATE public.lot_pasture_assignments
               SET moved_out = p_move_date
             WHERE id = v_from_assign;
        ELSE
            UPDATE public.lot_pasture_assignments
               SET head_count = v_from_head - p_head_count
             WHERE id = v_from_assign;
        END IF;
    END IF;

    -- Destination: add to the open assignment, or open one.
    SELECT id INTO v_to_assign
    FROM public.lot_pasture_assignments
    WHERE lot_id = p_lot_id
      AND pasture_id = p_to_pasture_id
      AND moved_out IS NULL;

    IF v_to_assign IS NULL THEN
        INSERT INTO public.lot_pasture_assignments (
            lot_id, pasture_id, head_count, moved_in, recorded_by
        ) VALUES (
            p_lot_id, p_to_pasture_id, p_head_count, p_move_date, p_recorded_by
        );
    ELSE
        UPDATE public.lot_pasture_assignments
           SET head_count = head_count + p_head_count
         WHERE id = v_to_assign;
    END IF;

    RETURN v_move_id;
END;
$function$;

-- ---------------------------------------------------------------------
-- Reverse a move
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_move_event(p_movement_id UUID)
RETURNS BOOLEAN
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
    RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------
-- FIX: delete_death_event double-counts when reopening a closed pasture
--
-- Found while testing the move reversal above, which was written by
-- mirroring this function and inherited the same fault.
--
-- record_death_with_pasture closes an emptied assignment by setting
-- moved_out and LEAVING head_count where it was, as a historical record
-- of what the pasture last held. That number is stale from then on.
-- delete_death_event reopens such a row with `head_count + v_head`,
-- which adds the returning head to a count that was never cleared:
--
--     pasture holds 3 -> death of all 3 -> row closed, head_count 3
--     reverse that death -> head_count 3 + 3 = 6
--
-- The herd doubles in that pasture and the lot drifts. Verified against
-- the production definitions on a local replica before writing this.
--
-- Only reachable when reversing a death that emptied a pasture, which is
-- why it has not surfaced. It is reachable from the office delete-death
-- path and from the field approvals rollback.
--
-- Everything else in the function is unchanged.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_death_event(p_event_id UUID)
RETURNS BOOLEAN
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
    RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------
-- Grants: same shape as every other table and function here -
-- authenticated only, never anon, never PUBLIC.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.record_move_with_pasture(UUID,UUID,UUID,INTEGER,DATE,TEXT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_move_event(UUID) FROM PUBLIC;
DO $g$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        EXECUTE 'REVOKE ALL ON FUNCTION public.record_move_with_pasture(UUID,UUID,UUID,INTEGER,DATE,TEXT,UUID) FROM anon';
        EXECUTE 'REVOKE ALL ON FUNCTION public.delete_move_event(UUID) FROM anon';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION public.record_move_with_pasture(UUID,UUID,UUID,INTEGER,DATE,TEXT,UUID) TO authenticated';
        EXECUTE 'GRANT EXECUTE ON FUNCTION public.delete_move_event(UUID) TO authenticated';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION public.record_move_with_pasture(UUID,UUID,UUID,INTEGER,DATE,TEXT,UUID) TO service_role';
        EXECUTE 'GRANT EXECUTE ON FUNCTION public.delete_move_event(UUID) TO service_role';
    END IF;
END
$g$;

COMMENT ON FUNCTION public.record_move_with_pasture(UUID,UUID,UUID,INTEGER,DATE,TEXT,UUID) IS
    'Atomically records a pasture move: writes lot_movements and rebalances both assignments. Never call the three writes separately - that is how drift happens.';
COMMENT ON FUNCTION public.delete_move_event(UUID) IS
    'Reverses record_move_with_pasture, restoring both assignments. Used by the field approvals screen to roll back a failed batch.';
