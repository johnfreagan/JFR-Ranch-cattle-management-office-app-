-- =====================================================================
-- The truck bottle is Draxxin KP, and Protivity is written off
-- =====================================================================
-- 2026-10-01. Three corrections from John, all of them his to make and
-- none of them arithmetic.
--
-- 1. THE HALF BOTTLE IN THE TRUCK IS DRAXXIN KP, NOT MACROSYN.
--
-- It was reported as Macrosyn and booked there - 250 mL at the catalog
-- rate, $195.47. John: "the truck has draxin kp not macrosyn." Draxxin
-- KP is a 250 mL bottle at $1.764/mL, so a half bottle is 125 mL and
-- $220.50, and it lands on a line that already carries one bottle on the
-- shelf.
--
--     Draxxin KP   250 mL shelf + 125 mL truck = 375 mL, $661.50
--                  against Redwing's $441.00, so +$220.50 for the books
--     Macrosyn     back to ZERO. There is none anywhere on the place.
--
-- THE SECOND-ORDER EFFECT IS THE IMPORTANT ONE. The earlier reading said
-- that of the $373.15 Redwing carries against no Macrosyn quantity,
-- $195.47 was real product in a truck and only $177.68 was the July
-- posting error. That is now wrong in the direction that matters: with
-- no Macrosyn anywhere, ALL $373.15 is the error. The July close has to
-- clear the whole thing.
--
-- 2. PROTIVITY IS COUNTED ZERO, BY DECISION.
--
-- Eight 10-dose boxes, 80 doses, are physically on the shelf. John: it
-- "has already been charged to a lot in past no need to resurrect it
-- will give to processing at no cost to burn up."
--
-- So a counted zero is now the TRUE statement, and this file reverses
-- the correction in 2026-10-01e that set the line back to NOT COUNTED.
-- That correction was right at the time and for the right reason - the
-- line then said a zero copied from Redwing, which was a false
-- statement about 80 real doses. What changed is not the doses but the
-- cost: it was expensed to a lot in a past period and none will be
-- carried forward. The doses exist; their cost does not. unit_cost goes
-- back to NULL because there is no price to hold.
--
-- This also closes the open item that was waiting on a price. No price
-- is needed.
--
-- 3. JAYCI AND BRENDA ARE THE ACCOUNTANTS. Earlier notes said to pass
-- the Macrosyn July entry "to the accountants" as though they were
-- someone else. They are not; it is Jayci's and Brenda's to clear. The
-- notes say so now.
--
-- WHAT IT DOES TO THE NUMBERS
--     crew-held stock      $2,394.53  ->  $2,419.56
--     the count           $20,056.61  ->  $20,081.64
--     Jayci's net           +$610.87  ->    +$635.90
--     stocked lines               11  ->          10
--
-- WHERE IT LEAVES THE RECONCILIATION
--     Redwing report at 9/30/2026                      $21,896.25
--       less Excede, re-allocated 10/1 (already done)   $2,077.36
--       less Macrosyn, July close (Jayci and Brenda)      $373.15
--       plus crew-held stock back in                    $2,419.56
--       less expired product, net                       $1,783.66
--     Redwing after all of it                          $20,081.64
--     The count                                        $20,081.64
--
-- STILL TO COME: Jake Taylor's processing medicine. Nothing has been
-- posted. The count has been a draft throughout.
-- =====================================================================

begin;

DO $fix$
DECLARE
    v_count uuid;
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

    -- Draxxin KP: 1 bottle on the shelf + the truck half. 375 mL.
    UPDATE public.med_count_lines cl
       SET barn_full = 1, crew_full = 0, crew_open = 0.5, crew_carried = false,
           counted_units = 375,
           notes = 'Sheet: 250 mL. Redwing 1 container at $441.00. | CREW ADDED 2026-10-01: 1/2 bottle in a truck = 125 mL at $1.764/mL = $220.50. CORRECTED by John 2026-10-01: the truck half bottle is DRAXXIN KP, not Macrosyn. It was first reported as Macrosyn and booked on that line; this moves it to the right drug. Charged out in September and not yet used, so Redwing is short by it.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Draxxin KP';

    -- Macrosyn: nothing anywhere.
    UPDATE public.med_count_lines cl
       SET barn_full = 0, crew_full = 0, crew_open = 0, crew_carried = false,
           counted_units = 0,
           notes = 'Counted ZERO. 2026-10-01: a half bottle in a truck was first reported as Macrosyn and booked here at $195.47; John corrected it to Draxxin KP, so this line goes back to nothing. There is no Macrosyn anywhere on the place. Redwing carries $373.15 against no quantity from the July close and ALL of it is the posting error - not $177.68, as the earlier reading had it. For Jayci and Brenda to clear in the July close.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Macrosyn(Draxxin)';

    -- Protivity: the doses exist, their cost does not.
    UPDATE public.med_count_lines cl
       SET counted_units = 0, unit_cost = NULL,
           notes = 'Counted ZERO by decision, 2026-10-01. Eight 10-dose boxes, 80 doses, are physically on the shelf and Redwing carries none. John: the product was already charged to a lot in a past period and will be given to processing at no cost to burn up, so there is no cost left to carry and nothing to resurrect. A counted zero is the TRUE statement here - the doses exist, their cost does not. This supersedes the correction that set the line back to NOT COUNTED while a price was looked for; no price is needed, because none will be carried.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Protivity';
END
$fix$;

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
    IF n <> 10 THEN RAISE EXCEPTION 'expected 10 stocked lines, found %', n; END IF;

    -- there must be NO line left uncounted: every one of the 21 now says
    -- something, which is what makes the count postable.
    SELECT count(*) INTO n FROM public.med_count_lines
     WHERE count_id = v_count AND counted_units IS NULL;
    IF n <> 0 THEN RAISE EXCEPTION '% count lines are still NOT COUNTED', n; END IF;

    -- every stocked line's four gathering boxes multiply out to counted_units
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
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'count boxes do not reconcile - %', bad; END IF;

    -- Macrosyn holds nothing and Draxxin KP holds the truck bottle
    SELECT count(*) INTO n FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count AND m.name = 'Macrosyn(Draxxin)' AND cl.counted_units = 0;
    IF n <> 1 THEN RAISE EXCEPTION 'Macrosyn is not zero'; END IF;

    SELECT round(cl.counted_units * cl.unit_cost, 2) INTO v FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count AND m.name = 'Draxxin KP';
    IF v <> 661.50 THEN RAISE EXCEPTION 'Draxxin KP values at %, expected 661.50', v; END IF;

    -- Protivity carries no cost at all, which is the point
    SELECT count(*) INTO n FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count AND m.name = 'Protivity'
       AND cl.counted_units = 0 AND cl.unit_cost IS NULL;
    IF n <> 1 THEN RAISE EXCEPTION 'Protivity is not a costless zero'; END IF;

    SELECT round(SUM(counted_units * unit_cost), 2) INTO v
      FROM public.med_count_lines WHERE count_id = v_count AND unit_cost IS NOT NULL;
    IF v <> 20081.64 THEN RAISE EXCEPTION 'count comes to %, expected 20081.64', v; END IF;

    SELECT round(SUM(cl.bottle_size * (coalesce(cl.crew_full,0) + coalesce(cl.crew_open,0))
                     * cl.unit_cost), 2) INTO v
      FROM public.med_count_lines cl
     WHERE cl.count_id = v_count AND cl.unit_cost IS NOT NULL;
    IF v <> 2419.56 THEN RAISE EXCEPTION 'crew-held stock comes to %, expected 2419.56', v; END IF;

    IF round(21896.25 - 2077.36 - 373.15 + 2419.56 - 1783.66, 2) <> 20081.64 THEN
        RAISE EXCEPTION 'the Redwing bridge no longer lands on the count';
    END IF;

    SELECT count(*) INTO n FROM public.med_purchase_lines;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', n; END IF;
    SELECT count(*) INTO n FROM public.med_txns;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', n; END IF;
    IF (SELECT status FROM public.med_counts WHERE id = v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the count is not a draft';
    END IF;

    RAISE NOTICE 'VERIFIED: 21 lines, none uncounted, 10 stocked, boxes reconcile, $20,081.64 counted of which $2,419.56 is crew-held, still a draft.';
END
$verify$;

commit;
