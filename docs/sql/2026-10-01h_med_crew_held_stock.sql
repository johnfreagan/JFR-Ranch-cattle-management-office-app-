-- =====================================================================
-- Crew-held stock: what is in the trucks and saddle bags on 9/30/2026
-- =====================================================================
-- 2026-10-01. Fourth and last correction to the opening count.
--
-- THE QUESTION JOHN ASKED
--     "The cowboys have inventory in their trucks and saddle bags as of
--      today. Do we ignore for now and start inventorying at 10/31?
--      This med was charged out last month to cattle but not used yet.
--      Will fix itself over the month but throws first month off?"
--
-- It does fix itself over a month, and it does throw the first month
-- off, and those are not the same size of problem. Ignoring it means
-- the opening count understates stock by whatever is in the trucks and
-- October then shows a windfall when that product gets used against
-- nothing. Counting it means the opening count is right the first time
-- and October's usage lands against October's cattle.
--
-- John chose to count it (option A). This file records it.
--
-- WHAT THE CREW REPORTED
-- Three men first, then a fourth reported in while this was being
-- written, which is why the per-drug arithmetic shows two parts.
--
--   Resflor    2 bottles each 1/2 full  = 1.0 bottle
--              + 3/4 of a 500 mL        = 1.75 bottles =   875 mL
--   Enroflox   3/4 + 1/2 + 3/4          = 2.0 bottles
--              + 1/2 of a 500 mL        = 2.5 bottles  = 1,250 mL
--   Excede     1 unopened + 1 at 1/4    =   125 mL (as 100 mL bottles)
--              + 1/4 of a 250 mL        =    62.5 mL  =   187.5 mL
--   Macrosyn   1/2 bottle               = 0.5 bottle   =   250 mL
--
-- Priced at each drug's count rate:
--     Resflor       875 mL at $0.830762  =   $726.92
--     Enroflox    1,250 mL at $0.367130  =   $458.91
--     Excede      187.5 mL at $2.133113  =   $399.96
--     Macrosyn      250 mL at $0.781880  =   $195.47
--                                          ---------
--                                          $1,781.26
--
-- THREE READINGS STILL TO CONFIRM BEFORE THE COUNT IS POSTED
--   1. Enroflox, the fourth man's "1.2 of 500" is read as 1/2 of a
--      500 mL bottle, to match the fractions used everywhere else in
--      the same message. If he meant 1.2 bottles the crew holds
--      1,600 mL and $587.41 rather than 1,250 mL and $458.91.
--   2. Excede, the first three men's bottles are taken as 100 mL,
--      because that is what the shelf is mostly made of. If they are
--      250 mL the trucks hold 375 mL and $799.92 rather than 187.5 mL
--      and $399.96. The fourth man's quarter bottle IS a 250 mL, which
--      makes the assumption weaker than it was.
--   3. Resflor, "2 bottles of resflor 1/2 full" is read as two half
--      bottles = 1.0 bottle. If it meant one full and one half the crew
--      holds 1,125 mL and $934.61 rather than 875 mL and $726.92.
--   All three are on the line notes and on the PDF for Jayci.
--
-- THE OTHER STOCKED LINES have no crew entry at all. The crew named
-- four drugs; crew_full and crew_open stay NULL on the rest rather than
-- being written to zero, because "they did not name it" is not the same
-- statement as "they looked and there is none."
--
-- ONE THING FOR REDWING THAT RUNS THE OTHER WAY
-- Three of these four were charged out in September and are still in
-- the trucks unused, so Redwing's inventory is understated by them and
-- they go back IN at the October close. Macrosyn is the odd one: of the
-- $373.15 Redwing carries against no quantity from the July close,
-- $195.47 is this real half bottle in a truck and only $177.68 is the
-- posting error. Worth telling the accountants that their July fix is
-- smaller than it looked.
--
-- WHERE IT LEAVES THE RECONCILIATION
--     Redwing report at 9/30/2026                      $21,896.25
--       less Excede, re-allocated 10/1 (already done)   $2,077.36
--       less Macrosyn, July close (with accountants)      $373.15
--       plus crew-held stock back in                    $1,781.26
--       less expired product, net (for Jayci)           $1,783.66
--             One Grass 1,804.00 + Synovex S 165.00
--             + Synovex C 121.00 = 2,090.00
--             less 306.34 moved to Multi Min
--     Redwing after all of it                          $19,443.34
--     The count                                        $19,443.34
--
-- Jayci's two entries very nearly cancel: $1,781.26 of crew stock back
-- in against $1,783.66 of expired product out is a net of $2.40. That
-- is a coincidence and not a reason to skip either entry - they are
-- different accounts and different months.
--
-- Nothing has been posted. The count has been a draft throughout.
-- =====================================================================

begin;

DO $crew$
DECLARE
    v_count uuid;
    n       integer;
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

    -- Resflor: barn 10 bottles, trucks 1.75 bottles. 5,875 mL.
    UPDATE public.med_count_lines cl
       SET barn_full = 10, crew_full = 1, crew_open = 0.75, crew_carried = false,
           counted_units = 5875,
           notes = 'Redwing "Resflor 500 ML" 10.00 bottles, $4,153.81. 10 x 500 mL. Redwing also lists "Resflor 250 ML" at zero. | CREW ADDED 2026-10-01: 2 bottles each 1/2 full = 1.0 bottle, plus a fourth man reporting 3/4 of a 500 mL = 1.75 bottles = 875 mL in the trucks. Charged out in September and not yet used. The "2 bottles each 1/2 full" reading is 1.0 bottle; if it meant 1 full and 1 half the crew holds 1,125 mL and $934.61 instead of $726.92.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Resflor';

    -- Enroflox: barn 21 bottles, trucks 2.5 bottles. 11,750 mL.
    UPDATE public.med_count_lines cl
       SET barn_full = 21, crew_full = 2, crew_open = 0.5, crew_carried = false,
           counted_units = 11750,
           notes = 'Redwing "Enroflox 500 ML" 21.00 bottles, $3,854.87. 21 x 500 mL. | CREW ADDED 2026-10-01: three part bottles - 3/4 + 1/2 + 3/4 = 2.0 bottles, plus a fourth man reporting 1/2 of a 500 mL = 2.5 bottles = 1,250 mL in the trucks. Charged out in September and not yet used. John wrote that last one as "1.2 of 500" and it is read as 1/2 to match the fractions used everywhere else; if he meant 1.2 bottles the crew holds 1,600 mL and $587.41 instead of $458.91.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Enroflox(Baytril)';

    -- Excede: shelf 2,650 mL (carried as 10.6 x 250 mL), trucks 187.5 mL
    -- (0.75 of a 250 mL bottle, so the four boxes multiply out to
    -- counted_units exactly). 2,837.5 mL.
    UPDATE public.med_count_lines cl
       SET barn_full = 10.6, crew_full = 0, crew_open = 0.75, crew_carried = false,
           counted_units = 2837.5,
           notes = 'FINAL 2026-10-01. The shelf holds 1 x 250 mL AND 24 x 100 mL = 2,650 mL (John, confirmed). Redwing''s 250 ML line carried $2,596.71 against that one bottle, which was product charged out and mis-posted; corrected it reads 1 bottle at $519.35, so Redwing''s Excede is $5,133.40 + $519.35 = $5,652.75 and $2,077.36 came out of inventory. 2,650 mL at $5,652.75 is $2.133113/mL. | CREW ADDED 2026-10-01: 1 unopened + 1 at 1/4 = 1.25 bottles TAKEN AS 100 mL BOTTLES = 125 mL, plus a fourth man reporting 1/4 of a 250 mL = 62.5 mL, so the trucks hold 187.5 mL = 0.75 of a 250 mL bottle, $399.96. If the first man''s bottles are 250 mL the trucks hold 375 mL and the crew part is $799.92.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Excede';

    -- Macrosyn: barn empty, trucks 1/2 bottle. 250 mL, priced at catalog.
    UPDATE public.med_count_lines cl
       SET barn_full = 0, crew_full = 0, crew_open = 0.5, crew_carried = false,
           counted_units = 250, unit_cost = 0.781880,
           notes = 'CREW 2026-10-01: 1/2 bottle of Macrosyn in a truck = 250 mL at the catalog rate of $0.78188/mL = $195.47. The count said zero when only the barn had been counted. Redwing carries $373.15 against no quantity from the July close, so $195.47 of that is real product sitting in a truck and $177.68 is the error - worth telling the accountants.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Macrosyn(Draxxin)';

    SELECT count(*) INTO n
      FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count
       AND m.name IN ('Resflor','Enroflox(Baytril)','Excede','Macrosyn(Draxxin)')
       AND coalesce(cl.crew_full,0) + coalesce(cl.crew_open,0) > 0;
    IF n <> 4 THEN
        RAISE EXCEPTION 'expected 4 crew-held lines, found %', n;
    END IF;
END
$crew$;

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

    -- EVERY stocked line's four boxes must multiply out to counted_units.
    -- This is the assertion that caught the Excede crew boxes implying
    -- 312.5 mL against a counted 2,775.
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
    IF v <> 19443.34 THEN RAISE EXCEPTION 'count comes to %, expected 19443.34', v; END IF;

    SELECT round(SUM(cl.bottle_size * (coalesce(cl.crew_full,0) + coalesce(cl.crew_open,0))
                     * cl.unit_cost), 2) INTO v
      FROM public.med_count_lines cl
     WHERE cl.count_id = v_count AND cl.unit_cost IS NOT NULL;
    IF v <> 1781.26 THEN RAISE EXCEPTION 'crew-held stock comes to %, expected 1781.26', v; END IF;

    -- and the bridge from Redwing's own report has to land on the count
    IF round(21896.25 - 2077.36 - 373.15 + 1781.26 - 1783.66, 2) <> 19443.34 THEN
        RAISE EXCEPTION 'the Redwing bridge no longer lands on the count';
    END IF;

    SELECT count(*) INTO n FROM public.med_purchase_lines;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', n; END IF;
    SELECT count(*) INTO n FROM public.med_txns;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', n; END IF;
    IF (SELECT status FROM public.med_counts WHERE id = v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the count is not a draft';
    END IF;

    RAISE NOTICE 'VERIFIED: 21 lines, 11 stocked, every line''s boxes reconcile, $19,443.34 counted of which $1,781.26 is crew-held, still a draft.';
END
$verify$;

commit;
