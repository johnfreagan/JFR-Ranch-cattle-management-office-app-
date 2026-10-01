-- =====================================================================
-- Opening count, second pass: Excede corrected, Synovex C expired
-- =====================================================================
-- 2026-10-01, later the same day.
--
-- EXCEDE - THIS CORRECTS A MISREADING ON MY PART, not a change of fact.
--
-- When John was asked how many bottles were on the 250 mL line he
-- answered "excede = 1 bottle". That was read as "the 250 mL line is one
-- bottle" and all 2,650 mL - 24 x 100 mL plus 1 x 250 mL - was counted
-- at $5,668.13. He meant ONE BOTTLE IN TOTAL.
--
-- What had actually happened: the 24 x 100 mL were charged out in
-- Redwing earlier that day and posted to the wrong place. Once
-- re-allocated, Redwing carries Excede at 1 bottle, $519.35. So the
-- shelf holds one 250 mL bottle and the count is 250 mL at $2.0774/mL.
--
-- That figure corroborates twice over: it is 0.30% from this catalog's
-- last purchase price of $2.071120, and it is what the earlier finding
-- was pointing at all along - $2,596.71 / 5 = $519.34 a bottle. The
-- "five bottles of money against one bottle of product" reading was
-- right about the arithmetic and wrong about the cause: not a case price
-- keyed against a single unit, but product charged out and mis-posted.
--
-- The draft was never posted, so nothing wrong ever reached the ledger.
-- But $5,668.13 against $519.35 is a $5,148.78 difference in a document
-- John was about to act on, which is why it is written up here rather
-- than quietly amended.
--
-- SYNOVEX C. Counted at 110 doses, $121.00, from Redwing. John then
-- found it is out of date and being disposed of, like Synovex S and One
-- Grass. Counted zero; the $121.00 joins the expired write-off.
--
-- WHERE THAT LEAVES THE RECONCILIATION
--     Redwing report at 9/30/2026                      $21,896.25
--       less Excede, re-allocated 10/1 (already done)   $7,210.76
--       less Macrosyn, July close (with accountants)      $373.15
--       less expired product, net                       $1,783.66
--             One Grass 1,804.00 + Synovex S 165.00
--             + Synovex C 121.00 = 2,090.00
--             less 306.34 moved to Multi Min
--     Redwing after all of it                          $12,528.68
--     The count                                        $12,528.68
--
-- Still a DRAFT. Nothing posts.
-- =====================================================================

begin;

-- Redwing's corrected book price for a 250 mL bottle. The catalog's
-- "last purchase price" fallback should carry it.
UPDATE public.medications SET bottle_cost = 519.35 WHERE name = 'Excede';

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
       SET counted_units = 250, unit_cost = 2.077400, barn_full = 1,
           notes = 'CORRECTED 2026-10-01 (second pass). First entry counted all 2,650 mL on a misreading of "excede = 1 bottle" as referring to the 250 mL line only; John meant one bottle in total. The 24 x 100 mL had been charged out in Redwing that day and mis-posted; once re-allocated Redwing carries 1 bottle at $519.35. One 250 mL bottle at $2.0774/mL, which is 0.30% from our last purchase price.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count AND m.name = 'Excede';

    UPDATE public.med_count_lines cl
       SET counted_units = 0, unit_cost = NULL, barn_full = 0,
           notes = 'CORRECTED 2026-10-01 (second pass). Counted 110 doses at $1.10 from Redwing; John then found it out of date and being disposed of, like Synovex S and One Grass. None on the shelf, and the $121.00 joins the expired write-off.'
      FROM public.medications m
     WHERE m.id = cl.medication_id AND cl.count_id = v_count
       AND m.name = 'Synovex C 100 Ds Prestige';
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
    IF v <> 12528.68 THEN RAISE EXCEPTION 'count comes to %, expected 12528.68', v; END IF;

    -- Excede must be the single 250 mL bottle, not the 2,650 mL first pass.
    SELECT count(*) INTO n FROM public.med_count_lines cl
      JOIN public.medications m ON m.id=cl.medication_id
     WHERE cl.count_id=v_count AND m.name='Excede'
       AND cl.counted_units=250 AND cl.unit_cost=2.077400;
    IF n <> 1 THEN RAISE EXCEPTION 'Excede is not 250 mL at 2.077400'; END IF;

    SELECT count(*) INTO posted FROM public.med_purchase_lines;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% layers)', posted; END IF;
    SELECT count(*) INTO posted FROM public.med_txns;
    IF posted <> 0 THEN RAISE EXCEPTION 'ledger is not empty (% txns)', posted; END IF;
    IF (SELECT status FROM public.med_counts WHERE id=v_count) <> 'draft' THEN
        RAISE EXCEPTION 'the count is not a draft';
    END IF;

    RAISE NOTICE 'VERIFIED: 21 lines, $12,528.68 counted, Excede 250 mL, still a draft, nothing posted.';
END
$verify$;

commit;
