-- =====================================================================
-- 37X-1: labor rate was $35.00 per head per DAY
-- =====================================================================
-- 2026-08-25. John's call: it should be $0.35/head/day.
--
-- The closeout screen stores labor as a rate plus a mode. 37X-1 carried
-- labor_mode = 'per_day' with assumed_labor_per_day = 35.0000, so every
-- projection multiplied it by days on feed: 223 days x $35 = $7,805/head
-- of labor against cattle that cost about $900. A hundredfold typo that
-- the screen accepted without complaint.
--
-- Only the rate changes. The mode stays 'per_day' - $0.35/head/day is what
-- was meant, and it lines up with the other lots (0.35 to 0.50).
--
-- Guarded: if the stored value is not 35, something else has already
-- changed it and this must not run blind.
--
-- Idempotent: re-running after a successful apply is a no-op.
-- =====================================================================

DO $fix$
DECLARE
    v_lot_id  uuid;
    v_current numeric;
    v_mode    text;
BEGIN
    SELECT id, assumed_labor_per_day, labor_mode
      INTO v_lot_id, v_current, v_mode
      FROM public.lots
     WHERE lot_number = '37X-1';

    IF v_lot_id IS NULL THEN
        RAISE EXCEPTION 'Lot 37X-1 not found - wrong database?';
    END IF;

    IF v_current IS NOT DISTINCT FROM 0.35 THEN
        RAISE NOTICE '37X-1 labor is already 0.35/head/day. Nothing to do.';
        RETURN;
    END IF;

    IF v_current IS DISTINCT FROM 35.0000 THEN
        RAISE EXCEPTION
            '37X-1 labor is %, expected 35.0000. Someone else changed it - look before running this.',
            COALESCE(v_current::text, 'NULL');
    END IF;

    IF v_mode IS DISTINCT FROM 'per_day' THEN
        RAISE EXCEPTION
            '37X-1 labor_mode is %, expected per_day. The fix assumes a per-day rate.',
            COALESCE(v_mode, 'NULL');
    END IF;

    UPDATE public.lots
       SET assumed_labor_per_day = 0.35,
           notes = COALESCE(notes || E'\n\n', '')
                   || '2026-08-25: Labor assumption corrected from $35.00/head/day to '
                   || '$0.35/head/day. The stored rate was a hundredfold data-entry error '
                   || 'and was inflating every closeout projection for this lot by roughly '
                   || '$7,700/head. Rate only; labor_mode stays per_day. John''s call.'
     WHERE id = v_lot_id;

    RAISE NOTICE '37X-1 labor corrected to $0.35/head/day, audit note appended.';
END
$fix$;

-- =====================================================================
--   SELECT lot_number, labor_mode, assumed_labor_per_day
--   FROM lots WHERE lot_number = '37X-1';
-- =====================================================================
