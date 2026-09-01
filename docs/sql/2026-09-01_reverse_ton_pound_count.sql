-- =====================================================================
-- Reverse the Commodity Barn count of 2026-08-31
-- =====================================================================
-- The count was entered in TONS into the POUNDS box. Every line is the
-- book figure divided by 2,000:
--
--   Corn (Feed)        866,388 lb book -> 433 counted   (433.19 tons)
--   Whole Cottonseed   174,418        ->  87            ( 87.21 tons)
--   Peanut Hulls        73,443        ->  37            ( 36.72 tons)
--   DDG                 73,318        ->  37            ( 36.66 tons)
--   SoyHull Pellets     69,830        ->  35            ( 34.92 tons)
--   Molasses            25,547        ->  13            ( 12.77 tons)
--
-- Posting it booked 1,282,302 lb / $119,524.97 of feed to the variance
-- account as shrink, and left the barn holding 642 lb.
--
-- WHY REVERSE RATHER THAN RE-COUNT: a second count at the true pounds
-- would book found feed and net the variance account back to about zero,
-- but it leaves two enormous offsetting entries in the one account whose
-- balance is supposed to mean "how good are the shrink allowances". It
-- would also lay the restored feed down as a NEW layer dated 8/31, ahead
-- of nothing and behind everything, quietly reordering FIFO. Reversing
-- puts the pounds back on the original layers at their original cost and
-- leaves no trace in the variance account, which is the truth: no shrink
-- happened.
--
-- delete_feed_usage() restores the exact layers a usage drew from, with
-- no branch for a layer consumed to zero - that branch is the
-- delete_death_event trap. Verified on scratch PostgreSQL 16 against
-- this exact case: 866,388 -> 433 -> 866,388, usage and cost rows gone.
--
-- HOW TO RUN IT: paste into the Supabase SQL editor. One DO block, so
-- any failure rolls the whole thing back.
-- =====================================================================

DO $reverse$
DECLARE
    v_count_id CONSTANT uuid := '87359e6f-ff0b-40c9-99f3-e1bce2955511';
    v_lines    integer;
    v_bad      integer;
    v_before   numeric;
    v_after    numeric;
    r          record;
    bad        text;
BEGIN
    -- 0. Prove this is the count we mean, and that it is the ton/pound
    -- mistake and not a real shrink event. If someone has already fixed
    -- it, or the id is wrong, stop rather than reverse a good count.
    SELECT count(*) INTO v_lines FROM public.feed_count_lines WHERE count_id = v_count_id;
    IF v_lines = 0 THEN
        RAISE EXCEPTION 'Count % has no lines - already reversed, or wrong id.', v_count_id;
    END IF;

    -- every line must look like tons-in-the-pounds-box: counted x 2000
    -- within 1%% of book. Anything else is a real count and must not be
    -- swept away by this script.
    SELECT count(*) INTO v_bad
      FROM public.feed_count_lines
     WHERE count_id = v_count_id
       AND (book_qty_lb IS NULL OR counted_qty_lb IS NULL
            OR book_qty_lb <= 0
            OR abs(counted_qty_lb * 2000 - book_qty_lb) > book_qty_lb * 0.01);
    IF v_bad > 0 THEN
        RAISE EXCEPTION
          'STOP: % of % line(s) on this count are NOT the ton/pound mistake. Reversing would destroy a real count.',
          v_bad, v_lines;
    END IF;

    SELECT COALESCE(SUM(qty_lb_remaining),0) INTO v_before FROM public.feed_receipts;

    -- 1. Put the pounds back on the layers they came off.
    FOR r IN
        SELECT cl.adjustment_usage_id AS usage_id, i.name
          FROM public.feed_count_lines cl
          JOIN public.feed_items i ON i.id = cl.item_id
         WHERE cl.count_id = v_count_id AND cl.adjustment_usage_id IS NOT NULL
    LOOP
        PERFORM public.delete_feed_usage(r.usage_id);
        RAISE NOTICE 'Reversed shrink on %.', r.name;
    END LOOP;

    -- 2. Remove the count itself. Lines cascade. It is not a record worth
    -- keeping: it describes pounds that were never missing.
    DELETE FROM public.feed_counts WHERE id = v_count_id;

    -- 3. Prove the barn is whole again.
    SELECT COALESCE(SUM(qty_lb_remaining),0) INTO v_after FROM public.feed_receipts;
    IF v_after - v_before <> 1282302 THEN
        RAISE EXCEPTION 'Expected 1,282,302 lb restored, got %. Rolling back.', v_after - v_before;
    END IF;

    SELECT string_agg(x.name || ' = ' || round(x.lb) || ' lb (want ' || x.want || ')', '; ')
      INTO bad
      FROM (
        SELECT i.name, SUM(r2.qty_lb_remaining) AS lb, v.want
          FROM (VALUES ('Corn (Feed)',866388),('Whole Cottonseed',174418),
                       ('Peanut Hulls',73443),('DDG',73318),
                       ('SoyHull Pellets',69830),('Molasses',25547)) v(nm,want)
          JOIN public.feed_items i ON i.name = v.nm
          JOIN public.feed_receipts r2 ON r2.item_id = i.id
         GROUP BY i.name, v.want
      ) x
     WHERE round(x.lb) <> x.want;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'Barn did not come back whole: %', bad;
    END IF;

    -- 4. And that no shrink survives in the variance account for these.
    IF EXISTS (SELECT 1 FROM public.feed_usage u
                JOIN public.feed_items i ON i.id = u.item_id
               WHERE u.destination_type = 'adjustment'
                 AND u.usage_date = DATE '2026-08-31'
                 AND i.name IN ('Corn (Feed)','Whole Cottonseed','Peanut Hulls',
                                'DDG','SoyHull Pellets','Molasses')) THEN
        RAISE EXCEPTION 'A barn shrink row survived the reversal.';
    END IF;

    RAISE NOTICE 'Barn restored: % lb back on hand, count deleted.', v_after - v_before;
END
$reverse$;


-- =====================================================================
-- Run this SECOND to read the result. Expect the barn at 1,282,944 lb /
-- $119,584.28 and total on hand back to 9,807,539 lb.
-- =====================================================================
SELECT l.name AS bay, count(r.id) AS layers,
       to_char(SUM(r.qty_lb_remaining), 'FM999,999,999') AS on_hand_lb,
       to_char(SUM(r.product_cost), 'FM999,999,990.00')  AS value_usd
  FROM public.feed_storage_locations l
  LEFT JOIN public.feed_receipts r ON r.location_id = l.id
 GROUP BY l.name
UNION ALL
SELECT 'TOTAL', count(*), to_char(SUM(qty_lb_remaining),'FM999,999,999'),
       to_char(SUM(product_cost),'FM999,999,990.00') FROM public.feed_receipts
 ORDER BY 1;
