-- =====================================================================
-- Excede is carried on a 100 mL bottle, so the count screen can take it
-- =====================================================================
-- 2026-10-01. No money moves here. 3,125 mL before, 3,125 mL after,
-- $6,665.98 before and after. What changes is whether a person can type
-- the row in.
--
-- FOUND BY LOOKING AT THE SCREEN, which is the point worth recording.
-- The count grid's open-bottle boxes take a FRACTION of a bottle and
-- the input is `step="0.25" max="0.75"` - quarters, nothing above three
-- quarters, because that is the precision a man in a truck can honestly
-- give. On a 250 mL bottle the crew's Excede came to
--     475 mL / 250 = 1.9 bottles  ->  crew_full 1, crew_open 0.9
-- and 0.9 is neither a quarter nor under the cap. The database took it
-- (the CHECK is only `< 1`) but the screen would not. A row that only
-- an UPDATE can produce is a row nobody can recount next month.
--
-- Excede is on the place in TWO container sizes - 24 x 100 mL and
-- 1 x 250 mL - and the line has to pick one. 100 mL is the one there
-- are 24 of, and on 100 every box lands on a quarter:
--
--                     250 mL carrier        100 mL carrier
--     barn            10.6                  26 + 0.5
--     crew            1 + 0.9   <-- bad     4 + 0.75
--     counted         3,125 mL              3,125 mL
--     value           $6,665.98             $6,665.98
--
-- unit_cost is per mL ($2.133113) and does not depend on the container,
-- so nothing downstream moves: not the value, not a dose, not the
-- reconciliation. On hand simply reads 31.25 bottles instead of 12.50.
--
-- WHAT IS NOT FIXED HERE. The medications catalog still carries ONE
-- bottle_size for Excede (250 mL, $519.35), and the shelf has two. That
-- is cosmetic today - per-mL cost is size-independent, so dosing and
-- FIFO are right either way - but "bottles" on any screen means
-- whichever size the catalog happens to hold. A catalog change is
-- John's call and is not made here.
--
-- Nothing has been posted. The count has been a draft throughout.
-- =====================================================================

begin;

DO $fix$
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

    UPDATE public.med_count_lines cl
       SET bottle_size = 100, barn_full = 26, barn_open = 0.5,
           crew_full = 4, crew_open = 0.75, crew_carried = false,
           counted_units = 3125,
           notes = 'FINAL 2026-10-01. The shelf holds 1 x 250 mL AND 24 x 100 mL = 2,650 mL (John, confirmed). Redwing''s 250 ML line carried $2,596.71 against that one bottle, which was product charged out and mis-posted; corrected it reads 1 bottle at $519.35, so Redwing''s Excede is $5,133.40 + $519.35 = $5,652.75 and $2,077.36 came out of inventory. 2,650 mL at $5,652.75 is $2.133113/mL. | CREW, ACTUAL as given by John 2026-10-01: 1 full 100 mL + 1 full 250 mL + 1/4 of a 250 + 1/4 of a 250 = 475 mL, $1,013.23. | CARRIED ON A 100 mL BOTTLE, not 250. Excede is on the place in both sizes, and 100 mL is the one there are 24 of. At 250 the crew half came to 1.9 bottles, which the count screen cannot accept - its open boxes are quarters and cap at 0.75. At 100 every box is a quarter: barn 26 + 1/2, crew 4 + 3/4, 3,125 mL. Same millilitres, same $6,665.98, and now enterable by hand.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Excede';

    SELECT round(cl.counted_units * cl.unit_cost, 2) INTO v
      FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count AND m.name = 'Excede';
    IF v <> 6665.98 THEN
        RAISE EXCEPTION 'Excede values at %, expected 6665.98 - this file must not move money', v;
    END IF;
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

    -- the gathering boxes still multiply out to counted_units
    SELECT string_agg(m.name, '; ') INTO bad
      FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count AND cl.counted_units > 0
       AND cl.bottle_size * (coalesce(cl.barn_full,0) + coalesce(cl.barn_open,0)
                           + coalesce(cl.crew_full,0) + coalesce(cl.crew_open,0))
           <> cl.counted_units;
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'count boxes do not reconcile - %', bad; END IF;

    -- THE NEW ONE. Every open box must be something the count screen can
    -- accept: a quarter, and not more than three quarters. The database
    -- CHECK only says "< 1", so this is the assertion that keeps a row
    -- from being created that nobody can recount.
    SELECT string_agg(m.name || ' barn_open=' || coalesce(cl.barn_open,0)
                      || ' crew_open=' || coalesce(cl.crew_open,0), '; ')
      INTO bad
      FROM public.med_count_lines cl
      JOIN public.medications m ON m.id = cl.medication_id
     WHERE cl.count_id = v_count
       AND (coalesce(cl.barn_open,0) > 0.75 OR coalesce(cl.crew_open,0) > 0.75
         OR coalesce(cl.barn_open,0) * 4 <> round(coalesce(cl.barn_open,0) * 4)
         OR coalesce(cl.crew_open,0) * 4 <> round(coalesce(cl.crew_open,0) * 4));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'an open box is not a quarter, or is over the screen''s 0.75 cap - %', bad;
    END IF;

    SELECT round(SUM(counted_units * unit_cost), 2) INTO v
      FROM public.med_count_lines WHERE count_id = v_count AND unit_cost IS NOT NULL;
    IF v <> 20081.64 THEN RAISE EXCEPTION 'count comes to %, expected 20081.64', v; END IF;

    SELECT round(SUM(cl.bottle_size * (coalesce(cl.crew_full,0) + coalesce(cl.crew_open,0))
                     * cl.unit_cost), 2) INTO v
      FROM public.med_count_lines cl
     WHERE cl.count_id = v_count AND cl.unit_cost IS NOT NULL;
    IF v <> 2419.56 THEN RAISE EXCEPTION 'crew-held stock comes to %, expected 2419.56', v; END IF;

    SELECT count(*) INTO n FROM public.med_purchase_lines;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', n; END IF;
    SELECT count(*) INTO n FROM public.med_txns;
    IF n <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', n; END IF;

    RAISE NOTICE 'VERIFIED: every open box is a quarter at or under 0.75, boxes reconcile, $20,081.64 counted, $2,419.56 crew-held, still a draft.';
END
$verify$;

commit;
