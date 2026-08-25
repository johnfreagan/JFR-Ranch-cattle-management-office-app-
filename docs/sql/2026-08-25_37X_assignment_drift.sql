-- =====================================================================
-- 37X: reduce one pasture assignment by 3 head to clear drift
-- =====================================================================
-- Lot 37X carries head_current 304 against 307 in open pasture
-- assignments: the pasture side is 3 head high.
--
-- Cause (established 2026-08-25): 16 of 37X's 20 death events predate the
-- lot's first pasture assignment. The assignments begin 2026-04-27; those
-- deaths run 2025-12-18 to 2026-04-16. They were raw inserts from the
-- April historical import rather than calls to record_death_with_pasture,
-- so they reduced the lot ledger without ever reducing a pasture. The
-- opening counts taken on 2026-04-27 absorbed most but not all of them.
--
-- 37X is the only lot in the book with this pattern. Other lots carry
-- pasture-less deaths (31-26: 60 head, 37X-1: 9, 47-26: 4) and all balance
-- at zero, so pasture-less deaths alone are not the trigger - deaths
-- occurring BEFORE the assignment structure existed are, and only 37X has
-- any.
--
-- Everything after April 2026 is correct and is NOT touched here: the
-- 4-head death on South 40 (2026-07-23) decremented and closed that
-- assignment, the 37-head sale out of Bottom (2026-08-11) decremented it
-- 39 -> 2, and all six moves are internal and net to zero.
--
-- This is a pasture-side correction only. head_in, head_dead, head_sold
-- and head_current are untouched, so death loss stays 20/361 = 5.5%.
-- If these 3 head are in fact dead or gone rather than merely counted in
-- the wrong pasture, this is the WRONG script - that case wants a death
-- event, which would move head_dead to 23 and death loss to 6.4%.
--
-- Idempotent: it verifies the drift is exactly -3 before changing
-- anything and refuses to run a second time, since the drift will then
-- be 0.
-- =====================================================================

BEGIN;

DO $fix$
DECLARE
    -- The pasture the 3 head are being taken OUT of. Change these two
    -- values if the shortfall is somewhere other than Front Native.
    c_ranch    CONSTANT TEXT := 'Steele';
    c_pasture  CONSTANT TEXT := 'Front Native';
    c_head     CONSTANT INT  := 3;

    v_lot      UUID;
    v_assign   UUID;
    v_head     INT;
    v_drift    INT;
    v_note     TEXT;
BEGIN
    SELECT id INTO v_lot FROM public.lots WHERE lot_number = '37X';
    IF v_lot IS NULL THEN
        RAISE EXCEPTION 'Lot 37X not found.';
    END IF;

    -- Refuse to act unless the books are in exactly the state that was
    -- diagnosed. If something has changed since, a human should look again.
    SELECT ls.head_current
           - COALESCE((SELECT SUM(a.head_count) FROM public.lot_pasture_assignments a
                        WHERE a.lot_id = v_lot AND a.moved_out IS NULL), 0)
      INTO v_drift
      FROM public.lot_status ls WHERE ls.lot_id = v_lot;

    -- A missing lot_status row would leave v_drift NULL, and every
    -- comparison below would then be NULL rather than true - so both
    -- guards would fall through silently and the update would run
    -- unverified. Fail loudly instead.
    IF v_drift IS NULL THEN
        RAISE EXCEPTION 'Could not read head_current for 37X from lot_status. Aborting rather than guessing.';
    END IF;

    IF v_drift = 0 THEN
        RAISE EXCEPTION '37X drift is already 0 - this correction has been applied. Nothing to do.';
    END IF;
    IF v_drift <> -c_head THEN
        RAISE EXCEPTION 'Expected 37X drift of -%, found %. State has changed since diagnosis; aborting.',
            c_head, v_drift;
    END IF;

    RAISE NOTICE 'Pre-check OK: 37X head_current=%, drift=%. Proceeding.',
        (SELECT ls.head_current FROM public.lot_status ls WHERE ls.lot_id = v_lot), v_drift;

    SELECT a.id, a.head_count INTO v_assign, v_head
      FROM public.lot_pasture_assignments a
      JOIN public.pastures p ON p.id = a.pasture_id
      JOIN public.ranches  r ON r.id = p.ranch_id
     WHERE a.lot_id = v_lot
       AND a.moved_out IS NULL
       AND p.name = c_pasture
       AND r.name = c_ranch;

    IF v_assign IS NULL THEN
        RAISE EXCEPTION 'No open 37X assignment at % - %.', c_ranch, c_pasture;
    END IF;
    IF v_head <= c_head THEN
        RAISE EXCEPTION 'Assignment at % - % holds only % head; refusing to reduce by %.',
            c_ranch, c_pasture, v_head, c_head;
    END IF;

    v_note := format(
        '2026-08-25: reduced %s head (%s -> %s) to clear lot-level drift. '
        || 'Cause: %s head of deaths dated 2025-12-18..2026-04-16 predate this lot''s first '
        || 'pasture assignment (2026-04-27) and were raw historical inserts, so they reduced '
        || 'the lot ledger without reducing any pasture. Pasture side only; head_in/dead/sold '
        || 'unchanged. Approved by owner.',
        c_head, v_head, v_head - c_head, 16);

    UPDATE public.lot_pasture_assignments
       SET head_count = head_count - c_head,
           notes = CASE WHEN notes IS NULL OR notes = '' THEN v_note
                        ELSE notes || E'\n' || v_note END
     WHERE id = v_assign;

    -- Prove it landed before committing.
    SELECT ls.head_current
           - COALESCE((SELECT SUM(a.head_count) FROM public.lot_pasture_assignments a
                        WHERE a.lot_id = v_lot AND a.moved_out IS NULL), 0)
      INTO v_drift
      FROM public.lot_status ls WHERE ls.lot_id = v_lot;

    IF v_drift <> 0 THEN
        RAISE EXCEPTION '37X drift is still % after the correction; rolling back.', v_drift;
    END IF;

    RAISE NOTICE '37X: % - % reduced % -> %. Drift now 0.',
        c_ranch, c_pasture, v_head, v_head - c_head;
END
$fix$;

COMMIT;

-- =====================================================================
-- Verify afterwards (read-only)
-- =====================================================================
-- SELECT ls.head_current,
--        (SELECT SUM(a.head_count) FROM lot_pasture_assignments a
--          JOIN lots l ON l.id = a.lot_id
--         WHERE l.lot_number = '37X' AND a.moved_out IS NULL) AS assigned
--   FROM lot_status ls JOIN lots l ON l.id = ls.lot_id
--  WHERE l.lot_number = '37X';        -- both must read 304
