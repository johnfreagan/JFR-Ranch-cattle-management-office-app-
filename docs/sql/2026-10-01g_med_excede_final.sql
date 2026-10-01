-- =====================================================================
-- Excede, final: 24 x 100 mL AND 1 x 250 mL
-- =====================================================================
-- 2026-10-01. Supersedes the Excede half of 2026-10-01f, which was
-- wrong. The Synovex C half of that file stands.
--
-- I got this twice before getting it right, so the record is worth
-- having straight.
--
--   First pass  - counted 2,650 mL at $2.138917/mL = $5,668.13, pricing
--                 everything at the 100 mL line's rate because the
--                 250 mL line's $10.386840/mL was plainly wrong.
--   Second pass - on "it has been corrected now and inventory of books
--                 is 1 bottle at $519.35" I read the whole of Excede as
--                 one bottle and cut the count to 250 mL, $519.35.
--                 WRONG. "1 bottle at $519.35" was the 250 ML LINE, not
--                 the whole drug.
--   Final       - John: "excede is 1 250 mil and 24 100 mile bottles".
--                 Both are on the shelf. 2,650 mL.
--
-- What had actually happened in Redwing: product charged out was left
-- sitting in inventory at the wrong value on the 250 ML line. Corrected,
-- that line reads 1 bottle at $519.35, so Redwing's Excede is
--     $5,133.40 (24 x 100 mL) + $519.35 (1 x 250 mL) = $5,652.75
-- and $2,077.36 came out of inventory, not $7,210.76.
--
-- The count is therefore 2,650 mL at $5,652.75, which is $2.133113/mL
-- and back-multiplies to $5,652.75 exactly.
--
-- THE ORIGINAL FINDING WAS RIGHT ALL ALONG. "$2,596.71 / 5 = $519.34 a
-- bottle, within 0.3% of our $517.78" pointed straight at $519.35 being
-- the real bottle price. The arithmetic was sound; only the explanation
-- for it was wrong - not a case price keyed at receiving, but product
-- charged out and mis-posted.
--
-- Nothing was ever posted. The count has been a draft throughout.
--
-- WHERE IT LEAVES THE RECONCILIATION
--     Redwing report at 9/30/2026                      $21,896.25
--       less Excede, re-allocated 10/1 (already done)   $2,077.36
--       less Macrosyn, July close (with accountants)      $373.15
--       less expired product, net (for Jayci)           $1,783.66
--             One Grass 1,804.00 + Synovex S 165.00
--             + Synovex C 121.00 = 2,090.00
--             less 306.34 moved to Multi Min
--     Redwing after all of it                          $17,662.08
--     The count                                        $17,662.08
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
       AND l.kind='ranch' AND NOT l.is_test;

    IF v_count IS NULL THEN
        RAISE EXCEPTION 'the opening count draft is missing';
    END IF;
    IF (SELECT status FROM public.med_counts WHERE id=v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the opening count is no longer a draft - refusing to edit a posted count';
    END IF;

    UPDATE public.med_count_lines cl
       SET counted_units = 2650, unit_cost = 2.133113, barn_full = 10.6,
           notes = 'FINAL 2026-10-01. The shelf holds 1 x 250 mL AND 24 x 100 mL = 2,650 mL (John, confirmed). Redwing''s 250 ML line carried $2,596.71 against that one bottle - product charged out and mis-posted; corrected it reads 1 bottle at $519.35, so Redwing''s Excede is $5,133.40 + $519.35 = $5,652.75 and $2,077.36 came out of inventory. 2,650 mL at $5,652.75 is $2.133113/mL. The corrected 250 mL bottle at $2.0774/mL is 0.30% from our last purchase price, which is what the original "five bottles of money against one bottle of product" reading was pointing at.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Excede';
END
$fix$;

DO $verify$
DECLARE
    v_count uuid; n integer; v numeric; posted integer;
BEGIN
    SELECT c.id INTO v_count FROM public.med_counts c
      JOIN public.med_stock_locations l ON l.id = c.location_id
     WHERE c.count_date = DATE '2026-09-30' AND c.is_opening
       AND l.kind='ranch' AND NOT l.is_test;

    SELECT count(*) INTO n FROM public.med_count_lines WHERE count_id=v_count;
    IF n <> 21 THEN RAISE EXCEPTION 'expected 21 count lines, found %', n; END IF;

    SELECT round(SUM(counted_units*unit_cost),2) INTO v
      FROM public.med_count_lines WHERE count_id=v_count AND unit_cost IS NOT NULL;
    IF v <> 17662.08 THEN RAISE EXCEPTION 'count comes to %, expected 17662.08', v; END IF;

    SELECT count(*) INTO n FROM public.med_count_lines cl
      JOIN public.medications m ON m.id=cl.medication_id
     WHERE cl.count_id=v_count AND m.name='Excede'
       AND cl.counted_units=2650 AND cl.unit_cost=2.133113;
    IF n <> 1 THEN RAISE EXCEPTION 'Excede is not 2,650 mL at 2.133113'; END IF;

    -- and it must back-multiply to what Redwing now carries
    SELECT round(counted_units*unit_cost,2) INTO v FROM public.med_count_lines cl
      JOIN public.medications m ON m.id=cl.medication_id
     WHERE cl.count_id=v_count AND m.name='Excede';
    IF v <> 5652.75 THEN RAISE EXCEPTION 'Excede values at %, expected 5652.75', v; END IF;

    SELECT count(*) INTO posted FROM public.med_purchase_lines;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', posted; END IF;
    SELECT count(*) INTO posted FROM public.med_txns;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', posted; END IF;
    IF (SELECT status FROM public.med_counts WHERE id=v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the count is not a draft';
    END IF;

    RAISE NOTICE 'VERIFIED: 21 lines, $17,662.08 counted, Excede 2,650 mL at $5,652.75, still a draft.';
END
$verify$;

commit;
