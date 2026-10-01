-- =====================================================================
-- The crew's actual counts, replacing the estimate
-- =====================================================================
-- 2026-10-01. Supersedes the Excede half of 2026-10-01h. The Enroflox,
-- Resflor and Macrosyn quantities in that file stand; this one only
-- records that two of them were confirmed.
--
-- 2026-10-01h flagged three readings of the crew's words that carried
-- more than one meaning. John answered all three.
--
--   Enroflox  "1.2 of 500" IS 1/2 of a 500 mL bottle. Confirmed.
--             Crew holds 2.5 bottles, 1,250 mL, $458.91. No change.
--
--   Resflor   "2 bottles 1/2 full" IS two bottles each half full, not
--             one full and one half. Confirmed. With the fourth man's
--             3/4 of a 500 mL on top, the crew holds 1.75 bottles,
--             875 mL, $726.92. No change.
--
--   Excede    CHANGED, and by a lot. The estimate was 1.25 bottles read
--             as 100 mL plus the fourth man's 1/4 of a 250 - 187.5 mL.
--             John's actual is FOUR containers:
--                 1 full 100 mL                      =   100 mL
--                 1 full 250 mL                      =   250 mL
--                 1/4 of a 250 mL                    =    62.5 mL
--                 1/4 of a 250 mL                    =    62.5 mL
--                                                      --------
--                                                        475 mL
--             at $2.133113/mL = $1,013.23, against $399.96 estimated.
--             Up $613.27.
--
-- The 100 mL assumption was the weakest of the three readings and it was
-- the one that was wrong. Worth remembering when the next count is
-- gathered: ask for the container size with the fraction, every time.
-- The count line records 475 mL as 1.9 of a 250 mL bottle, because
-- crew_open is a fraction of a bottle and the four gathering boxes have
-- to multiply out to counted_units.
--
-- WHAT IT DOES TO THE NUMBERS
--     crew-held stock      $1,781.26  ->  $2,394.53
--     the count           $19,443.34  ->  $20,056.61
--     Jayci's net            -$2.40   ->    +$610.87
--
-- Her two entries no longer nearly cancel. The crew is holding more
-- product than the expired write-off takes out, so the account goes UP.
--
-- WHERE IT LEAVES THE RECONCILIATION
--     Redwing report at 9/30/2026                      $21,896.25
--       less Excede, re-allocated 10/1 (already done)   $2,077.36
--       less Macrosyn, July close (with accountants)      $373.15
--       plus crew-held stock back in                    $2,394.53
--       less expired product, net (for Jayci)           $1,783.66
--     Redwing after all of it                          $20,056.61
--     The count                                        $20,056.61
--
-- STILL TO COME: Jake Taylor's processing medicine, and the split of
-- this one count into three locations - Medicine Room, Cowboys, Jake
-- Taylor. See docs/OPEN-ITEMS.md item 0d. Neither changes the totals
-- above; they change which shelf each line sits on.
--
-- Nothing has been posted. The count has been a draft throughout.
-- =====================================================================

begin;

DO $actual$
DECLARE
    v_count uuid;
    v       numeric;
BEGIN
    SELECT c.id INTO v_count
      FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind = 'ranch' AND NOT l.is_test;

    IF v_count IS NULL THEN
        RAISE EXCEPTION 'the opening count draft is missing';
    END IF;
    IF (SELECT status FROM public.med_counts WHERE id = v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the opening count is no longer a draft - refusing to edit a posted count';
    END IF;

    -- Excede: shelf 2,650 mL, trucks 475 mL. 3,125 mL.
    UPDATE public.med_count_lines cl
       SET barn_full = 10.6, crew_full = 1, crew_open = 0.9, crew_carried = false,
           counted_units = 3125,
           notes = 'FINAL 2026-10-01. The shelf holds 1 x 250 mL AND 24 x 100 mL = 2,650 mL (John, confirmed). Redwing''s 250 ML line carried $2,596.71 against that one bottle, which was product charged out and mis-posted; corrected it reads 1 bottle at $519.35, so Redwing''s Excede is $5,133.40 + $519.35 = $5,652.75 and $2,077.36 came out of inventory. 2,650 mL at $5,652.75 is $2.133113/mL. | CREW, ACTUAL as given by John 2026-10-01, superseding the earlier estimate: 1 full 100 mL + 1 full 250 mL + 1/4 of a 250 + 1/4 of a 250 = 475 mL, $1,013.23. Carried as 1.9 of a 250 mL bottle so the gathering boxes multiply out to counted_units.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Excede';

    -- Enroflox: quantity unchanged, reading confirmed.
    UPDATE public.med_count_lines cl
       SET notes = 'Redwing "Enroflox 500 ML" 21.00 bottles, $3,854.87. 21 x 500 mL. | CREW ADDED 2026-10-01: three part bottles - 3/4 + 1/2 + 3/4 = 2.0 bottles, plus a fourth man reporting 1/2 of a 500 mL = 2.5 bottles = 1,250 mL in the trucks. CONFIRMED by John 2026-10-01: the fourth man''s "1.2 of 500" is 1/2 of a 500 mL. Charged out in September and not yet used.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Enroflox(Baytril)';

    -- Resflor: quantity unchanged, reading confirmed. The one residual
    -- doubt is recorded on the line rather than left in somebody's head.
    UPDATE public.med_count_lines cl
       SET notes = 'Redwing "Resflor 500 ML" 10.00 bottles, $4,153.81. 10 x 500 mL. Redwing also lists "Resflor 250 ML" at zero. | CREW ADDED 2026-10-01: 2 bottles each 1/2 full = 1.0 bottle, plus a fourth man reporting 3/4 of a 500 mL = 1.75 bottles = 875 mL in the trucks. CONFIRMED by John 2026-10-01: "resflor is 2 bottles 1/2 full" - two bottles each half full, not one full and one half. The fourth man''s 3/4 is on top of that; if John meant 875 mL was the whole of it, this line is 500 mL and $415.38 instead.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Resflor';

    SELECT round(cl.counted_units * cl.unit_cost, 2) INTO v
      FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count AND m.name = 'Excede';
    IF v <> 6665.98 THEN
        RAISE EXCEPTION 'Excede values at %, expected 6665.98', v;
    END IF;
END
$actual$;

DO $verify$
DECLARE
    v_count uuid;
    n       integer;
    v       numeric;
    bad     text;
BEGIN
    SELECT c.id INTO v_count
      FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind = 'ranch' AND NOT l.is_test;

    SELECT count(*) INTO n FROM public.med_count_lines WHERE count_id = v_count;
    IF n <> 21 THEN RAISE EXCEPTION 'expected 21 count lines, found %', n; END IF;

    SELECT count(*) INTO n FROM public.med_count_lines
     WHERE count_id = v_count AND counted_units > 0;
    IF n <> 11 THEN RAISE EXCEPTION 'expected 11 stocked lines, found %', n; END IF;

    -- EVERY stocked line's four gathering boxes must multiply out to
    -- counted_units. This assertion has now caught two real errors.
    SELECT string_agg(m.name || ': boxes give ' ||
               (cl.bottle_size * (coalesce(cl.barn_full,0) + coalesce(cl.barn_open,0)
                                + coalesce(cl.crew_full,0) + coalesce(cl.crew_open,0)))
               || ' against counted ' || cl.counted_units, '; ')
      INTO bad
      FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count AND cl.counted_units > 0
       AND cl.bottle_size * (coalesce(cl.barn_full,0) + coalesce(cl.barn_open,0)
                           + coalesce(cl.crew_full,0) + coalesce(cl.crew_open,0))
           <> cl.counted_units;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'count boxes do not reconcile - %', bad;
    END IF;

    SELECT round(SUM(counted_units * unit_cost), 2) INTO v
      FROM public.med_count_lines
     WHERE count_id = v_count AND unit_cost IS NOT NULL;
    IF v <> 20056.61 THEN RAISE EXCEPTION 'count comes to %, expected 20056.61', v; END IF;

    SELECT round(SUM(cl.bottle_size * (coalesce(cl.crew_full,0) + coalesce(cl.crew_open,0))
                     * cl.unit_cost), 2) INTO v
      FROM public.med_count_lines cl
     WHERE cl.count_id = v_count AND cl.unit_cost IS NOT NULL;
    IF v <> 2394.53 THEN RAISE EXCEPTION 'crew-held stock comes to %, expected 2394.53', v; END IF;

    IF round(21896.25 - 2077.36 - 373.15 + 2394.53 - 1783.66, 2) <> 20056.61 THEN
        RAISE EXCEPTION 'the Redwing bridge no longer lands on the count';
    END IF;

    SELECT count(*) INTO n FROM public.med_purchase_lines;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', n; END IF;
    SELECT count(*) INTO n FROM public.med_txns;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', n; END IF;
    IF (SELECT status FROM public.med_counts WHERE id = v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the count is not a draft';
    END IF;

    RAISE NOTICE 'VERIFIED: 21 lines, 11 stocked, every line''s boxes reconcile, $20,056.61 counted of which $2,394.53 is crew-held, still a draft.';
END
$verify$;

commit;
